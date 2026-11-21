#!/usr/bin/env bash
# Update standalone Linux programs from GitHub releases.
#
#   bash binup.sh                  open the interactive menu
#   bash binup.sh add [name]       register an app and choose its release file
#   bash binup.sh edit NAME        edit settings or choose a different build
#   bash binup.sh check [NAME]     check one or all apps, without installing
#   bash binup.sh update NAME      update one app (-f or --force to reinstall)
#   bash binup.sh update all       update all apps, continuing after failures
#   bash binup.sh list [--json] | remove NAME
#   bash binup.sh status NAME | logs NAME [--follow] | service NAME start|stop|restart
#   bash binup.sh install [CONFIG_PATH]       upgrade a loose script and install the UI
#   bash binup.sh web-install [CONFIG_PATH]   install the UI from this checkout
#   bash binup.sh web-uninstall               remove the web service and Cockpit page
#
# Pick a numbered file, enter r for a custom regex, or q to cancel. Terminal
# updates reopen the picker if a rule matches zero or several release files.
# In asset_regex, {tag} matches the full tag and {version} drops its leading v.
#
# Config: binup.json beside the script, or BINUP_CONF. GITHUB_TOKEN is optional.
# Run as your normal user. System units and protected destinations may need sudo.
# Requires Bash, curl, jq, flock, Python 3 and GNU coreutils. Optional tar
# compressors such as zstd must be installed to read those formats.
# check exits 0 if current, 10 if an update or baseline check is due, 1 on error.

# Single-quoted filters passed to config/save_config contain jq variables.
# Helpers read the active transaction's local variables inside its subshell.
# shellcheck disable=SC2016,SC2030,SC2031
set -uo pipefail

SELF=$(readlink -f -- "${BASH_SOURCE[0]}") || exit 1
LAUNCHER=$(realpath -ms -- "${BASH_SOURCE[0]}") || exit 1
CONF=$(realpath -m -- "${BINUP_CONF:-${LAUNCHER%/*}/binup.json}") || exit 1
API=https://api.github.com

# The web runner is a new session leader. Acquiring its private terminal gives
# sudo one timestamp for this run, including commands inside Bash subshells.
if [[ -n ${BINUP_SUDO_TTY:-} && -n ${BINUP_ASKPASS_DIR:-} ]]; then
  : < "$BINUP_SUDO_TTY" || exit 1
  unset BINUP_SUDO_TTY
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
fail() { warn "$*"; return 1; }

case $(uname -m) in
  x86_64)        ARCH_RE='amd64|x86_64|x64|64bit' ;;
  i?86)          ARCH_RE='i[3-6]86|x86([^_0-9]|$)|32bit' ;;
  aarch64|arm64) ARCH_RE='arm64|aarch64|armv8' ;;
  armv7l)        ARCH_RE='armv7|armhf' ;;
  *)             ARCH_RE=$(uname -m) ;;
esac

