"""Exercise the public CLI and web API with an isolated registry and service manager."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tarfile
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from urllib.error import HTTPError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = b"#!/bin/sh\n# verified build\nexit 0\n"
UNIT = "binup-test.service"


def mock_command(tool, args):
    root = Path(os.environ["BINUP_TEST"])
    with (root / "calls").open("a") as stream:
        stream.write(json.dumps([tool, *args]) + "\n")
    if tool == "curl":
        if args[-1].endswith("/repos/Whatevser/binup/git/ref/heads/main"):
            print(json.dumps({"object": {"type": "commit", "sha": (root / "main-revision").read_text()}}))
        elif args[-1].startswith("https://codeload.github.com/"):
            assert args[-1].rsplit("/", 1)[1] == (root / "main-revision").read_text()
            shutil.copyfile(root / "bundle.tar.gz", args[args.index("-o") + 1])
        elif "-o" in args:
            Path(args[args.index("-o") + 1]).write_bytes(PAYLOAD)
        else:
            print((root / "release.json").read_text())
        return 0
    if tool == "systemd-run":
        if (root / "fail-systemd-run").exists():
            print("Could not start transient user unit", file=sys.stderr)
            return 1
        return 0  # API launch is tested separately from the worker process.
    if tool == "journalctl":
        since = next((float(a.split("@", 1)[1]) for a in args if a.startswith("--since=@")), None)
        journal = root / "journal"
        if since is None or journal.stat().st_mtime >= since:
            print(journal.read_text(), flush=True)
        if "--follow" in args:
            signal.pause()
        return 0
    if tool == "sudo":
        if (root / "password-required").exists():
            if "-A" not in args:
                print("sudo: a password is required", file=sys.stderr)
                return 1
            stamp = root / ("sudo-session-" + str(os.getsid(0)))
            if not stamp.exists():
                for _ in range(3):
                    helper = subprocess.run([os.environ["SUDO_ASKPASS"], "Password for binup-test"],
                                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=12)
                    if helper.returncode or not helper.stdout:
                        return 1
                    if helper.stdout == b"fixture-only password\n":
                        stamp.touch()
                        break
                    print("Sorry, try again.", file=sys.stderr, flush=True)
                else:
                    return 1
        if (root / "deny-sudo").exists():
            print("sudo: a password is required", file=sys.stderr)
            return 1
        command = args[args.index("--") + 1:] if "--" in args else args
        command = [arg.replace("/etc/systemd/system", str(root / "system")) for arg in command]
        if command[0] == "--":
            command.pop(0)
        os.execvp(command[0], command)
    scope = "user" if "--user" in args else "system"
    args = [arg for arg in args if arg != "--user"]
    op, unit = args[0], args[-1]
    folder = root / ("config/systemd/user" if scope == "user" else "system")
    state_file = root / (scope + "-" + unit + ".state")
    exists = (folder / unit).is_file()
    state = state_file.read_text() if state_file.exists() else "inactive"
    if (root / "offline").exists():
        print("Failed to connect to bus", file=sys.stderr)
        return 1
    if op.startswith("list-"):
        print("\n".join(f.name + " enabled" for f in sorted(folder.glob("*.service"))))
    elif op == "show":
        if "ExecStart" in args:
            return 0
        values = dict(LoadState="loaded" if exists else "not-found", ActiveState=state,
                      SubState={"active": "running", "failed": "failed"}.get(state, "dead"),
                      Result="exit-code" if state == "failed" else "success")
        props = next(arg.split("=", 1)[1].split(",") for arg in args if arg.startswith("--property="))
        print("\n".join(values[key] if "--value" in args else key + "=" + values[key] for key in props))
        return 0 if exists else 4
    elif op in ("enable", "disable", "daemon-reload"):
        return int(op == "enable" and (root / "fail-enable").exists())
    elif op in ("start", "restart", "stop"):
        if op == "stop" and (root / "slow-stop").exists():
            (root / "stopping").touch()
            time.sleep(1.2)
        if op == "stop" and (root / "fail-stop").exists():
            return 1
        if op != "stop" and ((root / "fail-start").exists() or (root / "fail-start-once").exists()):
            (root / "fail-start-once").unlink(missing_ok=True)
            state_file.write_text("failed")
            print("service exited with status 1", file=sys.stderr)
            return 1
        state_file.write_text("inactive" if op == "stop" else "active")
    elif op == "is-active":
        return 0 if state == "active" else 3
    elif op == "status":
        print(f"{unit} - test service\nActive: {state}")
        return 0 if state == "active" else 3
    else:
        raise AssertionError(args)
    return 0


class ServiceTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        tools = self.root / "tools"
        tools.mkdir()
        for tool in ("curl", "systemctl", "journalctl", "sudo", "systemd-run"):
            file = tools / tool
            file.write_text("#!/bin/sh\nexec " + shlex.join([sys.executable, str(Path(__file__).resolve()), "--mock", tool]) + ' "$@"\n')
            file.chmod(0o755)
        self.config = self.root / "apps.json"
        self.config.write_text("{}\n")
        self.binary = self.root / "a worker $file %test"
        self.env = dict(os.environ, BINUP_CONF=str(self.config), BINUP_TEST=tmp.name,
                        XDG_CONFIG_HOME=str(self.root / "config"), XDG_DATA_HOME=str(self.root / "data"), PATH=str(tools) + ":" + os.environ["PATH"])
        (self.root / "journal").write_text("unit failed: bind error\n")
        self.release("linux_x86_64")

    def release(self, name, digest=None):
        asset = dict(name=name, state="uploaded", browser_download_url="https://example.invalid/build",
                     digest="sha256:" + (digest or hashlib.sha256(PAYLOAD).hexdigest()))
        (self.root / "release.json").write_text(json.dumps(dict(tag_name="v1", draft=False, prerelease=False, assets=[asset])))

    def cli(self, *argv, answers=(), code=0, env=None):
        proc = subprocess.run(["bash", str(ROOT / "binup.sh"), *argv], input="\n".join(answers) + "\n",
                              env=self.env if env is None else env, capture_output=True, text=True, timeout=35)
        self.assertEqual(proc.returncode, code, proc.stdout + proc.stderr)
        return proc.stdout + proc.stderr

    def create(self, scope="user", code=0):
        return self.cli("add", "demo", answers=["2", UNIT, scope, str(self.binary),
                        '''--label "two words" '$HOME' '100%' 'say"hi' ''', "~", "", "org/app", "", "1"], code=code)

    def unit(self, scope="user"):
        return self.root / ("config/systemd/user" if scope == "user" else "system") / UNIT

    def record(self):
        return json.loads(self.config.read_text())["demo"]

    def test_create_install_inspect_and_follow(self):
        self.create()
        self.assertTrue(self.record()["start_after_install"])
        self.assertIn("awaiting install", self.cli("list"))
        self.cli("update", "demo")
        self.assertEqual(self.binary.read_bytes(), PAYLOAD)
        self.assertNotIn("start_after_install", self.record())
        unit = self.unit().read_text()
        for setting in ("Type=exec", "Restart=always", "RestartSec=5s", "WantedBy=default.target",
                        '":' + str(self.binary).replace("%", "%%") + '"', '"two words" "$HOME" "100%%"'):
            self.assertIn(setting, unit)
        if shutil.which("systemd-analyze"):
            subprocess.run(["systemd-analyze", "verify", str(self.unit())], check=True, capture_output=True)
        self.assertIn("active/running", self.cli("list"))
        (self.root / ("user-" + UNIT + ".state")).write_text("failed")
        self.assertIn("failed/exit-code", self.cli("list"))
        self.assertIn("Active: failed", self.cli("status", "demo", code=3))
        self.assertIn("bind error", self.cli("logs", "demo"))
        self.assertIn("bind error", self.cli(answers=["5", "1", "2", "7", "8"]))
        self.assertIn("--user-unit=" + UNIT, (self.root / "calls").read_text())
        self.cli("service", "demo", "restart")
        self.assertIn("active/running", self.cli("list"))

    @unittest.skipIf(os.geteuid() == 0, "test redirects privileged writes via sudo as a normal user")
    def test_system_unit_and_permissions(self):
        self.binary.write_bytes(PAYLOAD)
        self.binary.chmod(0o755)
        self.create("system")
        unit = self.unit("system").read_text()
        self.assertIn("User=" + str(os.getuid()), unit)
        self.assertIn("WantedBy=multi-user.target", unit)
        if shutil.which("systemd-analyze"):
            subprocess.run(["systemd-analyze", "verify", str(self.unit("system"))], check=True, capture_output=True)
        self.assertIn("active/running", self.cli("list"))
        self.cli("logs", "demo")
        self.assertIn("--unit=" + UNIT, (self.root / "calls").read_text())
        (self.root / "deny-sudo").touch()
        self.assertIn("start a new run from the web UI", self.cli("service", "demo", "stop", code=1, env=dict(self.env, BINUP_WEB="1")))

    def test_failed_setup_and_existing_unit(self):
        (self.root / "fail-enable").touch()
        self.create(code=1)
        self.assertFalse(self.unit().exists())
        self.assertEqual(json.loads(self.config.read_text()), {})
        (self.root / "fail-enable").unlink()
        self.unit().write_text("# hand-managed\n")
        self.assertIn("already exists", self.create(code=1))
        self.assertEqual(self.unit().read_text(), "# hand-managed\n")
        self.cli("add", "binup-test", answers=["1", "", "", str(self.binary), "", "org/app", "", "1"])
        self.assertEqual(json.loads(self.config.read_text())["binup-test"]["service"], "binup-test")
        self.assertEqual(self.unit().read_text(), "# hand-managed\n")
        (self.root / "offline").touch()
        self.assertEqual(json.loads(self.cli("list", "--json"))[0]["state"], "unavailable")

    def test_failed_or_interrupted_shutdown(self):
        original = b"#!/bin/sh\n# previous build\nexit 0\n"
        self.binary.write_bytes(original)
        self.binary.chmod(0o755)
        self.create()
        before = self.config.read_bytes()
        calls = self.root / "calls"
        calls.write_text("")
        (self.root / "fail-stop").touch()
        out = self.cli("update", "demo", code=1)
        self.assertIn("still active with the previous binary", out)
        self.assertIn("logs demo", out)
        self.assertNotIn('"start"', calls.read_text())
        self.assertEqual(self.binary.read_bytes(), original)
        (self.root / "fail-stop").unlink()
        (self.root / "slow-stop").touch()
        process = subprocess.Popen(["bash", str(ROOT / "binup.sh"), "update", "demo"], env=self.env,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        try:
            deadline = time.monotonic() + 8
            while not (self.root / "stopping").exists():
                self.assertLess(time.monotonic(), deadline, "service did not enter the stop stage")
                time.sleep(0.025)
            os.killpg(process.pid, signal.SIGINT)
            output = process.communicate(timeout=12)[0]
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        self.assertNotEqual(process.returncode, 0, output)
        self.assertIn("back up", output)
        self.assertEqual(self.binary.read_bytes(), original)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertIn("active/running", self.cli("list"))

    @unittest.skipIf(os.geteuid() == 0, "web installer runs as an unprivileged account")
    def test_web_unit_install_and_remove(self):
        alternate = self.root / "live $config %.json"
        alternate.write_text("{}")
        self.config.write_text("{broken")
        self.cli("web-install", str(alternate))
        self.assertFalse((self.root / "config/binup/web.token").exists())
        unit = self.unit().with_name("binup-web.service")
        text = unit.read_text()
        persistent = self.root / "config/binup/binup.json"
        stable = self.root / "data/binup/current"
        self.assertEqual(json.loads(persistent.read_text()), {})
        self.assertFalse(alternate.exists())
        self.assertIn(str(persistent), text)
        self.assertIn(str(stable / "binup_web.py"), text)
        self.assertEqual(stable.resolve(), ROOT)
        self.assertIn("KillMode=mixed", text)
        self.assertNotIn("--token-file", text)
        if shutil.which("systemd-analyze"):
            subprocess.run(["systemd-analyze", "verify", str(unit)], check=True, capture_output=True)
        self.cli("web-install", str(alternate))
        alternate_env = dict(self.env, BINUP_CONF=str(alternate))
        self.assertIn("Web UI action", self.cli(answers=["9", "4", "8"], env=alternate_env))
        previous_env = self.env.copy()
        del previous_env["BINUP_CONF"]
        legacy_unit = [line + ' "--token-file" "/old/token"' if line.startswith("ExecStart=") else line
                       for line in text.splitlines()]
        unit.write_text("\n".join(legacy_unit) + "\n")
        self.cli("web-install", env=previous_env)
        self.assertIn(str(persistent), unit.read_text())
        self.assertNotIn("--token-file", unit.read_text())
        self.cli("web-uninstall")
        self.assertFalse(unit.exists())
        unit.write_text("[Service]\nExecStart=/bin/sleep infinity\n")
        self.assertIn("belongs to another service", self.cli("web-install", str(alternate), code=1))
        self.assertIn("/bin/sleep", unit.read_text())

    @unittest.skipIf(os.geteuid() == 0, "web setup runs as an unprivileged account")
    def test_cockpit_discovery_upgrade_and_uninstall(self):
        package = self.root / "data/cockpit/binup"
        bridge = self.root / "tools/cockpit-bridge"
        bridge.write_text("#!/bin/sh\nexit 0\n")
        bridge.chmod(0o755)
        self.cli("web-install")
        self.assertEqual(package.resolve(), ROOT / "web")
        manifest = json.loads((package / "manifest.json").read_text())
        self.assertEqual(manifest["menu"]["index"]["label"], "Binup")
        self.assertTrue((package / manifest["menu"]["index"]["path"]).is_file())
        self.cli("web-install")
        self.cli("web-uninstall")
        self.assertFalse(package.is_symlink())
        package.mkdir()
        (package / "keep").touch()
        self.assertIn("unrelated Cockpit package", self.cli("web-install", code=1))
        self.assertTrue((package / "keep").is_file())

    @unittest.skipIf(os.geteuid() == 0, "web setup runs as an unprivileged account")
    def test_one_file_upgrade_preserves_registry(self):
        loose = self.root / "my tools"
        loose.mkdir()
        launcher, live = loose / "binup.sh", loose / "binup.json"
        launcher.write_text("#!/bin/bash\n# previous version\n")
        live.write_text('{"saved":{"service":"","repo":"org/app","custom":true}}\n')
        live_web = live.with_name(live.name + ".web.json")
        live_web.write_text('{"interval_hours":6,"next_check":null,"checks":{}}')
        live_status = live.with_name(live.name + ".self-update.json")
        live_status.write_text('{"state":"success","message":"Previous upgrade"}')
        before = live.read_bytes()
        bootstrap = loose / "binup-upgrade.sh"
        shutil.copyfile(ROOT / "binup.sh", bootstrap)
        revision = "1" * 40
        (self.root / "main-revision").write_text(revision)
        with tarfile.open(self.root / "bundle.tar.gz", "w:gz") as archive:
            for file in ("binup.sh", "binup_web.py", "web", "binup.json"):
                archive.add(ROOT / file, f"binup-{revision}/{file}")
        env = self.env.copy()
        del env["BINUP_CONF"]
        persistent = self.root / "config/binup/binup.json"
        stable = self.root / "data/binup/current"
        for _ in range(2):
            subprocess.run(["bash", str(bootstrap), "install"], env=env, check=True, capture_output=True)
            self.assertTrue(persistent.exists())
            self.assertEqual(persistent.read_bytes(), before)
            self.assertEqual(stable.resolve().name, revision)
            self.assertFalse((loose / "binup.sh").is_symlink())  # No loose launcher required.
            proc = subprocess.run(["bash", str(stable / "binup.sh"), "list", "--json"],
                                  env=env, capture_output=True, check=True, text=True)
            self.assertEqual(json.loads(proc.stdout)[0]["name"], "saved")
        unit = self.unit().with_name("binup-web.service").read_text()
        self.assertIn(str(persistent), unit)
        self.assertIn(str(stable / "binup_web.py"), unit)
        self.assertNotIn("--token-file", unit)
        self.assertFalse(live.exists())
        self.assertFalse(live_web.exists())
        self.assertFalse(live_status.exists())
        self.assertEqual(json.loads(persistent.with_name("binup.json.web.json").read_text())["interval_hours"], 6)
        self.assertEqual(json.loads(persistent.with_name("binup.json.self-update.json").read_text())["message"], "Previous upgrade")
        installed = stable.resolve()
        self.assertEqual((self.root / "calls").read_text().count("https://codeload.github.com/"), 1)
        (self.root / "main-revision").write_text("2" * 40)
        (self.root / "bundle.tar.gz").write_bytes(b"incomplete download")
        rejected = subprocess.run(["bash", str(bootstrap), "install"], env=env, capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(stable.resolve(), installed)
        self.assertEqual(persistent.read_bytes(), before)

    @unittest.skipIf(os.geteuid() == 0, "web installer runs as an unprivileged account")
    def test_migrate_existing_scripts_config_from_old_service(self):
        old = self.root / "scripts/binup.json"
        old.parent.mkdir()
        old.write_text('{"qbit":{"bin":"/home/user/bin/qbittorrent-nox","repo":"owner/qbit","version":"v4"}}')
        old_web = old.with_name(old.name + ".web.json")
        old_web.write_text('{"interval_hours":24,"next_check":12345,"checks":{}}')
        legacy_unit = self.unit().with_name("binup-web.service")
        legacy_unit.parent.mkdir(parents=True, exist_ok=True)
        legacy_unit.write_text('# Generated by binup web-install\n[Service]\n' +
                               'ExecStart=/usr/bin/python3 /tmp/old/binup_web.py serve --config "' +
                               str(old) + '"\n')
        self.cli("web-install")
        persistent = self.root / "config/binup/binup.json"
        self.assertEqual(json.loads(persistent.read_text())["qbit"]["version"], "v4")
        self.assertEqual(json.loads(persistent.with_name("binup.json.web.json").read_text())["interval_hours"], 24)
        self.assertFalse(old.exists())
        self.assertFalse(old_web.exists())
        self.assertIn(str(persistent), legacy_unit.read_text())
        self.assertIn(str(self.root / "data/binup/current/binup_web.py"), legacy_unit.read_text())

    @unittest.skipIf(os.geteuid() == 0, "web installer runs as an unprivileged account")
    def test_conflicting_persistent_config_is_not_overwritten(self):
        old = self.root / "old.json"
        old.write_text('{"existing":{"version":"one"}}')
        persistent = self.root / "config/binup/binup.json"
        persistent.parent.mkdir(parents=True)
        persistent.write_text('{"existing":{"version":"two"}}')
        self.assertIn("Config conflict", self.cli("web-install", str(old), code=1))
        self.assertEqual(json.loads(persistent.read_text())["existing"]["version"], "two")
        self.assertTrue(old.exists())
        self.assertFalse(self.unit().with_name("binup-web.service").exists())

    def start_server(self, *options):
        script = [sys.executable, str(ROOT / "binup_web.py")]
        process = subprocess.Popen([*script, "serve", "--config", str(self.config), *options],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_server, process)
        self.web_process = process
        line = process.stdout.readline()
        self.assertIn("listening on", line)
        self.base = "http://127.0.0.1:" + line.strip().rsplit(":", 1)[1]

    @staticmethod
    def stop_server(process):
        if process.poll() is None:
            process.terminate()
            process.communicate(timeout=15)

    def api(self, path, body=None, **headers):
        data = None if body is None else json.dumps(body).encode()
        req = Request(self.base + "/api/" + path, data=data, headers={"Content-Type": "application/json", **headers})
        with urlopen(req, timeout=18) as result:
            return json.load(result)

    def test_self_update_api_and_restart_persistence(self):
        self.start_server("--port", "0")
        revision = "a" * 40
        (self.root / "main-revision").write_text(revision)
        status = self.api("self-update?check=1")
        self.assertEqual(status["latest"], revision)
        self.assertFalse(status.get("state"))
        start = self.api("self-update", {})
        self.assertEqual(start["state"], "queued")
        self.assertIn("systemd-run", (self.root / "calls").read_text())
        self.assertIn("self-update-worker", (self.root / "calls").read_text())
        self.assertIn(str(self.config), (self.root / "calls").read_text())
        for path, body in (("self-update", {}), ("runs", {"action": "add", "app": "blocked"})):
            with self.assertRaises(HTTPError) as error:
                self.api(path, body)
            self.assertEqual(error.exception.code, 409)
        status_file = self.config.with_name(self.config.name + ".self-update.json")
        self.stop_server(self.web_process)
        self.start_server("--port", "0")
        self.assertEqual(self.api("self-update")["state"], "queued")
        self.assertTrue(status_file.is_file())
        status_file.write_text(json.dumps({"state": "success", "finished": time.time(),
                                           "message": "Updated", "output": "All good"}))
        self.assertEqual(self.api("self-update")["output"], "All good")
        (self.root / "fail-systemd-run").touch()
        with self.assertRaises(HTTPError) as failure:
            self.api("self-update", {})
        self.assertEqual(failure.exception.code, 503)
        self.assertEqual(self.api("self-update")["state"], "error")

    def test_self_update_worker_success_and_failure(self):
        sys.path.insert(0, str(ROOT))
        try:
            import binup_web
        finally:
            sys.path.pop(0)
        old_script = binup_web.SCRIPT
        self.addCleanup(setattr, binup_web, "SCRIPT", old_script)
        fake_script = self.root / "fake-update.sh"
        binup_web.SCRIPT = str(fake_script)
        fake_script.write_text("""#!/bin/bash
