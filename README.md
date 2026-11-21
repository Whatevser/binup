# binup

Update standalone Linux programs from GitHub releases, including single binaries and archives. Run `bash binup.sh` for the interactive menu. Binup uses `binup.json` beside the script, or the path in `BINUP_CONF`. The included JSON contains example entries with machine-specific paths.

## Upgrade from the basic script

Run this **as your normal user from the folder containing your current `binup.sh` and `binup.json`**.

```bash
curl -fsSLo binup-upgrade.sh https://raw.githubusercontent.com/Whatevser/binup/main/binup.sh && bash binup-upgrade.sh install "$PWD/binup.json"
```

The installer downloads the matching CLI, server and UI together. It enables `binup-web.service`, adds Binup to Cockpit when installed, and points the old `binup.sh` at the installed version. Your apps, matching rules and installed versions stay in the same JSON. For subsequent upgrades run `bash binup.sh install` from that folder. Loose-script installations use curl and tar and keep their runtime under `~/.local/share/binup-runtime`, or `$XDG_DATA_HOME/binup-runtime` if configured.

If you already use a Git checkout, update it and install directly from there. A reinstall reuses the registry from the existing Binup user service. Pass a JSON path to choose a different registry.

```bash
git pull --ff-only && bash binup.sh web-install
```

On Ubuntu and Mint, the required packages are `bash curl jq util-linux python3 tar coreutils`. The installers use your systemd user manager.

## Open Binup

- **Cockpit** — Sign in to the managed host as the user who installed Binup. Refresh Cockpit and choose **System → Binup** in the left sidebar. The applications, service journals, live output and interactive prompts work within the page. Cockpit carries requests to port 9098 on the selected host. The browser only needs access to Cockpit. The package lives in your user Cockpit data directory. If you install Cockpit later, rerun `bash binup.sh web-install`.
- **Standalone** — Open `http://<LAN-or-VPN-IP>:9098/`. The page opens immediately on an allowed connection. Binup accepts loopback, private LAN IPs, Tailscale’s `100.64.0.0/10`, link-local addresses and IPv6 unique-local addresses. This covers WireGuard and ZeroTier networks using those ranges. IPv6 is enabled when the host supports a dual-stack listener.
- **Terminal** — Run `bash binup.sh` for the app menu. **9 · Web UI** installs the service and Cockpit page, shows the service status, or uninstalls both. Your registry and managed app units are kept.

Anyone who can reach the standalone service from an allowed network can operate it as the installing user. It checks the actual TCP peer. Keep a public reverse proxy or port-forward that rewrites clients to a trusted source away from this port. Use Cockpit or your VPN for remote access.

IP literals and the machine's own hostnames work by default. For a custom tunnel prefix or an extra DNS name such as a full MagicDNS name, run `systemctl --user edit binup-web.service`, set only the values you need, then run `systemctl --user restart binup-web.service`. Each setting takes a space-separated list.

```ini
[Service]
Environment="BINUP_EXTRA_NETWORKS=2001:db8:1234::/64"
Environment="BINUP_HOSTNAMES=server.example-tailnet.ts.net"
```

Replace the example prefix with your actual private tunnel's routed prefix. To start the service at boot and keep it after logout, use `loginctl enable-linger "$USER"`. Read its own logs with `journalctl --user-unit=binup-web.service -n 100 --no-pager`. Remove the service and sidebar entry with `bash binup.sh web-uninstall`.

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