as_root() {
  if (( EUID == 0 )); then "$@"
  elif [[ -n ${BINUP_WEB:-} ]]; then
    command -v sudo >/dev/null || { fail 'This action needs sudo. Run it from the local CLI.'; return 1; }
    if [[ -n ${BINUP_ASKPASS_DIR:-} ]]; then
      SUDO_ASKPASS="${SELF%/*}/binup_web.py" BINUP_SUDO_APP="${app:-}" BINUP_SUDO_BIN="${bin:-}" \
        sudo -A -p 'Password for %p' -- "$@"
      return
    fi
    local rc
    if sudo -n -- "$@"; then return 0; else rc=$?; fi
    warn 'If sudo needs a password, open Binup in Cockpit over HTTPS or through localhost and retry.'
    return "$rc"
  else sudo -- "$@"; fi
}
as_login() {
  if (( EUID == 0 )) && [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    sudo -H -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$SUDO_USER")" "$@"
  else "$@"; fi
}
sctl() {
  local scope=$1
  shift
  if [[ $scope == user ]]; then as_login systemctl --user "$@"
  else
    case $1 in
      start|stop|restart|enable|disable|daemon-reload) as_root systemctl "$@" ;;
      *) systemctl "$@" ;;
    esac
  fi
}
valid_service() {
  local name=${1%.service} pattern='^([[:alnum:]_.:]|\\x[[:xdigit:]]{2})([[:alnum:]_.:@-]|\\x[[:xdigit:]]{2})*$'
  [[ ( $2 == system || $2 == user ) && $name =~ $pattern && $name != *@ && ${#name} -le 247 ]]
}

# Every mutating command holds the same lock through selection, install and save.
mutate() (
  if [[ ! -e $CONF.lock ]]; then (umask 022; : >> "$CONF.lock") || return 1; fi
  exec 9<"$CONF.lock" || return 1
  flock -n 9 || { fail "Another writer holds $CONF.lock. Retry when it finishes."; return 1; }
  "$@"
)

config() {
  if [[ -e $CONF ]]; then jq "$@" "$CONF"; else jq "$@" <<< '{}'; fi
}
save_config() (
  local draft
  draft=$(mktemp -- "$CONF.XXXXXXXX") || return 1
  trap 'rm -f -- "$draft"' EXIT
  config -e "$@" > "$draft" && [[ -s $draft ]] || { fail "Could not write $CONF."; return 1; }
  if [[ -e $CONF ]]; then
    if (( EUID == 0 )); then chown --reference="$CONF" -- "$draft" || return 1; fi
    chmod --reference="$CONF" -- "$draft" || return 1
  fi
  mv -fT -- "$draft" "$CONF"
)
entry_for() { config -ec --arg n "$1" '.[$n] // {}'; }
field()     { jq -r --arg k "$2" '.[$k] // ""' <<< "$1"; }

# The web form also accepts choices, help text, a required flag and a display label.
ask() {
  local label=$1 initial=${2:-}
  if [[ -n ${BINUP_PROMPT_FD:-} ]]; then
    jq -c --arg label "${6:-$label}" --arg value "$initial" --arg app "${app:-}" \
      --arg hint "${4:-}" --argjson required "${5:-false}" \
      '{label:$label,app:$app,default:$value,options:.,hint:$hint,required:$required}' <<< "${3:-[]}" >&"$BINUP_PROMPT_FD" || return 1
    IFS= read -r REPLY
  elif [[ -t 0 ]]; then
    IFS= read -er -i "$initial" -p "$label: " REPLY
  else
    printf '%s: ' "$label" >&2
    IFS= read -r REPLY || return 1
    REPLY=${REPLY:-$initial}
  fi
}

choice() {
  local label=$1 initial=$2
  if [[ -n ${BINUP_PROMPT_FD:-} ]]; then ask "$label" "$initial" || return 1
  else
    printf '%s%s: ' "$label" "${initial:+ [$initial]}" >&2
    IFS= read -r REPLY || return 1
  fi
  REPLY=${REPLY:-$initial}
}
choose() {
  local label=$1 initial=$2 value i=0
  shift 2
  if [[ -n ${BINUP_PROMPT_FD:-} ]]; then
    local options
    options=$(printf '%s\n' "$@" | jq -Rs 'split("\n")[:-1] | to_entries |
      map({value:((.key+1)|tostring),label:.value})') || return 1
    ask "$label" "$initial" "$options" '' true
    return
  fi
  for value in "$@"; do ((++i)); printf '  %d) %s\n' "$i" "$value" >&2; done
  while choice "$label" "$initial"; do
    if [[ $REPLY =~ ^[1-9][0-9]{0,7}$ ]] && (( REPLY <= $# )); then return 0; fi
    warn 'Enter a listed number.'
  done
  return 1
}

find_services() {
  local scope
  command -v systemctl >/dev/null || return 0
  for scope in system user; do
    { sctl "$scope" list-unit-files --type=service --no-legend --no-pager
      sctl "$scope" list-units --type=service --all --no-legend --no-pager --plain
    } 2>/dev/null | awk '{print $1}' | grep -iF -- "$1" | grep -v '@\.service$' | sort -u | sed "s/^/$scope /"
  done
}
svc_bin() { sctl "$1" show -p ExecStart --value -- "$2" 2>/dev/null | sed -n 's/^.*path=\([^;]*[^; ]\) *;.*/\1/p' | head -1; }
detect_version() {
  local bin=$1 arg out
  [[ -f $bin && -x $bin ]] || return 0
  for arg in --version version -v -V; do
    out=$(timeout 3 "$bin" "$arg" </dev/null 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?([-+][0-9A-Za-z.]+)?' | head -1)
    if [[ -n $out ]]; then say "$out"; return; fi
  done
}

gh() {
  local headers=(-H 'Accept: application/vnd.github+json')
  if [[ -n ${GITHUB_TOKEN:-} ]]; then headers+=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
  curl --proto '=https' -fsSL --connect-timeout 10 --max-time 60 --retry 2 "${headers[@]}" -- "$API/$1"
}

get_release() {
  local repo=$1 channel=$2 tag_re=$3 page=1 releases match
  if [[ $channel == stable && -z $tag_re ]]; then
    gh "repos/$repo/releases/latest" | jq -ce 'select(.draft == false and .prerelease == false and (.tag_name | type == "string"))'
    return
  fi
  case $channel in stable|prerelease|any) ;; *) fail "Unknown release channel '$channel'."; return 1 ;; esac
  while :; do
    releases=$(gh "repos/$repo/releases?per_page=30&page=$page") || return 1
    match=$(jq -cr --arg chan "$channel" --arg re "$tag_re" '
      if type != "array" then error("expected a release list") else
        first(.[] | select(.draft == false)
          | select($chan == "any" or (.prerelease == ($chan == "prerelease")))
          | select(.tag_name | test($re))) // empty end' <<< "$releases") || return 1
    if [[ -n $match ]]; then say "$match"; return; fi
    if jq -e 'length < 30' <<< "$releases" >/dev/null; then
      fail "$repo has no $channel release matching tag filter '$tag_re'."
      return 1
    fi
    ((page++))
  done
}

regex_literal() { printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'; }
suggest_rule() {
  local name=$1 tag=$2 token before after marker
  # Generalize only a whole release token. Keep architecture, edition and file type literal.
  for token in "$tag" "${tag#v}"; do
    [[ -n $token && $name == *"$token"* && ! $token =~ ^[0-9]{1,3}$ ]] || continue
    before=${name%%"$token"*}
    after=${name#*"$token"}
    [[ $before != *[[:alnum:]] && $after != [[:alnum:]]* ]] || continue
    if [[ $token == "$tag" ]]; then marker='{tag}'; else marker='{version}'; fi
    printf '^%s%s%s$\n' "$(regex_literal "$before")" "$marker" "$(regex_literal "$after")"
    return
  done
  printf '^%s$\n' "$(regex_literal "$name")"
}

matching_assets() {
  local assets=$1 rule=$2 tag=$3
  local tag_literal version_literal
  tag_literal=$(regex_literal "$tag")
  version_literal=$(regex_literal "${tag#v}")
  jq -c --arg re "$rule" --arg tag "$tag_literal" --arg ver "$version_literal" --arg arch "$ARCH_RE" '
    if $re != "" then
      ($re | gsub("\\{(?<key>tag|version)\\}"; if .key == "tag" then $tag else $ver end)) as $expanded
      | map(select(.name | test($expanded; "i")))
    else
      map(select(.name | test("linux"; "i") and test($arch; "i")
        and (test("\\.(sha[0-9]+|md5|sig|asc|pem|sbom|json|txt|deb|rpm|apk|msi|exe|dmg|pkg)$|checksum|darwin|macos|windows|freebsd"; "i") | not)))
    end' <<< "$assets"
}

# Sets SELECTED_ASSET and SELECTED_RULE from the same release used for the menu.
select_asset() {
  local mode=$1 release=$2 rule=$3 tag assets matches count total default='' choice name proposed options hint
  tag=$(field "$release" tag_name)
  assets=$(jq -ce '[.assets[] | select(.state == "uploaded")]' <<< "$release") || return 1
  total=$(jq length <<< "$assets")
  (( total )) || { fail "$tag has no downloadable files."; return 1; }
  matches=$(matching_assets "$assets" "$rule" "$tag") || matches='[]'
  count=$(jq length <<< "$matches")
  if (( count == 1 )); then
    SELECTED_ASSET=$(jq -c '.[0]' <<< "$matches")
    SELECTED_RULE=$rule
    [[ $mode == pick ]] || return 0
    name=$(field "$SELECTED_ASSET" name)
    default=$(jq -r --arg n "$name" 'map(.name) | index($n) + 1' <<< "$assets")
  else
    warn "$tag has $count matches for ${rule:-automatic Linux / CPU detection}."
  fi
  if [[ -n ${BINUP_PROMPT_FD:-} && $mode != check ]]; then
    options=$(jq -c 'to_entries | map({value:((.key+1)|tostring),label:.value.name})
      + [{value:"r",label:"Enter a custom matching rule…"}]' <<< "$assets") || return 1
    hint="Release $tag. Choose the file for this machine."
    if (( count != 1 )); then hint="Release $tag. $count files match the current rule. Choose the correct build."; fi
  else
    printf '%s\n%s\n' "$assets" "$matches" | jq -sr '
      (.[1] | INDEX(.name)) as $matched | .[0] | to_entries[] |
      "  \(.key+1)) \(.value.name)\(if $matched[.value.name] then "  [match]" else "" end)"' >&2 || return 1
  fi
  if [[ $mode == check || ( $mode == update && ! -t 0 && -z ${BINUP_PROMPT_FD:-} ) ]]; then
    fail "Run Update in the menu or web UI to choose a file, or use Edit to change the rule."
    return 1
  fi
  while :; do
    if [[ -n ${BINUP_PROMPT_FD:-} ]]; then ask 'Release build' "$default" "$options" "$hint" true || return 1
    else choice 'Build number (r = custom regex, q = cancel)' "$default" || return 1; fi
    choice=$REPLY
    case $choice in
      q|Q) fail 'Selection cancelled.'; return 1 ;;
      r|R)
        ask 'Asset regex ({tag} is the release tag, {version} drops its leading v)' "$rule" || return 1
        proposed=$REPLY
        matches=$(matching_assets "$assets" "$proposed" "$tag") || { hint="Invalid matching rule. Choose a build or edit the rule."; continue; }
        count=$(jq length <<< "$matches")
        if (( count != 1 )); then hint="That rule matches $count files. Choose one file or refine the rule."; warn "$hint"; continue; fi
        SELECTED_ASSET=$(jq -c '.[0]' <<< "$matches")
        SELECTED_RULE=$proposed
        ;;
      *)
        if [[ ! $choice =~ ^[1-9][0-9]{0,8}$ ]] || (( choice > total )); then warn 'Enter a listed number.'; continue; fi
        SELECTED_ASSET=$(jq -c --argjson i "$choice" '.[$i-1]' <<< "$assets") || return 1
        name=$(field "$SELECTED_ASSET" name)
        if [[ -n $rule && $choice == "$default" ]]; then
          SELECTED_RULE=$rule
        else
          SELECTED_RULE=$(suggest_rule "$name" "$tag")
          matches=$(matching_assets "$assets" "$SELECTED_RULE" "$tag") || return 1
          if ! jq -e --arg n "$name" 'length == 1 and .[0].name == $n' <<< "$matches" >/dev/null; then
            SELECTED_RULE="(?-i)$SELECTED_RULE"
            matches=$(matching_assets "$assets" "$SELECTED_RULE" "$tag") || return 1
            if ! jq -e --arg n "$name" 'length == 1 and .[0].name == $n' <<< "$matches" >/dev/null; then
              warn 'Could not generate a unique rule. Use r to enter a regex.'
              continue
            fi
          fi
        fi
        ;;
    esac
    say "Selected $(field "$SELECTED_ASSET" name)   [${SELECTED_RULE:-automatic}]"
    return 0
  done
}

# A unit always runs the foreground program directly. Split quoted arguments once,
# then quote each systemd argument separately; no shell evaluates the command.
unit_text() {
  python3 - "$@" <<'PY'
import os, pwd, shlex, sys
unit, scope, directory, program, mode, *args = sys.argv[1:]
try:
    if mode == "split":
        args = shlex.split(args[0])
    if not os.path.isabs(program) or (directory != "~" and not os.path.isabs(directory)):
        raise ValueError("use an absolute binary path and an absolute working directory (or ~)")
    if any(any(ord(c) < 32 or ord(c) == 127 for c in value) for value in [unit, directory, program, *args]):
        raise ValueError("control characters are not valid in a unit")
    def quote(value):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"'
    print("# Managed by binup\n[Unit]\nDescription=Binup - " + unit)
    if mode == "split":
        print("ConditionFileIsExecutable=" + program.replace("%", "%%"))
    print("\n[Service]\nType=exec")
    if scope == "system":
        user = pwd.getpwnam(os.environ["SUDO_USER"]) if os.geteuid() == 0 and os.environ.get("SUDO_USER") else pwd.getpwuid(os.getuid())
        print("User=" + str(user.pw_uid))
    print("WorkingDirectory=" + directory.replace("%", "%%"))
    # systemd's ':' prefix keeps dollar expressions literal, including in argv[0].
    print("ExecStart=" + " ".join(map(quote, [":" + program, *args])))
    print("Restart=always\nRestartSec=5s\n\n[Install]")
    print("WantedBy=" + ("default.target" if scope == "user" else "multi-user.target"))
except (ValueError, KeyError) as error:
    sys.exit(f"Invalid service settings: {error}")
PY
}
unit_dir() {
  if [[ $1 == system ]]; then say /etc/systemd/system
  elif (( EUID == 0 )) && [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    as_login sh -c 'printf "%s/systemd/user\n" "${XDG_CONFIG_HOME:-$HOME/.config}"'
  else say "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; fi
}
unit_fs() {
  if [[ $scope == system ]]; then as_root "$@"; else as_login "$@"; fi
}
service_hint() {
  printf 'Inspect the service with: BINUP_CONF=%q bash %q status %q\n' "$CONF" "$LAUNCHER" "$app" >&2
  printf 'Read recent errors with: BINUP_CONF=%q bash %q logs %q\n' "$CONF" "$LAUNCHER" "$app" >&2
}
# The caller owns unit_created and staged_unit until registration commits.
create_unit() {
  local load dir unit=$svc.service
  dir=$(unit_dir "$scope") || return 1
  unit_file=$dir/$unit
  load=$(sctl "$scope" show --property=LoadState --value -- "$unit") || [[ $load == not-found ]] || return 1
  [[ $load == not-found && ! -e $unit_file && ! -L $unit_file ]] ||
    { fail "$unit already exists or is masked in $scope scope. Choose an existing service."; return 1; }
  unit_fs mkdir -p -- "$dir" || return 1
  staged_unit=$(unit_fs mktemp -- "$dir/.binup-unit.XXXXXXXX") || return 1
  unit_text "$unit" "$scope" "$working_dir" "$bin" split "$arguments" | unit_fs tee "$staged_unit" >/dev/null || return 1
  unit_fs chmod 0644 -- "$staged_unit" || return 1
  unit_fs ln -T -- "$staged_unit" "$unit_file" || return 1
  unit_created=1
  sctl "$scope" daemon-reload && sctl "$scope" enable -- "$unit"
}

add_app() (
  local app=${1:-} old bin svc scope ver repo rule channel tag_re member health release defaults picked=''
  local services=() create=0 staged_unit='' unit_file='' unit_created=0 saved=0 pending=false
  local working_dir='~' arguments='' options=() cancelled=0
  # shellcheck disable=SC2329
  cleanup_add() {
    if (( unit_created && ! saved )); then
      sctl "$scope" disable -- "$svc.service" || warn "Could not disable $svc."
      if ! unit_fs rm -f -- "$unit_file" || ! sctl "$scope" daemon-reload; then warn "Check the unit at $unit_file."; fi
    fi
    if [[ -n $staged_unit ]]; then unit_fs rm -f -- "$staged_unit"; fi
  }
  trap 'cleanup_add' EXIT
  trap 'exit 130' INT TERM HUP
  if [[ -z $app ]]; then ask 'App name' || return 1; app=$REPLY; fi
  [[ $app == *[![:space:]]* && $app != all && $app != -f && $app != --force && $app != *[[:cntrl:]]* ]] ||
    { fail "Choose an app name without control characters. The names all, -f and --force are reserved."; return 1; }
  old=$(entry_for "$app") || return 1
  svc=$(field "$old" service); scope=$(field "$old" scope); scope=${scope:-system}
  bin=$(field "$old" bin); ver=$(field "$old" version); repo=$(field "$old" repo)
  rule=$(field "$old" asset_regex); channel=$(field "$old" release_channel); channel=${channel:-stable}
  tag_re=$(field "$old" tag_regex); member=$(field "$old" archive_member); health=$(field "$old" health_url)

  choose 'Service setup' 1 'Find or enter an existing service' 'Create a new service' 'No service' || return 1
  case $REPLY in
    1)
      mapfile -t services < <(find_services "$app")
      if [[ -n $svc ]]; then picked="$scope $svc"
      elif (( ${#services[@]} == 1 )); then picked=${services[0]}
      elif (( ${#services[@]} > 1 )); then
        options=("${services[@]}" 'Enter a service name')
        choose 'Existing service' '' "${options[@]}" || return 1
        if (( REPLY <= ${#services[@]} )); then picked=${services[REPLY-1]}; fi
      fi
      if [[ -n $picked ]]; then scope=${picked%% *}; svc=${picked#* }; svc=${svc%.service}; fi
      ask 'Service (blank = none)' "$svc" || return 1; svc=${REPLY%.service} ;;
    2)
      create=1; scope=user
      ask 'New service name' "${svc:-$app}" '[]' '' true || return 1; svc=${REPLY%.service}
      [[ -n $svc ]] || { fail 'A new service needs a name.'; return 1; } ;;
    3) svc='';;
  esac
  if [[ -n $svc ]]; then
    ask 'Service scope (system/user)' "$scope" '["user","system"]' '' true 'Service scope' || return 1; scope=$REPLY
    valid_service "$svc" "$scope" || { fail 'Enter one service name and a scope of system or user.'; return 1; }
    if (( ! create )) && [[ -z $bin ]]; then bin=$(svc_bin "$scope" "$svc.service"); fi
  fi
  [[ -n $bin ]] || bin=$(type -P -- "$app")
  ask 'Binary path' "$bin" '[]' '' true || return 1; bin=${REPLY/#\~/$HOME}
  [[ -n $bin ]] || { fail 'A binary path is required.'; return 1; }
  if (( create )); then
    bin=$(realpath -ms -- "$bin") || return 1
    ask 'Startup arguments (blank = none)' || return 1; arguments=$REPLY
    ask 'Working directory (~ = service user home)' '~' || return 1; working_dir=$REPLY
    say "Will enable $svc.service in $scope scope with automatic restart."
    if [[ ! -f $bin || ! -x $bin ]]; then pending=true; say 'The first successful update will start it.'; fi
  fi
  if [[ -z $ver && -x $bin ]]; then ver=$(detect_version "$bin"); fi
  ask 'Installed version (blank = unknown)' "$ver" || return 1; ver=$REPLY
  ask 'GitHub repo (owner/repo or URL)' "$repo" '[]' '' true || return 1
  repo=$(sed -E 's#^(https?://)?(www\.)?github\.com/##; s#/*$##; s#\.git$##' <<< "$REPLY" | cut -d/ -f1,2)
  [[ $repo =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || { fail 'Invalid GitHub repository.'; return 1; }

  say "Channel $channel, tag filter ${tag_re:-any}, archive member ${member:-auto}, health URL ${health:-none}"
  ask 'Change these settings? [y/N]' '' '[{"value":"","label":"Keep current settings"},{"value":"y","label":"Change settings"}]' \
    "Channel: $channel · Tag filter: ${tag_re:-any} · Archive member: ${member:-auto} · Health URL: ${health:-none}" false 'Release settings' || return 1
  if [[ $REPLY == [yY] || $REPLY == [yY][eE][sS] ]]; then
    ask 'Release channel (stable/prerelease/any)' "$channel" '["stable","prerelease","any"]' '' true 'Release channel' || return 1; channel=$REPLY
    ask 'Tag regex (blank = any tag)' "$tag_re" || return 1; tag_re=$REPLY
    ask 'Archive member (blank = auto)' "$member" || return 1; member=$REPLY
    ask 'Health URL (blank = systemd only)' "$health" || return 1; health=$REPLY
  fi
  release=$(get_release "$repo" "$channel" "$tag_re") || { fail "Could not select a release for $repo."; return 1; }
  say "Release $(field "$release" tag_name)"
  select_asset pick "$release" "$rule" || return 1

  defaults=$(jq -cn --arg bin "$bin" --arg service "$svc" --arg scope "$scope" --arg version "$ver" \
    --arg repo "$repo" --arg asset_regex "$SELECTED_RULE" --arg release_channel "$channel" \
    --arg tag_regex "$tag_re" --arg archive_member "$member" --arg health_url "$health" '$ARGS.named') || return 1
  # Keep the unit and the registry in sync if interrupted between the two writes.
  trap 'cancelled=1' INT TERM HUP
  if (( create )); then create_unit || return 1; fi
  (( ! cancelled )) || return 130
  save_config --arg n "$app" --argjson settings "$defaults" --argjson pending "$pending" '
    .[$n] |= ((. // {}) as $old | $old + $settings
      | if $pending then .start_after_install=true
        elif any(["bin","service","scope"][]; $old[.] != $settings[.]) then del(.start_after_install) else . end
      | if any(["repo","bin","asset_regex","archive_member"][]; ($old[.] // "") != $settings[.])
        then del(.asset_sha256, .binary_sha256, .archive_selector) else . end
      | if .release_channel == "stable" then del(.release_channel) else . end
      | with_entries(select((.key == "tag_regex" or .key == "archive_member" or .key == "health_url")
                            and .value == "" | not)))' || return 1
  saved=1
  ok "Saved '$app'."
  if (( cancelled )); then
    if (( create )) && [[ $pending == false ]]; then say "Use List → $app → Start to start its new service."; fi
    return 130
  fi
  trap 'exit 130' INT TERM HUP
  if (( create )) && [[ $pending == false ]]; then
    say "Starting $scope service $svc."
    local interrupted=0
    svc=$svc.service
    start_checked || { service_hint; return 1; }
  fi
)

file_kind() {
  case ${1,,} in
    *.tar|*.tar.*|*.tgz|*.tbz|*.tbz2|*.txz|*.tzst) say tar ;;
    *.zip) say zip ;; *.gz) say gz ;; *.xz) say xz ;; *.bz2) say bz2 ;; *.zst) say zst ;;
    *) say raw ;;
  esac
}

# Read only the selected regular member into a fixed output file. Archive paths
# never become filesystem destinations. Inspect headers without running the build.
unpack() {
  python3 - "$@" <<'PY'
import bz2
import gzip
import lzma
import shutil
import stat
import subprocess
import sys
import tarfile
import zipfile
from pathlib import PurePosixPath

source, output, kind, filename, basename, member = sys.argv[1:]
with open("/proc/self/exe", "rb") as stream:
    host = stream.read(64)

def executable(header):
    if header.startswith(b"#!"):
        return bool(header[2:].split(b"\n", 1)[0].strip())
    byteorder = "little" if host[5] == 1 else "big"
    return (len(header) >= 52 and header[:7] == host[:7]
            and header[18:20] == host[18:20]
            and int.from_bytes(header[16:18], byteorder) in (2, 3)
            and any(header[24:28] if host[4] == 1 else header[24:32]))

def copy_stream(stream):
    header = stream.read(64)
    if not executable(header):
        raise ValueError("selected file is not a native Linux ELF executable or a shebang script")
    with open(output, "wb") as out:
        out.write(header)
        shutil.copyfileobj(stream, out)

def from_archive(files, open_member):
    # Keep member objects, so duplicate filenames are detected as well.
    if member:
        matches = [item for path, item in files if PurePosixPath(path) == PurePosixPath(member)]
    else:
        matches = [item for path, item in files if PurePosixPath(path).name == basename]
        if not matches:
            matches = []
            for path, item in files:
                with open_member(item) as stream:
                    if executable(stream.read(64)):
                        matches.append(item)
    if len(matches) != 1:
        names = ", ".join(path for path, _ in files)
        raise ValueError(f"{len(matches)} matching archive members. Set archive_member using edit. Files: {names}")
    with open_member(matches[0]) as stream:
        copy_stream(stream)

try:
    if kind == "tar":
        # Python reads tar/gzip/bzip2/xz directly. Other compressors are optional.
        suffix = filename.lower().rsplit(".", 1)[-1]
        program = {"zst": "zstd", "tzst": "zstd", "lz": "lzip", "lzo": "lzop",
                   "lz4": "lz4", "z": "gzip"}.get(suffix)
        if program:
            tar_path = source + ".tar"
            with open(tar_path, "wb") as dest:
                subprocess.run([program, "-dc", source], stdout=dest, check=True)
            source = tar_path
        with tarfile.open(source, "r:*") as archive:
            files = [(item.name, item) for item in archive if item.isfile()]
            from_archive(files, archive.extractfile)
    elif kind == "zip":
        with zipfile.ZipFile(source) as archive:
            files = [(item.filename, item) for item in archive.infolist()
                     if not item.is_dir() and stat.S_IFMT(item.external_attr >> 16) in (0, stat.S_IFREG)]
            from_archive(files, archive.open)
    elif kind in ("raw", "zst"):
        if kind == "zst":
            with open(output, "wb") as dest:
                subprocess.run(["zstd", "-dc", source], stdout=dest, check=True)
        with open(output, "rb") as stream:
            if not executable(stream.read(64)):
                raise ValueError("invalid executable for this host")
    else:
        opener = {"gz": gzip.open, "xz": lzma.open, "bz2": bz2.open}[kind]
        with opener(source, "rb") as stream:
            copy_stream(stream)
except (OSError, ValueError, EOFError, RuntimeError, tarfile.TarError, zipfile.BadZipFile,
        lzma.LZMAError, subprocess.CalledProcessError) as exc:
    sys.exit(f"Could not unpack {filename}: {exc}")
PY
}

hash_file() {
  local hash
  hash=$(sha256sum < "$1") || return 1
  say "${hash%% *}"
}

# These functions use the app settings and digests read by process_app.
record_build() {
  save_config --arg n "$app" --arg tag "$tag" --arg rule "$SELECTED_RULE" \
    --arg asset "$asset_hash" --arg binary "$binary_hash" --arg selector "$archive_selector" '
    .[$n] |= (. + {version: $tag, asset_regex: $rule, asset_sha256: $asset, binary_sha256: $binary}
      | del(.start_after_install) | if $selector == "" then del(.archive_selector) else .archive_selector = $selector end)'
}

start_checked() {
  local deadline
  say "Waiting for $scope service $svc to ${1:-start}."
  sctl "$scope" "${1:-start}" -- "$svc" || return 1
  if [[ -z $health ]]; then
    sleep 2
    sctl "$scope" is-active --quiet -- "$svc"
    return
  fi
  say "Waiting for the HTTP health check for $svc."
  deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    (( ! interrupted )) || return 130
    if sctl "$scope" is-active --quiet -- "$svc" &&
       [[ $(curl --proto '=http,https' -s --max-time 2 -o /dev/null -w '%{http_code}' -- "$health") == 2?? ]]; then
      return 0
    fi
    sleep 1
  done
  fail "$svc did not pass its HTTP health check."
}

install_build() (
  local source=$1 dir stage state had_old=0 was_active=0 stopped=0 swapped=0 committed=0 interrupted=0
  local priv=() stop_requested=0 start_attempted=0
  say "Staging the new binary and preparing the backup for $bin."
  dir=$(dirname -- "$bin")
  if [[ ! -d $dir ]]; then mkdir -p -- "$dir" 2>/dev/null || as_root mkdir -p -- "$dir" || return 1; fi
  if (( EUID != 0 )) && [[ ! -w $dir || ( -e $bin && ! -O $bin ) ]]; then priv=(as_root); fi
  stage=$("${priv[@]}" mktemp -d -- "$dir/.binup.XXXXXXXX") || return 1

  # shellcheck disable=SC2329  # Called by the subshell's EXIT trap.
  cleanup_install() {
    local rc=$? restored=1 recovery=start actual
    if (( interrupted && ! committed )); then rc=130; fi
    trap - EXIT
    trap '' HUP INT TERM
    interrupted=0
    if (( rc != 0 && ! committed )); then
      if (( swapped )); then
        warn "Restoring the previous installation of $app."
        if (( start_attempted )) && ! sctl "$scope" stop -- "$svc"; then
          warn "Could not stop $svc. Will restart it after restoring the binary."
          recovery=restart
        fi
        if (( had_old )); then
          "${priv[@]}" mv -fT -- "$bin.bak" "$bin" || restored=0
        else
          "${priv[@]}" rm -f -- "$bin" || restored=0
        fi
      fi
      if (( stop_requested && ! stopped )); then
        actual=$(sctl "$scope" show --property=ActiveState --value -- "$svc") || actual=unknown
        case $actual in
          active|reloading) say "$svc is still active with the previous binary." ;;
          inactive|failed) stopped=1 ;;
          deactivating)
            warn "$svc is still stopping. Requesting a start with the previous binary."
            sctl "$scope" start --no-block -- "$svc" || warn "Could not queue the start for $svc."
            service_hint ;;
          *) warn "Stop did not complete. Current service state: $actual"; service_hint ;;
        esac
      fi
      if (( ! restored )); then warn "Could not restore $bin. Inspect $bin.bak."; service_hint
      elif (( stopped )); then
        say "Bringing the previously active $svc back up."
        start_checked "$recovery" || { warn "The previous binary is in place, but $svc did not pass its start check."; service_hint; }
      fi
    fi
    "${priv[@]}" rm -rf -- "$stage" || warn "Could not remove staging directory $stage."
    exit "$rc"
  }
  trap 'cleanup_install' EXIT
  trap 'interrupted=1' HUP INT TERM

  "${priv[@]}" install -m 0755 -- "$source" "$stage/new" || return 1
  if [[ -e $bin ]]; then
    had_old=1
    "${priv[@]}" chown --reference="$bin" -- "$stage/new" &&
      "${priv[@]}" chmod --reference="$bin" -- "$stage/new" &&
      "${priv[@]}" cp -p -- "$bin" "$stage/old" || return 1
    if [[ ! -x $bin ]]; then "${priv[@]}" chmod +x -- "$stage/new" || return 1; fi
  fi
  if [[ -n $svc ]]; then
    state=$(sctl "$scope" show --property=LoadState,ActiveState -- "$svc") || return 1
    if ! grep -Eq '^LoadState=(loaded|masked)$' <<< "$state"; then
      fail "Could not load $scope service $svc. Use Edit to find or create the correct unit."; return 1
    fi
    case $'\n'$state$'\n' in
      *$'\nActiveState=active\n'*|*$'\nActiveState=reloading\n'*) was_active=1 ;;
      *$'\nActiveState=inactive\n'*|*$'\nActiveState=failed\n'*) ;;
      *) fail "$svc is changing state. Inspect its status and logs. If it keeps restarting, stop it in List before retrying."
         service_hint; return 1 ;;
    esac
    if (( was_active && ! had_old )); then
      fail "$svc is running and $bin is missing. Check its binary path before stopping it."
      return 1
    fi
  fi
  if (( had_old )); then "${priv[@]}" mv -fT -- "$stage/old" "$bin.bak" || return 1; fi
  (( ! interrupted )) || return 130
  if (( was_active )); then
    say "Stopping $scope service $svc and waiting for shutdown. An interrupt cancels the update after shutdown."
    printf '  To watch the shutdown, open Logs in the web UI or run: BINUP_CONF=%q bash %q logs %q --follow\n' "$CONF" "$LAUNCHER" "$app"
    stop_requested=1
    (trap '' INT HUP TERM; sctl "$scope" stop -- "$svc") ||
      { fail "systemctl could not finish stopping $svc."; service_hint; return 1; }
    stopped=1
  fi
  (( ! interrupted )) || return 130
  say "Replacing $bin."
  "${priv[@]}" mv -fT -- "$stage/new" "$bin" || { fail "Could not replace $bin."; return 1; }
  swapped=1
  if command -v restorecon >/dev/null; then "${priv[@]}" restorecon "$bin" || return 1; fi
  if (( was_active )) || [[ $pending == true ]]; then
    start_attempted=1
    start_checked || { fail "$svc failed after installing $tag."; service_hint; return 1; }
  fi
  (( ! interrupted )) || return 130
  record_build || { fail "Could not commit $CONF."; return 1; }
  committed=1
  if (( had_old )); then ok "$app updated to $tag (backup $bin.bak)."; else ok "$app installed at $bin ($tag)."; fi
)

process_app() (
  local mode=$1 app=$2 entry='' tag='' reason='' tmp='' rc
  process_build; rc=$?
  if [[ -n ${BINUP_PROMPT_FD:-} && $rc != 130 && $rc != 143 && $rc != 129 && -n $entry ]]; then
    if [[ $mode == update && $rc == 0 ]]; then entry=$(entry_for "$app") || return 1; fi
    jq -nc --arg app "$app" --arg tag "$tag" --arg reason "$reason" --argjson entry "$entry" --argjson code "$rc" \
      '{type:"result",app:$app,tag:$tag,reason:$reason,entry:$entry,code:$code}' >&"$BINUP_PROMPT_FD" || return 1
  fi
  return "$rc"
)

process_build() {
  local bin basename svc scope repo rule channel tag_re member health
  local release asset_hash binary_hash local_hash='' expected='' name kind url payload
  local previous saved_asset saved_binary saved_selector archive_selector='' pending interrupted=0
  local progress=(-sS)
  entry=$(entry_for "$app") || return 1
  [[ $entry != '{}' ]] || { fail "'$app' is not registered."; return 1; }
  bin=$(field "$entry" bin); repo=$(field "$entry" repo)
  [[ -n $bin && -n $repo ]] || { fail "$app needs a binary path and repository."; return 1; }
  basename=$(basename -- "$bin")
  bin=$(realpath -m -- "$bin") || return 1
  if [[ -e $bin && ! -f $bin ]]; then fail "$bin is not a regular file."; return 1; fi
  svc=$(field "$entry" service); scope=$(field "$entry" scope); scope=${scope:-system}
  if [[ -n $svc ]]; then
    valid_service "$svc" "$scope" || { fail "Invalid service '$svc' or scope '$scope'. Use Edit to correct it."; return 1; }
    svc="${svc%.service}.service"
  fi
  channel=$(field "$entry" release_channel); channel=${channel:-stable}
  rule=$(field "$entry" asset_regex); tag_re=$(field "$entry" tag_regex)
  member=$(field "$entry" archive_member); health=$(field "$entry" health_url)
  pending=$(jq -r '(.start_after_install == true) and ((.service // "") != "")' <<< "$entry")
  previous=$(field "$entry" version); saved_asset=$(field "$entry" asset_sha256)
  saved_binary=$(field "$entry" binary_sha256); saved_selector=$(field "$entry" archive_selector)

  say "$app ($repo)"
  release=$(get_release "$repo" "$channel" "$tag_re") || { fail "$app: release lookup failed."; return 1; }
  tag=$(field "$release" tag_name)
  select_asset "$mode" "$release" "$rule" || return 1
  name=$(field "$SELECTED_ASSET" name); url=$(field "$SELECTED_ASSET" browser_download_url)
  asset_hash=$(field "$SELECTED_ASSET" digest)
  [[ $asset_hash =~ ^sha256:([[:xdigit:]]{64})$ ]] || { fail "$name has no published SHA-256 digest."; return 1; }
  asset_hash=${BASH_REMATCH[1],,}
  kind=$(file_kind "$name")
  if [[ $kind == tar || $kind == zip ]]; then
    if [[ -n $member ]]; then archive_selector="path:$member"; else archive_selector="basename:$basename"; fi
  fi
  if [[ $kind == raw ]]; then expected=$asset_hash
  elif [[ $asset_hash == "$saved_asset" && $archive_selector == "$saved_selector" ]]; then expected=$saved_binary
  fi
  if [[ -f $bin ]]; then local_hash=$(hash_file "$bin") || return 1; fi

  if [[ $local_hash && $local_hash == "$expected" && -x $bin ]] && [[ $mode == check || $FORCE == 0 ]]; then
    binary_hash=$local_hash
    if [[ $pending == true ]]; then
      if [[ $mode == check ]]; then reason="Service awaiting first start"; say "$app is verified; $svc is awaiting its first start."; return 10; fi
      start_checked || { service_hint; return 1; }
    fi
    if [[ $mode == update && ( $pending == true || $previous != "$tag" || $saved_asset != "$asset_hash" || $saved_binary != "$binary_hash" || $rule != "$SELECTED_RULE" ) ]]; then
      record_build || return 1
      ok "$app already has $tag. Saved the verified build details."
    else
      ok "$app is up to date ($tag, $name)."
    fi
    return 0
  fi
  if [[ $mode == update && $FORCE == 1 ]]; then reason='forced reinstall'
  elif [[ ! -f $bin ]]; then reason='binary missing'
  elif [[ $previous != "$tag" ]]; then reason="${previous:-unknown} → $tag"
  elif [[ -z $saved_asset && $kind != raw ]]; then reason='archive baseline needed'
  elif [[ -n $saved_asset && $saved_asset != "$asset_hash" ]]; then reason='release file changed under the same tag'
  elif [[ ! -x $bin ]]; then reason='installed file is not executable'
  elif [[ -n $expected ]]; then reason="installed SHA-256 ${local_hash:0:12}… differs from expected ${expected:0:12}…"
  else reason='archive contents need verification'
  fi
  say "  $tag / $name ($reason)"
  [[ $mode != check ]] || return 10

  tmp=$(mktemp -d) || return 1
  trap 'rm -rf -- "$tmp"' EXIT
  say "Downloading $name."
  if [[ -t 2 || -n ${BINUP_WEB:-} ]]; then progress=(--progress-bar -S); fi
  curl --proto '=https' --proto-redir '=https' -fL "${progress[@]}" --retry 2 --connect-timeout 10 --speed-time 60 --speed-limit 1 -o "$tmp/download" -- "$url" ||
    { fail "$app: download failed for $name."; return 1; }
  local downloaded_hash
  say 'Verifying SHA-256 and checking the executable.'
  downloaded_hash=$(hash_file "$tmp/download") || return 1
  [[ $downloaded_hash == "$asset_hash" ]] || { fail "$name: SHA-256 mismatch."; return 1; }
  payload=$tmp/binary
  if [[ $kind == raw ]]; then payload=$tmp/download; fi
  unpack "$tmp/download" "$payload" "$kind" "$name" "$basename" "$member" || return 1
  binary_hash=$asset_hash
  if [[ $kind != raw ]]; then binary_hash=$(hash_file "$payload") || return 1; fi
  if (( ! FORCE )) && [[ $binary_hash == "$local_hash" && -x $bin ]]; then
    if [[ $pending == true ]]; then start_checked || { service_hint; return 1; }; fi
    record_build || return 1
    ok "$app already has the verified binary for $tag. Build details saved."
  else
    install_build "$payload"
  fi
}

run_apps() {
  local mode=$1 target=${2:-all} keys app rc result=0 names=() failures=()
  if [[ $target != all ]]; then process_app "$mode" "$target"; return; fi
  keys=$(config -r 'keys[]') || return 1
  [[ -n $keys ]] || { say 'No apps registered.'; return 0; }
  mapfile -t names <<< "$keys"
  # Keep stdin attached to the terminal when an app needs a new build selection.
  for app in "${names[@]}"; do
    process_app "$mode" "$app"; rc=$?
    case $rc in
      0) ;;
      129|130|143) warn 'Operation interrupted.'; return "$rc" ;;
      10) (( result != 0 )) || result=10 ;;
      *) result=1; failures+=("$app") ;;
    esac
  done
  if (( ${#failures[@]} )); then warn "Failed: ${failures[*]}"; fi
  return "$result"
}

list_data() {
  local rows row svc scope unit properties key value load active sub result state
  rows=$(config -c 'to_entries | sort_by(.key)[] |
    {name:.key, version:(.value.version // ""), service:(.value.service // ""),
     scope:(.value.scope // "system"), repo:.value.repo, bin:.value.bin,
     pending:(.value.start_after_install == true)}') || return 1
  while IFS= read -r row; do
    [[ -n $row ]] || continue
    svc=$(field "$row" service); scope=$(field "$row" scope)
    state='no service'; sub=''; result=''; load=''; active=''
    if [[ -n $svc ]] && ! valid_service "$svc" "$scope"; then
      state='invalid service'
    elif [[ -n $svc ]]; then
      unit="${svc%.service}.service"
      properties=$(sctl "$scope" show --property=LoadState,ActiveState,SubState,Result -- "$unit" 2>/dev/null) || :
      while IFS='=' read -r key value; do
        case $key in LoadState) load=$value ;; ActiveState) active=$value ;; SubState) sub=$value ;; Result) result=$value ;; esac
      done <<< "$properties"
      case $load in
        loaded) state=${active:-unavailable} ;;
        not-found) state=missing ;;
        '') state=unavailable ;;
        *) state=$load ;;
      esac
    fi
    jq -c --arg state "$state" --arg sub "$sub" --arg result "$result" '. + {state:$state,sub:$sub,result:$result}' <<< "$row" || return 1
  done <<< "$rows"
}
list_apps() {
  local data
  data=$(list_data | jq -s '.') || return 1
  if [[ ${1:-} == --json ]]; then say "$data"; return; fi
  jq -r '(["NAME","VERSION","SERVICE","SCOPE","STATE","BINARY","REPO"],
    (.[] | [.name,.version,.service,(if .service != "" then .scope else "" end),
    (.state + (if .state == "failed" and .result != "" then "/" + .result
               elif .sub != "" and .state != "missing" then "/" + .sub
                 + (if .sub == "auto-restart" and .result != "" then " (" + .result + ")" else "" end)
               else "" end)
            + (if .pending then " (awaiting install)" else "" end)),.bin,.repo]))
    | map(if . == "" or . == null then "-" else . end) | @tsv' <<< "$data" |
    if command -v column >/dev/null; then column -t -s $'\t'; else cat; fi
}
service_command() {
  local app=$1 op=$2 entry svc scope unit health interrupted=0
  local journal=(--no-pager -n 100 -o short-iso)
  entry=$(entry_for "$app") || return 1
  svc=$(field "$entry" service); scope=$(field "$entry" scope); scope=${scope:-system}
  [[ -n $svc ]] || { fail "'$app' has no registered service."; return 1; }
  valid_service "$svc" "$scope" || { fail "Invalid service '$svc' or scope '$scope'. Use Edit to correct it."; return 1; }
  unit="${svc%.service}.service"
  case $op in
    status) sctl "$scope" status --no-pager --full -- "$unit" ;;
    logs)
      if [[ ${3:-} == --follow ]]; then journal+=(--follow)
      elif [[ ${3:-} =~ ^--since=@[0-9]{1,12}\.[0-9]{6}$ ]]; then journal+=(--quiet "$3"); fi
      if [[ $scope == user ]]; then as_login journalctl "--user-unit=$unit" "${journal[@]}"
      else journalctl "--unit=$unit" "${journal[@]}"; fi ;;
    start|restart|stop)
      say "$op $scope service $unit"
      if [[ $op == stop ]]; then sctl "$scope" stop -- "$unit" || { service_hint; return 1; }
      else
        health=$(field "$entry" health_url)
        svc=$unit
        start_checked "$op" || { service_hint; return 1; }
      fi
      if jq -e '.start_after_install == true' <<< "$entry" >/dev/null; then
        save_config --arg n "$app" 'del(.[$n].start_after_install)' || return 1
      fi
      ok "$unit: $op completed." ;;
    *) fail 'Use service NAME start, stop or restart.' ;;
  esac
}
list_menu() {
  local names=() keys app op
  list_apps || return 1
  keys=$(config -r 'to_entries | sort_by(.key)[] | select((.value.service // "") != "") | .key') || return 1
  [[ -n $keys ]] || return 0
  mapfile -t names <<< "$keys"
  choose 'Inspect service or return' "$((${#names[@]} + 1))" "${names[@]}" Back || return 1
  (( REPLY <= ${#names[@]} )) || return 0
  app=${names[REPLY-1]}
  while choose "$app service action" 7 'Status' 'Recent logs' 'Follow logs (Ctrl+C to leave)' 'Start' 'Restart' 'Stop' 'Back'; do
    case $REPLY in
      1) service_command "$app" status ;;
      2) service_command "$app" logs ;;
      3) (trap 'exit 130' INT; service_command "$app" logs --follow) ;;
      4|5|6) case $REPLY in 4) op=start ;; 5) op=restart ;; 6) op=stop ;; esac
             mutate service_command "$app" "$op" ;;
      7) return 0 ;;
    esac
  done
}