printf "Upgraded %s\\n" "$2"
exit 0
""")
        self.assertEqual(binup_web.self_update_worker(self.config), 0)
        status = binup_web.read_update_status(binup_web.self_update_path(self.config))
        self.assertEqual(status["state"], "success")
        self.assertIn(str(self.config), status["output"])
        self.assertEqual(status["code"], 0)
        fake_script.write_text("""#!/bin/bash
echo "Upgrade rejected"
exit 22
""")
        self.assertEqual(binup_web.self_update_worker(self.config), 1)
        status = binup_web.read_update_status(binup_web.self_update_path(self.config))
        self.assertEqual(status["state"], "error")
        self.assertEqual(status["code"], 22)
        self.assertIn("Upgrade rejected", status["output"])

    def test_failed_web_upgrade_restores_previous_unit(self):
        self.cli("web-install")
        old_unit = self.unit().with_name("binup-web.service").read_bytes()
        stable = self.root / "data/binup/current"
        previous = self.root / "previous-version"
        previous.mkdir()
        stable.unlink()
        stable.symlink_to(previous)
        (self.root / "fail-start-once").touch()
        self.cli("web-install", code=1)
        self.assertEqual(self.unit().with_name("binup-web.service").read_bytes(), old_unit)
        self.assertEqual(stable.resolve(), previous)
        self.assertEqual((self.root / "user-binup-web.service.state").read_text(), "active")

    def test_import_legacy_self_update_result_after_migration(self):
        sys.path.insert(0, str(ROOT))
        try:
            from binup_web import Control, read_update_status, self_update_path
        finally:
            sys.path.pop(0)
        legacy = self.root / "scripts/binup.json.self-update.json"
        legacy.parent.mkdir()
        status_path = self_update_path(self.config)
        status_path.write_text(json.dumps({"state": "running", "started": 42,
                                           "legacy_path": str(legacy)}))
        legacy.write_text(json.dumps({"state": "success", "started": 42,
                                      "output": "Installed new runtime", "finished": 50}))
        summary = Control(self.config).self_update_status()
        self.assertEqual(summary["state"], "success")
        self.assertIn("Installed new runtime", summary["output"])
        self.assertFalse(legacy.exists())
        self.assertNotIn("legacy_path", read_update_status(status_path))

    def test_local_network_policy(self):
        sys.path.insert(0, str(ROOT))
        try:
            from binup_web import LocalAccess, LocalServer
        finally:
            sys.path.pop(0)
        access = LocalAccess(aliases=["lab.home.arpa"])
        server = SimpleNamespace(access=access)
        for address in ("127.0.0.1", "::1", "192.168.1.42", "10.3.4.5", "172.31.255.254",
                        "100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1", "fe80::1%eth0",
                        "::ffff:10.10.2.3", "169.254.1.22"):
            self.assertTrue(LocalServer.verify_request(server, None, (address, 49152)), address)
        for address in ("8.8.8.8", "100.128.0.1", "172.32.0.1", "192.0.2.1", "::",
                        "::ffff:8.8.8.8", "2001:4860:4860::8888", "ff02::1", "0.0.0.0"):
            self.assertFalse(LocalServer.verify_request(server, None, (address, 49152)), address)
        for host in ("lab.home.arpa:9098", "localhost", "[fd7a:115c:a1e0::1]:9098", "192.168.2.3:9098"):
            self.assertTrue(access.permits_host(host), host)
        for host in ("other.invalid", "other.invalid@127.0.0.1", "[::1]unexpected", "127.0.0.1%extra",
                     "localhost:bad", "localhost/path", "localhost:99999"):
            self.assertFalse(access.permits_host(host), host)
        self.assertTrue(LocalAccess(["2001:db8:12::/64"]).permits_ip("2001:db8:12::a"))
        with self.assertRaises(ValueError):
            LocalAccess(["0.0.0.0/0"])

    def finish_run(self, run):
        path = "runs/" + run["id"]
        detail = self.api(path)
        while detail["code"] is None:
            self.assertIsNone(detail["prompt"], detail)
            detail = self.api(path + "?after=" + str(detail["cursor"]))
        return self.api(path)

    def test_per_app_policy_and_backup_cleanup(self):
        original = b"#!/bin/sh\n# previous version\nexit 0\n"
        self.binary.write_bytes(original)
        self.binary.chmod(0o755)
        self.config.write_text(json.dumps({"demo": dict(repo="org/app", bin=str(self.binary),
                                                       version="v0", asset_regex="linux")}))
        # Legacy apps are checked, not installed, by an unattended pass.
        self.cli("auto", "demo", code=10)
        self.assertEqual(self.binary.read_bytes(), original)
        self.cli("policy", "demo", "auto_update", "on")
        self.cli("policy", "demo", "keep_backup", "on")
        self.cli("auto", "demo")
        self.assertEqual(self.binary.read_bytes(), PAYLOAD)
        backup = Path(str(self.binary) + ".bak")
        self.assertEqual(backup.read_bytes(), original)
        self.assertTrue(self.record()["auto_update"])
        self.assertTrue(self.record()["keep_backup"])
        self.assertTrue(json.loads(self.cli("list", "--json"))[0]["has_backup"])
        self.cli("cleanup", "demo")
        self.assertFalse(backup.exists())
        self.cli("cleanup", "all")  # Repeated cleanup is safe.
        self.cli("policy", "demo", "keep_backup", "off")
        self.binary.write_bytes(original)
        self.cli("update", "demo")
        self.assertEqual(self.binary.read_bytes(), PAYLOAD)
        self.assertFalse(backup.exists())
        self.assertFalse(self.record()["keep_backup"])
        self.cli("policy", "demo", "auto_update", "off")
        self.assertFalse(self.record()["auto_update"])
        self.cli("policy", "demo", "bogus", "on", code=1)
        self.cli("policy", "demo", "auto_update", "maybe", code=1)
        sentinel = self.root / "sentinel"
        sentinel.write_text("leave untouched")
        backup.symlink_to(sentinel)
        self.cli("cleanup", "demo", code=1)
        self.assertEqual(sentinel.read_text(), "leave untouched")

    def test_web_per_app_scheduled_install(self):
        old = b"#!/bin/sh\n# old build\nexit 0\n"
        automatic = self.root / "auto tool"
        manual = self.root / "manual tool"
        for binary in (automatic, manual):
            binary.write_bytes(old)
            binary.chmod(0o755)
        self.config.write_text(json.dumps({
            "automatic": dict(repo="org/app", bin=str(automatic), version="v0", asset_regex="linux"),
            "manual": dict(repo="org/app", bin=str(manual), version="v0", asset_regex="linux")
        }))
        self.start_server("--port", "0")
        with self.assertRaises(HTTPError):
            self.api("app-settings", {"app": "automatic", "key": "auto_update", "enabled": 1})
        self.assertTrue(self.api("app-settings", {"app": "automatic", "key": "auto_update",
                                                    "enabled": True})["enabled"])
        self.api("app-settings", {"app": "automatic", "key": "keep_backup", "enabled": False})
        apps = {app["name"]: app for app in self.api("state")["apps"]}
        self.assertTrue(apps["automatic"]["auto_update"])
        self.assertFalse(apps["automatic"]["keep_backup"])
        self.assertFalse(apps["manual"]["auto_update"])
        self.api("settings", {"interval_hours": 6})
        deadline = time.monotonic() + 12
        while True:
            runs = self.api("state")["runs"]
            if runs and runs[0]["scheduled"]:
                break
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.05)
        result = self.finish_run(runs[0])
        self.assertEqual(result["action"], "auto")
        self.assertEqual(result["code"], 10)
        self.assertEqual(automatic.read_bytes(), PAYLOAD)
        self.assertEqual(manual.read_bytes(), old)
        self.assertFalse(Path(str(automatic) + ".bak").exists())
        apps = {app["name"]: app for app in self.api("state")["apps"]}
        self.assertEqual(apps["automatic"]["check"]["status"], "current")
        self.assertEqual(apps["manual"]["check"]["status"], "available")
        self.assertFalse(apps["automatic"]["has_backup"])

    def test_scheduled_checks_and_version_results(self):
        self.binary.write_bytes(PAYLOAD)
        self.binary.chmod(0o755)
        entry = dict(repo="org/app", bin=str(self.binary), version="v1", asset_regex="linux")
        entries = {"current": entry, "old": dict(entry, version="v0", bin=str(self.root / "missing")),
                   "broken": dict(entry, asset_regex="no-match"),
                   "renamed": dict(entry, version="v0", asset_regex="old-filename")}
        self.config.write_text(json.dumps(entries))
        original = self.config.read_bytes()
        self.start_server("--port", "0")
        before = self.api("state")
        self.assertEqual(before["settings"]["interval_hours"], 0)
        self.assertTrue(all("check" not in app for app in before["apps"]))
        with self.assertRaises(HTTPError):
            self.api("settings", {"interval_hours": True})
        # The first automatic run waits behind an open wizard.
        pending = self.api("runs", {"action": "add", "app": "test"})
        self.api("settings", {"interval_hours": 6})
        self.assertEqual(len(self.api("state")["runs"]), 1)
        self.api("runs/" + pending["id"] + "/cancel", {})
        deadline = time.monotonic() + 12
        while True:
            runs = self.api("state")["runs"]
            if runs[0]["scheduled"]:
                break
            self.assertLess(time.monotonic(), deadline)
        check = self.finish_run(runs[0])
        self.assertEqual(check["code"], 1)
        state = self.api("state")
        self.assertEqual({a["name"]: a["check"]["status"] for a in state["apps"]},
                         {"current": "current", "old": "available", "broken": "error", "renamed": "available"})
        renamed = next(a for a in state["apps"] if a["name"] == "renamed")["check"]
        self.assertEqual((renamed["latest"], renamed["problem"]), ("v1", "Check failed"))
        self.assertTrue(time.time() + 5*3600 < state["settings"]["next_check"] <= time.time() + 6*3600)
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.root / "missing").exists())
        self.assertNotIn('"-o"', (self.root / "calls").read_text())
        # Restart with an overdue check and leave the service running without a browser.
        self.stop_server(self.web_process)
        sidecar = self.config.with_name(self.config.name + ".web.json")
        saved = json.loads(sidecar.read_text())
        saved["next_check"] = time.time() - 1
        sidecar.write_text(json.dumps(saved))
        self.start_server("--port", "0")
        time.sleep(0.8)
        state = self.api("state")
        self.assertEqual(len(state["runs"]), 1)
        self.assertTrue(state["runs"][0]["scheduled"])
        self.finish_run(state["runs"][0])
        self.assertEqual(self.api("settings", {"interval_hours": 0})["next_check"], None)
        entries["current"]["tag_regex"] = "changed"
        self.config.write_text(json.dumps(entries))
        self.assertNotIn("check", next(a for a in self.api("state")["apps"] if a["name"] == "current"))
        self.api("history/clear", {})
        self.assertFalse(self.api("state")["runs"])
        self.assertIn("check", next(a for a in self.api("state")["apps"] if a["name"] == "old"))

    def test_interactive_sudo(self):
        self.binary.write_bytes(PAYLOAD)
        self.binary.chmod(0o755)
        self.create("system")
        (self.root / "password-required").touch()
        # Exercise a private, non-loopback TCP peer even on loopback-only CI.
        from threading import Thread
        sys.path.insert(0, str(ROOT))
        try:
            from binup_web import Control, Handler, LocalAccess, LocalServer
        finally:
            sys.path.pop(0)

        class LanServer(LocalServer):
            def get_request(self):
                sock, address = super().get_request()
                return sock, ("192.168.10.42", address[1])

        server = LanServer(("127.0.0.1", 0), Handler)
        server.access = LocalAccess(aliases=["green-g4"])
        server.files = {}
        server.control = Control(self.config)
        server.control.env.update(self.env)
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.control.shutdown)
        self.addCleanup(worker.join)
        self.addCleanup(server.shutdown)
        self.base = "http://127.0.0.1:" + str(server.server_port)

        def begin():
            run = self.api("runs", {"action": "restart", "app": "demo", "interactive_sudo": True},
                           Host="green-g4:9098", Origin="http://green-g4:9098")
            return "runs/" + run["id"], {"X-Binup-Run": run["owner"]}

        def wait_for(path, headers, predicate):
            result = self.api(path, **headers)
            while not predicate(result):
                self.assertIsNone(result["code"], result["output"])
                result = self.api(path + "?after=" + str(result["cursor"]), **headers)
            return result

        path, headers = begin()
        data = wait_for(path, headers, lambda r: r["prompt"])
        prompt = data["prompt"]
        self.assertTrue(prompt["secret"])
        self.assertIsNone(self.api(path)["prompt"])
        self.assertNotIn(headers["X-Binup-Run"], json.dumps(self.api("state")))
        args = {"id": prompt["id"], "value": "wrong fixture password"}
        for endpoint, auth, status in [("password", {}, 403), ("input", headers, 409)]:
            with self.assertRaises(HTTPError) as error:
                self.api(path + "/" + endpoint, args, **auth)
            self.assertEqual(error.exception.code, status)
        self.api(path + "/password", args, **headers)
        second = wait_for(path, headers, lambda r: r["prompt"] and r["prompt"]["id"] != prompt["id"])
        self.assertTrue(second["prompt"]["retry"])
        self.api(path + "/password", {"id": second["prompt"]["id"], "value": "fixture-only password"}, **headers)
        result = wait_for(path, headers, lambda r: r["code"] is not None)
        self.assertEqual(result["code"], 0, self.api(path)["output"])
        public = json.dumps([self.api(path), self.api("state")]) + (self.root / "calls").read_text()
        self.assertNotIn("fixture-only password", public)
        self.assertNotIn("wrong fixture password", public)
        path, headers = begin()
        wait_for(path, headers, lambda r: r["prompt"])
        self.api(path + "/cancel", {}, **headers)
        cancelled = wait_for(path, headers, lambda r: r["code"] is not None)
        self.assertTrue(cancelled["cancelling"])
        self.assertIsNone(cancelled["prompt"])

    def test_web_runs_repair_cancel_and_access(self):
        # A unit from before the token-free upgrade may still pass the old option.
        self.start_server("--bind", "127.0.0.1", "--port", "0", "--token-file", str(self.root / "unused"))
        self.assertEqual(self.api("state")["apps"], [])
        for req in ({"Origin": "https://elsewhere.invalid"}, {"Host": "unrelated.example"},
                    {"Sec-Fetch-Site": "cross-site"}):
            with self.assertRaises(HTTPError) as error:
                self.api("state", **req)
            self.assertEqual(error.exception.code, 403)
        self.create()
        self.release("renamed.worker")
        run = self.api("runs", {"action": "update", "app": "demo"})
        path = "runs/" + run["id"]
        self.assertFalse(self.api(path)["truncated"])
        cursor = -1
        output = ""
        while True:
            update = self.api(path + "?after=" + str(cursor))
            cursor = update["cursor"]
            output += update["output"]
            if update["prompt"] or update["code"] is not None:
                break
        self.assertIn("0 matches", output)
        prompt = update["prompt"]
        self.assertEqual([(o["value"], o["label"]) for o in prompt["options"]][0], ("1", "renamed.worker"))
        with self.assertRaises(HTTPError):
            self.api(path + "/input", {"id": prompt["id"], "value": "99"})
        self.api(path + "/clear", {})
        self.api("history/clear", {})
        cleared = self.api(path)
        self.assertEqual(cleared["output"], "")
        self.assertGreater(cleared["cleared"], -1)
        self.assertEqual(cleared["prompt"]["id"], prompt["id"])
        with self.assertRaises(HTTPError) as busy:
            self.api("runs", {"action": "edit", "app": "demo"})
        self.assertEqual(busy.exception.code, 409)
        self.assertIn("bind error", self.api("logs?app=demo")["output"])
        cutoff = self.api("logs/clear-view", {})["since"]
        self.assertEqual(self.api("logs?app=demo&since=" + str(cutoff))["output"], "")
        (self.root / "journal").write_text("new service entry")
        self.assertIn("new service entry", self.api("logs?app=demo&since=" + str(cutoff))["output"])
        self.api(path + "/input", {"id": prompt["id"], "value": "1"})
        with self.assertRaises(HTTPError) as stale:
            self.api(path + "/input", {"id": prompt["id"], "value": "1"})
        self.assertEqual(stale.exception.code, 409)
        while update["code"] is None:
            update = self.api(path + "?after=" + str(cursor))
            output += update["output"]
            cursor = update["cursor"]
        self.assertEqual(update["code"], 0, output)
        self.assertEqual(self.binary.read_bytes(), PAYLOAD)
        self.assertIn("renamed", self.record()["asset_regex"])
        self.assertIn("Verifying SHA-256", output)
        self.release("renamed.worker", "a" * 64)
        failed = "runs/" + self.api("runs", {"action": "update", "app": "demo"})["id"]
        update = self.api(failed)
        while update["code"] is None:
            update = self.api(failed + "?after=" + str(update["cursor"]))
        self.assertNotEqual(update["code"], 0)
        self.assertIn("SHA-256 mismatch", self.api(failed)["output"])
        run = self.api("runs", {"action": "add", "app": "cancel-me"})
        path = "runs/" + run["id"]
        self.api(path + "/cancel", {})
        update = self.api(path)
        while update["code"] is None:
            update = self.api(path + "?after=" + str(update["cursor"]))
        self.assertTrue(update["cancelling"])
        self.assertNotIn("cancel-me", json.loads(self.config.read_text()))


if __name__ == "__main__":
    if sys.argv[1:2] == ["--mock"]:
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
