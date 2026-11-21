#!/usr/bin/env bash
# Update standalone Linux programs from GitHub releases.
#
#   bash binup.sh                  open the interactive menu
#   bash binup.sh add [name]       register an app and choose its release file
#   bash binup.sh edit NAME        edit settings or choose a different build
#   bash binup.sh check [NAME]     check one or all apps, without installing
#   bash binup.sh update NAME      update one app (-f or --force to reinstall)
#   bash binup.sh update all       update all apps, continuing after failures
#   bash binup.sh list | remove NAME
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
# shellcheck disable=SC2016
set -uo pipefail

SELF=$(readlink -f -- "${BASH_SOURCE[0]}") || exit 1
CONF=$(realpath -m -- "${BINUP_CONF:-${SELF%/*}/binup.json}") || exit 1
API=https://api.github.com

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

as_root() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi; }

sctl() {
  local scope=$1
  shift
  if [[ $scope == user ]]; then
    if (( EUID == 0 )) && [[ -n ${SUDO_USER:-} ]]; then
      sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$SUDO_USER")" systemctl --user "$@"
    else
      systemctl --user "$@"
    fi
  else
    case $1 in start|stop|restart) as_root systemctl "$@" ;; *) systemctl "$@" ;; esac
  fi
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

ask() {
  local label=$1 initial=${2:-}
  if [[ -t 0 ]]; then
    IFS= read -er -i "$initial" -p "$label: " REPLY
  else
    printf '%s: ' "$label" >&2
    IFS= read -r REPLY || return 1
    REPLY=${REPLY:-$initial}
  fi
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
svc_bin() { sctl "$1" show -p ExecStart --value -- "$2" 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1; }
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
  local mode=$1 release=$2 rule=$3 tag assets matches count total default='' choice name proposed
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
  printf '%s\n%s\n' "$assets" "$matches" | jq -sr '
    (.[1] | INDEX(.name)) as $matched | .[0] | to_entries[] |
    "  \(.key+1)) \(.value.name)\(if $matched[.value.name] then "  [match]" else "" end)"' >&2 || return 1
  if [[ $mode == check || ( $mode == update && ! -t 0 ) ]]; then
    fail "Run update in a terminal to choose a file, or use edit to change the rule."
    return 1
  fi
  while :; do
    printf 'Build number%s (r = custom regex, q = cancel): ' "${default:+ [$default]}" >&2
    IFS= read -r choice || return 1
    choice=${choice:-$default}
    case $choice in
      q|Q) fail 'Selection cancelled.'; return 1 ;;
      r|R)
        ask 'Asset regex ({tag} is the release tag, {version} drops its leading v)' "$rule" || return 1
        proposed=$REPLY
        matches=$(matching_assets "$assets" "$proposed" "$tag") || continue
        count=$(jq length <<< "$matches")
        if (( count != 1 )); then warn "That rule matches $count files. Choose one file or refine the rule."; continue; fi
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