remove_app() {
  config -e --arg n "$1" 'has($n)' >/dev/null || { fail "'$1' is not registered."; return 1; }
  save_config --arg n "$1" 'del(.[$n])' && ok "Removed '$1'."
}
pick_app() {
  local keys list=()
  keys=$(config -r 'keys[]') || return 1
  [[ -n $keys ]] || { fail 'No apps registered.'; return 1; }
  mapfile -t list <<< "$keys"
  PS3='App: '
  select PICKED in "${list[@]}" 'Cancel'; do
    [[ $REPLY != "$((${#list[@]} + 1))" ]] || return 1
    [[ -n $PICKED ]] && return 0
  done
  return 1
}

menu() {
  local action REPLY
  while :; do
    PS3='binup> '
    select action in 'Add app' 'Update one' 'Update all' 'Check for updates' 'List' 'Edit' 'Remove' 'Quit' 'Web UI'; do break; done || return 0
    case $action in
      'Add app') mutate add_app ;;
      'Update one') pick_app && mutate run_apps update "$PICKED" ;;
      'Update all') mutate run_apps update all ;;
      'Check for updates') run_apps check all ;;
      'List') list_menu ;;
      'Edit') pick_app && mutate add_app "$PICKED" ;;
      'Remove') pick_app && mutate remove_app "$PICKED" ;;
      'Web UI') web_menu ;;
      'Quit') return 0 ;;
      *) [[ $REPLY != q ]] || return 0 ;;
    esac
  done
}

