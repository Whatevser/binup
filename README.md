# binup

Update standalone Linux programs from GitHub releases, including single binaries and archives. Run `bash binup.sh` for the interactive menu. Binup uses `binup.json` beside the script, or the path in `BINUP_CONF`. The included JSON contains example entries with machine-specific paths.

## Install the web UI

On Ubuntu or Linux Mint, install the runtime dependencies if needed.

```bash
sudo apt install git curl jq util-linux python3
```

If you already have a binup **Git checkout** with your working JSON, run these commands inside it as your normal user.

```bash
git pull --ff-only
bash binup.sh web-install
bash binup.sh web-token
```

If your current folder contains **loose copies of the script and your working JSON**, run these commands from that folder. The new checkout will use your existing registry.

```bash
git clone https://github.com/Whatevser/binup.git "$HOME/.local/share/binup"
bash "$HOME/.local/share/binup/binup.sh" web-install "$PWD/binup.json"
bash "$HOME/.local/share/binup/binup.sh" web-token
```

Open `http://<server-IP>:9098` and enter the printed token. You can also install it, show the token, check its status or uninstall it from **9 · Web UI** in the terminal menu. The user service listens on `0.0.0.0:9098`. Anyone with the token can install and run software as the service account. Use HTTP on a trusted LAN or VPN, or put it behind an HTTPS reverse proxy.

The installer enables `binup-web.service` and runs it directly from the checkout. Keep the checkout at that path. To update the UI, pull there and run `systemctl --user restart binup-web.service`. To start it at boot and keep it after logout, run `loginctl enable-linger "$USER"`. To inspect the UI service itself, run `journalctl --user-unit=binup-web.service -n 100 --no-pager`. To remove it, run `bash binup.sh web-uninstall`. Your registry, app units and access token stay on disk.

## Manage apps and services

- **1 · Add app** offers existing service discovery, new service creation, or an app without a service. For a new service, choose user or system scope, its binary, startup arguments and working directory. Run a foreground program. Quote arguments containing spaces. Binup enables the unit with `Restart=always` and a five-second restart delay. New system units run the app as the account that created them.
- If the binary is already installed, binup starts the new service on registration. If the binary is missing, use **Update one** to install the selected build and start it. An existing service that you deliberately stopped stays stopped during ordinary updates.
- **5 · List** shows each service's scope, state and failure result. Select an app for status, the last 100 journal entries, live logs, or start/restart/stop. Press Ctrl+C to leave live logs. **Edit** can change an existing app's service or release selection.
- When a release renames its files, **Update** displays the available builds. Select the correct file to download it and save the new matching rule after verification succeeds. **Check** is read-only.
- From the web UI, use **Logs** on an app row for its journal, systemd status and service controls. **Live output** shows command output, errors and interactive build choices. Refreshing the page reconnects to the current run. **Run history** keeps the last 12 runs in memory until the UI service restarts.

The CLI and web UI can share the same registry and writer lock. Set `BINUP_CONF` to the path printed by `web-install` when using the CLI from a different checkout. The web service runs as your user. Operations on protected paths or system units use `sudo -n`; when sudo needs a password, use the terminal menu. System journal visibility follows the account's journal permissions.

### CLI shortcuts

```bash
bash binup.sh list
bash binup.sh status qbit
bash binup.sh logs qbit --follow
bash binup.sh service qbit restart
bash binup.sh check
bash binup.sh update qbit
```

Updates verify the GitHub release asset's SHA-256 digest before replacing the binary. An update backs up the old file next to it as `.bak` and checks service startup if the app was running. A configured `health_url` also has to return a successful HTTP response. If replacement or startup fails, live output shows the recovery attempt and commands for inspecting the service.