add_app() {
  local app=${1:-} old bin svc scope ver repo rule channel tag_re member health release defaults picked=''
  local services=()
  if [[ -z $app ]]; then ask 'App name' || return 1; app=$REPLY; fi
  [[ -n $app && $app != all && $app != *[[:cntrl:]]* ]] || { fail "Choose an app name other than 'all', without control characters."; return 1; }
  old=$(entry_for "$app") || return 1
  svc=$(field "$old" service); scope=$(field "$old" scope); scope=${scope:-system}
  bin=$(field "$old" bin); ver=$(field "$old" version); repo=$(field "$old" repo)
  rule=$(field "$old" asset_regex); channel=$(field "$old" release_channel); channel=${channel:-stable}
  tag_re=$(field "$old" tag_regex); member=$(field "$old" archive_member); health=$(field "$old" health_url)

  if [[ $old == '{}' ]]; then
    mapfile -t services < <(find_services "$app")
    case ${#services[@]} in
      0) picked='' ;;
      1) picked=${services[0]} ;;
      *) PS3='Pick service: '
         select picked in "${services[@]}" '(none)'; do [[ -n $picked ]] && break; done
         [[ $picked != '(none)' ]] || picked='' ;;
    esac
    if [[ -n $picked ]]; then
      scope=${picked%% *}; svc=${picked#* }; svc=${svc%.service}; bin=$(svc_bin "$scope" "$svc")
    fi
    [[ -n $bin ]] || bin=$(type -P -- "$app")
  fi
  ask 'Service (blank = none)' "$svc" || return 1; svc=${REPLY%.service}
  if [[ -n $svc ]]; then
    ask 'Service scope (system/user)' "$scope" || return 1; scope=$REPLY
    [[ $scope == system || $scope == user ]] || { fail 'Scope must be system or user.'; return 1; }
  fi
  ask 'Binary path' "$bin" || return 1; bin=${REPLY/#\~/$HOME}
  [[ -n $bin ]] || { fail 'A binary path is required.'; return 1; }
  if [[ -z $ver && -x $bin ]]; then ver=$(detect_version "$bin"); fi
  ask 'Installed version (blank = unknown)' "$ver" || return 1; ver=$REPLY
  ask 'GitHub repo (owner/repo or URL)' "$repo" || return 1
  repo=$(sed -E 's#^(https?://)?(www\.)?github\.com/##; s#/*$##; s#\.git$##' <<< "$REPLY" | cut -d/ -f1,2)
  [[ $repo =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || { fail 'Invalid GitHub repository.'; return 1; }

  say "Channel $channel, tag filter ${tag_re:-any}, archive member ${member:-auto}, health URL ${health:-none}"
  ask 'Change these settings? [y/N]' || return 1
  if [[ $REPLY == [yY] || $REPLY == [yY][eE][sS] ]]; then
    ask 'Release channel (stable/prerelease/any)' "$channel" || return 1; channel=$REPLY
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
  save_config --arg n "$app" --argjson settings "$defaults" '
    .[$n] |= ((. // {}) as $old | $old + $settings
      | if any(["repo","bin","asset_regex","archive_member"][]; ($old[.] // "") != $settings[.])
        then del(.asset_sha256, .binary_sha256, .archive_selector) else . end
      | if .release_channel == "stable" then del(.release_channel) else . end
      | with_entries(select((.key == "tag_regex" or .key == "archive_member" or .key == "health_url")
                            and .value == "" | not)))' || return 1
  ok "Saved '$app'."
}

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
      | if $selector == "" then del(.archive_selector) else .archive_selector = $selector end)'
}

start_checked() {
  local deadline
  sctl "$scope" "${1:-start}" -- "$svc" || return 1
  if [[ -z $health ]]; then
    sleep 2
    sctl "$scope" is-active --quiet -- "$svc"
    return
  fi
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
  local priv=()
  dir=$(dirname -- "$bin")
  if [[ ! -d $dir ]]; then mkdir -p -- "$dir" 2>/dev/null || as_root mkdir -p -- "$dir" || return 1; fi
  if (( EUID != 0 )) && [[ ! -w $dir || ( -e $bin && ! -O $bin ) ]]; then priv=(sudo); fi
  stage=$("${priv[@]}" mktemp -d -- "$dir/.binup.XXXXXXXX") || return 1

  # shellcheck disable=SC2329  # Called by the subshell's EXIT trap.
  cleanup_install() {
    local rc=$? restored=1 recovery=start
    trap - EXIT
    trap '' HUP INT TERM
    interrupted=0
    if (( rc != 0 && ! committed )); then
      if (( swapped )); then
        warn "Restoring the previous installation of $app."
        if (( was_active )) && ! sctl "$scope" stop -- "$svc"; then
          warn "Could not stop $svc. Will restart it after restoring the binary."
          recovery=restart
        fi
        if (( had_old )); then
          "${priv[@]}" mv -fT -- "$bin.bak" "$bin" || restored=0
        else
          "${priv[@]}" rm -f -- "$bin" || restored=0
        fi
      fi
      if (( ! restored )); then warn "ROLLBACK FAILED for $bin. Check $bin.bak before starting $svc."
      elif (( stopped )); then start_checked "$recovery" || warn "ROLLBACK FAILED to bring $svc back up."
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
    if ! grep -Eq '^LoadState=(loaded|masked)$' <<< "$state"; then fail "Could not load $scope service $svc."; return 1; fi
    case $'\n'$state$'\n' in
      *$'\nActiveState=active\n'*|*$'\nActiveState=reloading\n'*) was_active=1 ;;
      *$'\nActiveState=inactive\n'*|*$'\nActiveState=failed\n'*) ;;
      *) fail "$svc is changing state. Retry after it settles."; return 1 ;;
    esac
    if (( was_active && ! had_old )); then
      fail "$svc is running and $bin is missing. Check its binary path before stopping it."
      return 1
    fi
  fi
  if (( had_old )); then "${priv[@]}" mv -fT -- "$stage/old" "$bin.bak" || return 1; fi
  (( ! interrupted )) || return 130
  if (( was_active )); then
    stopped=1
    sctl "$scope" stop -- "$svc" || return 1
  fi
  (( ! interrupted )) || return 130
  "${priv[@]}" mv -fT -- "$stage/new" "$bin" || { fail "Could not replace $bin."; return 1; }
  swapped=1
  if command -v restorecon >/dev/null; then "${priv[@]}" restorecon "$bin" || return 1; fi
  if (( was_active )); then start_checked || { fail "$svc failed after installing $tag."; return 1; }; fi
  (( ! interrupted )) || return 130
  record_build || { fail "Could not commit $CONF."; return 1; }
  committed=1
  if (( had_old )); then ok "$app updated to $tag (backup $bin.bak)."; else ok "$app installed at $bin ($tag)."; fi
)

process_app() (
  local mode=$1 app=$2 entry bin basename svc scope repo rule channel tag_re member health
  local release tag asset_hash binary_hash local_hash='' expected='' name kind url tmp payload reason
  local previous saved_asset saved_binary saved_selector archive_selector=''
  entry=$(entry_for "$app") || return 1
  [[ $entry != '{}' ]] || { fail "'$app' is not registered."; return 1; }
  bin=$(field "$entry" bin); repo=$(field "$entry" repo)
  [[ -n $bin && -n $repo ]] || { fail "$app needs a binary path and repository."; return 1; }
  basename=$(basename -- "$bin")
  bin=$(realpath -m -- "$bin") || return 1
  if [[ -e $bin && ! -f $bin ]]; then fail "$bin is not a regular file."; return 1; fi
  svc=$(field "$entry" service); scope=$(field "$entry" scope); scope=${scope:-system}
  if [[ -n $svc && $scope != system && $scope != user ]]; then fail "Invalid scope '$scope' for $svc."; return 1; fi
  channel=$(field "$entry" release_channel); channel=${channel:-stable}
  rule=$(field "$entry" asset_regex); tag_re=$(field "$entry" tag_regex)
  member=$(field "$entry" archive_member); health=$(field "$entry" health_url)
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
    if [[ $mode == update && ( $previous != "$tag" || $saved_asset != "$asset_hash" || $saved_binary != "$binary_hash" || $rule != "$SELECTED_RULE" ) ]]; then
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
  else reason='installed file needs verification or replacement'
  fi
  say "  $tag / $name ($reason)"
  [[ $mode != check ]] || return 10

  tmp=$(mktemp -d) || return 1
  trap 'rm -rf -- "$tmp"' EXIT
  curl --proto '=https' --proto-redir '=https' -fLsS --retry 2 --connect-timeout 10 --speed-time 60 --speed-limit 1 -o "$tmp/download" -- "$url" ||
    { fail "$app: download failed for $name."; return 1; }
  local downloaded_hash
  downloaded_hash=$(hash_file "$tmp/download") || return 1
  [[ $downloaded_hash == "$asset_hash" ]] || { fail "$name: SHA-256 mismatch."; return 1; }
  payload=$tmp/binary
  if [[ $kind == raw ]]; then payload=$tmp/download; fi
  unpack "$tmp/download" "$payload" "$kind" "$name" "$basename" "$member" || return 1
  binary_hash=$asset_hash
  if [[ $kind != raw ]]; then binary_hash=$(hash_file "$payload") || return 1; fi
  if (( ! FORCE )) && [[ $binary_hash == "$local_hash" && -x $bin ]]; then
    record_build || return 1
    ok "$app already has the verified binary for $tag. Build details saved."
  else
    install_build "$payload"
  fi
)

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
      10) (( result != 0 )) || result=10 ;;
      *) result=1; failures+=("$app") ;;
    esac
  done
  if (( ${#failures[@]} )); then warn "Failed: ${failures[*]}"; fi
  return "$result"
}

list_apps() {
  { printf 'NAME\tVERSION\tSERVICE\tBINARY\tREPO\n'
    config -r 'to_entries[] | [.key, .value.version,
      (if (.value.service // "") == "" then "" else "\(.value.service) (\(.value.scope // "system"))" end),
      .value.bin, .value.repo] | map(if . == "" or . == null then "-" else . end) | @tsv'
  } | if command -v column >/dev/null; then column -t -s $'\t'; else cat; fi
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
    select action in 'Add app' 'Update one' 'Update all' 'Check for updates' 'List' 'Edit' 'Remove' 'Quit'; do break; done || return 0
    case $action in
      'Add app') mutate add_app ;;
      'Update one') pick_app && mutate run_apps update "$PICKED" ;;
      'Update all') mutate run_apps update all ;;
      'Check for updates') run_apps check all ;;
      'List') list_apps ;;
      'Edit') pick_app && mutate add_app "$PICKED" ;;
      'Remove') pick_app && mutate remove_app "$PICKED" ;;
      'Quit') return 0 ;;
      *) [[ $REPLY != q ]] || return 0 ;;
    esac
  done
}

FORCE=0
args=()
for arg in "$@"; do
  case $arg in -f|--force) FORCE=1 ;; *) args+=("$arg") ;; esac
done
set -- "${args[@]}"
case ${1:-} in -h|--help|help) sed -n '2,/^$/{ /^#/s/^# \{0,1\}//p; }' "$SELF"; exit 0 ;; esac
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
  list|ls)   list_apps ;;
  remove|rm) [[ -n ${2:-} ]] && mutate remove_app "$2" || exit 1 ;;
  *)         fail "Unknown command '$1'. Try --help." ;;
esac