web_menu() {
  while choose 'Web UI action' 4 'Install the web service and Cockpit page' 'Show service status' 'Uninstall the web service and Cockpit page' 'Back'; do
    case $REPLY in
      1) ask 'Registry file for the web UI' "$CONF" && bash "$LAUNCHER" web-install "$REPLY" ;;
      2) sctl user status --no-pager --full -- binup-web.service ;;
      3) choice 'Remove the web service and Cockpit page? [y/N]' n && [[ $REPLY == [yY]* ]] && web_setup web-uninstall "$CONF" ;;
      4) return 0 ;;
    esac
  done
}

installed_web_config() {
  local dir unit
  dir=$(unit_dir user) || return 1
  unit=$dir/binup-web.service
  [[ -f $unit ]] && grep -Fxq '# Generated by binup web-install' "$unit" || return 0
  python3 - "$unit" <<'PY'
import shlex, sys
from pathlib import Path
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("ExecStart="):
        argv = shlex.split(line[len("ExecStart="):])
        if "--config" in argv and argv.index("--config") + 1 < len(argv):
            print(argv[argv.index("--config") + 1].replace("%%", "%"))
            break
else:
    sys.exit("Could not read the installed registry path. Pass its path to install or web-install.")
PY
}

cockpit_package() {
  local action=$1 source=${SELF%/*}/web folder="${XDG_DATA_HOME:-$HOME/.local/share}/cockpit" link
  link=$folder/binup
  if [[ $action == install ]] && ! command -v cockpit-bridge >/dev/null &&
     [[ ! -e /usr/share/cockpit/shell/manifest.json && ! -x /usr/lib/cockpit/cockpit-ws && ! -x /usr/libexec/cockpit-ws ]]; then
    say 'Cockpit was not detected. To add the page later, rerun web-install after installing Cockpit.'
    return 0
  fi
  if [[ -e $link || -L $link ]]; then
    if [[ ! -L $link ]] || { [[ $(readlink -- "$link") != "$source" ]] &&
        ! jq -e '."x-binup-package" == true' "$link/manifest.json" >/dev/null 2>&1; }; then
      fail "An unrelated Cockpit package owns $link. It was left in place."; return 1
    fi
  fi
  if [[ $action == remove ]]; then
    if [[ -L $link ]]; then rm -- "$link" || return 1; fi
    return 0
  fi
  mkdir -p -- "$folder" && ln -sfnT -- "$source" "$link" || return 1
  ok 'Cockpit page installed for this user. Open System → Binup in the left menu.'
}

# A loose script can fetch a complete, matching runtime without Git. Old
# snapshots also let an already-running command finish with its original files.
install_latest() (
  local directory=${LAUNCHER%/*} store="${XDG_DATA_HOME:-$HOME/.local/share}/binup-runtime"
  local temp archive revision release prefix launcher="$directory/binup.sh" origin
  (( EUID != 0 )) || { fail 'Run install as the user who owns the apps.'; return 1; }
  if [[ -e $directory/.git ]] && command -v git >/dev/null; then
    origin=$(git -C "$directory" config --get remote.origin.url)
    if [[ $origin =~ ^(https://github\.com/|git@github\.com:)Whatevser/binup(\.git)?/?$ ]]; then
      [[ $(git -C "$directory" branch --show-current) == main ]] || { fail 'Run web-install for this checkout, or switch to main to upgrade.'; return 1; }
      git -C "$directory" fetch origin main || return 1
      if [[ $CONF == "$directory/binup.json" && -f $CONF ]] && ! git -C "$directory" diff --quiet HEAD FETCH_HEAD -- binup.json; then
        fail "Upstream also changed binup.json. Keep your live config when merging this checkout."; return 1
      fi
      git -C "$directory" merge --ff-only FETCH_HEAD || return 1
      bash "$launcher" web-install "$CONF"; return
    fi
  fi
  mkdir -p -- "$store" || return 1
  exec 8>"$store/install.lock" || return 1
  flock -n 8 || { fail 'Another Binup installation is running.'; return 1; }
  revision=$(gh 'repos/Whatevser/binup/git/ref/heads/main' |
    jq -er '.object | select(.type == "commit") | .sha | select(test("^[0-9a-f]{40}$"))') ||
    { fail 'Could not read the current Binup commit from GitHub.'; return 1; }
  release=$store/$revision
  if [[ ! -d $release ]]; then
    say "Downloading Binup ${revision:0:7} and its web interface."
    temp=$(mktemp -d -- "$store/.install.XXXXXXXX") || return 1
    trap 'rm -rf -- "$temp"' EXIT
    archive=$temp/source.tar.gz
    curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 --connect-timeout 10 --max-time 120 \
      -o "$archive" -- "https://codeload.github.com/Whatevser/binup/tar.gz/$revision" || return 1
    mkdir -- "$temp/code" || return 1
    prefix=binup-$revision
    tar -xzf "$archive" -C "$temp/code" --strip-components=1 -- "$prefix/binup.sh" "$prefix/binup_web.py" "$prefix/web" || return 1
    bash -n "$temp/code/binup.sh" && jq -e '."x-binup-package" == true' "$temp/code/web/manifest.json" >/dev/null &&
      mv -T -- "$temp/code" "$release" || return 1
  fi
  bash "$release/binup.sh" web-install "$CONF" || return 1
  if [[ $directory != "$release" && $directory != "$store/"* ]]; then
    ln -sfnT -- "$release/binup.sh" "$launcher" || return 1
    ok "Updated $launcher."
  fi
)

web_setup() (
  local action=$1 config_path=$2 folder unit path draft='' load base=${SELF%/*} python existing=0 asset
  (( EUID != 0 )) || { fail 'Run web setup as the user who owns the apps.'; return 1; }
  folder=$(unit_dir user) || return 1
  unit=binup-web.service; path=$folder/$unit
  if [[ -e $path || -L $path ]]; then
    if [[ -L $path || ! -f $path ]] || ! grep -Fxq '# Generated by binup web-install' "$path"; then
      fail "$path belongs to another service. Inspect it before installing."; return 1
    fi
    existing=1
  elif [[ $action != web-uninstall ]]; then
    load=$(sctl user show --property=LoadState --value -- "$unit") || [[ $load == not-found ]] || return 1
    [[ $load == not-found ]] || { fail "An existing user unit owns $unit."; return 1; }
  fi
  if [[ $action == web-uninstall ]]; then
    if (( existing )); then sctl user disable --now -- "$unit" && rm -- "$path" && sctl user daemon-reload || return 1; fi
    cockpit_package remove && ok 'Web service and Cockpit page removed.'; return
  fi
  if [[ ! -f $base/binup_web.py ]]; then install_latest; return; fi
  for asset in index.html app.js entry.js standalone.js style.css cockpit.css manifest.json; do
    [[ -f $base/web/$asset ]] || { fail "Missing web/$asset. Run bash binup.sh install to get the complete release."; return 1; }
  done
  config_path=$(realpath -m -- "$config_path") || return 1
  python=$(type -P python3) || return 1
  mkdir -p -- "$folder" || return 1
  draft=$(mktemp -- "$folder/.binup-web.XXXXXXXX") || return 1
  trap 'rm -f -- "$draft"' EXIT
  {
    say '# Generated by binup web-install'
    unit_text "$unit" user '~' "$python" argv "$base/binup_web.py" serve --config "$config_path" || return 1
    printf '\n[Service]\nKillMode=mixed\nTimeoutStopSec=5min\n'
  } > "$draft" || return 1
  chmod 0644 -- "$draft" || return 1
  if (( existing )); then mv -fT -- "$draft" "$path" || return 1
  else ln -T -- "$draft" "$path" || return 1; fi
  if ! sctl user daemon-reload || ! sctl user enable -- "$unit" || ! sctl user restart -- "$unit"; then
    fail "Web setup failed. Run journalctl --user-unit=$unit -n 50 --no-pager"; return 1
  fi
  sleep 1
  sctl user is-active --quiet -- "$unit" ||
    { fail "Web startup failed. Run journalctl --user-unit=$unit -n 50 --no-pager"; return 1; }
  ok "Open http://<LAN-or-VPN-IP>:9098/ on your private network."
  say "Config: $config_path"
  cockpit_package install
)

FORCE=0
args=()
for arg in "$@"; do
  case $arg in -f|--force) FORCE=1 ;; *) args+=("$arg") ;; esac
done
set -- "${args[@]}"
case ${1:-} in -h|--help|help) sed -n '2,/^$/{ /^#/s/^# \{0,1\}//p; }' "$SELF"; exit 0 ;; esac
case ${1:-} in
  web-token) say 'Open Binup using your local server address or Cockpit. No token is required.'; exit 0 ;;
  web-uninstall) web_setup "$1" "$CONF"; exit $? ;;
  install|web-install)
    if [[ -n ${2:-} ]]; then CONF=$(realpath -m -- "$2") || exit 1
    elif [[ -z ${BINUP_CONF:-} ]]; then
      saved_config=$(installed_web_config) || exit 1
      if [[ -n $saved_config ]]; then CONF=$(realpath -m -- "$saved_config") || exit 1; fi
    fi
    [[ -d ${CONF%/*} && -w ${CONF%/*} && ( ! -e $CONF || -f $CONF ) ]] ||
      { warn "Choose a config file in a directory you can write: $CONF"; exit 1; } ;;
esac
for dep in curl jq flock python3 sha256sum; do
  command -v "$dep" >/dev/null || { warn "Missing dependency: $dep"; exit 1; }
done
# jq normally accepts an empty input. Reject truncated/invalid configs up front.
config -es 'length == 1 and (.[0] | type == "object" and all(.[]; type == "object"))' >/dev/null ||
  { warn "Invalid config: $CONF"; exit 1; }
case ${1:-} in
  '')        menu ;;
  add)       mutate add_app "${2:-}" ;;
  edit)      [[ -n ${2:-} ]] && mutate add_app "$2" || exit 1 ;;
  check)     run_apps check "${2:-all}" ;;
  update)    mutate run_apps update "${2:-all}" ;;
  list|ls)   list_apps "${2:-}" ;;
  status|logs) [[ -n ${2:-} ]] || { warn "Use $1 NAME"; exit 1; }; service_command "$2" "$1" "${3:-}" ;;
  service) [[ $# == 3 && $3 =~ ^(start|stop|restart)$ ]] || { warn 'Use service NAME start|stop|restart'; exit 1; }
           mutate service_command "$2" "$3" ;;
  install) install_latest ;;
  web-install) web_setup "$1" "$CONF" ;;
  remove|rm) [[ -n ${2:-} ]] && mutate remove_app "$2" || exit 1 ;;
  *)         fail "Unknown command '$1'. Try --help." ;;
esac
