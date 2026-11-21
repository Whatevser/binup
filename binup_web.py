#!/usr/bin/env python3
"""Local web frontend for binup.sh. Requires Python 3 on Linux."""
import argparse
import codecs
from collections import deque
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import secrets
import selectors
import signal
import socket
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parent
SCRIPT = str(ROOT / "binup.sh")
STATIC = {"/": ("index.html", "text/html"), "/entry.js": ("standalone.js", "text/javascript"),
          "/app.js": ("app.js", "text/javascript"),
          "/style.css": ("style.css", "text/css")}
OUTPUT_LIMIT = 256 * 1024
HISTORY_LIMIT = 12


class RequestError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class LocalAccess:
    """Trust the TCP peer. Only accept literal local addresses and known Host names."""
    def __init__(self, extra_networks=(), aliases=()):
        local = ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                 "100.64.0.0/10", "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10")
        self.networks = [ipaddress.ip_network(prefix) for prefix in (*local, *extra_networks)]
        if any(net.prefixlen == 0 for net in self.networks):
            raise ValueError("Specify the actual tunnel subnet in BINUP_EXTRA_NETWORKS.")
        hostname = socket.gethostname().split(".")[0]
        self.names = {name.lower().rstrip(".") for name in
                      ("localhost", hostname, hostname + ".local", socket.getfqdn(), *aliases)}

    def permits_ip(self, host):
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            return False
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            address = address.ipv4_mapped
        return any(address in network for network in self.networks)

    def permits_host(self, authority):
        if not authority or any(c.isspace() or c in "/\\@?#," for c in authority):
            return False
        try:
            url = urlsplit("//" + authority)
            host = url.hostname
            if not host:
                return False
            expected = f"[{host}]" if ":" in host else host
            if url.port is not None:
                expected += f":{url.port}"
            if authority.lower() != expected.lower():
                return False
        except ValueError:
            return False
        return self.permits_ip(host) or host.lower().rstrip(".") in self.names


class LocalServer(ThreadingHTTPServer):
    def verify_request(self, request, client_address):
        return self.access.permits_ip(client_address[0])


class IPv6Server(LocalServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        if self.server_address[0] == "::" and socket.has_dualstack_ipv6():
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


class Run:
    """One CLI process group. Prompts have a dedicated pipe and a single-use ID."""
    def __init__(self, action, target, argv, env):
        self.id = secrets.token_hex(8)
        self.action, self.target = action, target
        self.started = time.time()
        self.code = None
        self.cancelling = False
        self.prompt = None
        self.seq = self.chars = 0
        self.discarded = -1
        self.events = deque()
        self.changed = threading.Condition()
        reader, writer = os.pipe()
        # The bash config lock uses fd 9. Pass an independent high fd.
        prompt_fd = fcntl.fcntl(writer, fcntl.F_DUPFD_CLOEXEC, 50)
        os.close(writer)
        try:
            self.process = subprocess.Popen(["/bin/bash", SCRIPT, *argv], env=dict(env, BINUP_PROMPT_FD=str(prompt_fd)),
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                            pass_fds=(prompt_fd,), start_new_session=True)
        except BaseException:
            os.close(reader)
            raise
        finally:
            os.close(prompt_fd)
        self.thread = threading.Thread(target=self.watch, args=(reader,), name="binup-" + self.id)
        self.thread.start()

    def notify(self):
        self.seq += 1
        self.changed.notify_all()

    def append(self, text):
        if not text:
            return
        with self.changed:
            self.notify()
            self.events.append((self.seq, text))
            self.chars += len(text)
            while self.chars > OUTPUT_LIMIT or len(self.events) > 4096:
                self.discarded, old = self.events.popleft()
                self.chars -= len(old)

    def watch(self, reader):
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        pending = b""
        try:
            with os.fdopen(reader, "rb", buffering=0) as prompts, selectors.DefaultSelector() as selector:
                selector.register(self.process.stdout, selectors.EVENT_READ, "output")
                selector.register(prompts, selectors.EVENT_READ, "prompt")
                while selector.get_map():
                    for key, _ in selector.select():
                        data = os.read(key.fd, 8192)
                        if not data:
                            selector.unregister(key.fileobj)
                            if key.data == "output":
                                self.append(decoder.decode(b"", final=True))
                        elif key.data == "output":
                            self.append(decoder.decode(data))
                        else:
                            pending += data
                            while b"\n" in pending:
                                line, pending = pending.split(b"\n", 1)
                                item = json.loads(line)
                                with self.changed:
                                    self.append("\n? " + item["label"] + "\n")
                                    self.notify()
                                    self.prompt = dict(id=self.seq, label=item["label"], default=item["default"])
        except (OSError, ValueError, KeyError) as exc:
            self.append(f"\n! Console stream failed: {exc}\n")
            self.cancel()
        finally:
            code = self.process.wait()
            with self.changed:
                self.process.stdout.close()
                self.process.stdin.close()
                self.code = code
                self.prompt = None
                self.notify()

    def summary(self):
        with self.changed:
            return dict(id=self.id, action=self.action, target=self.target, started=self.started,
                        code=self.code, cancelling=self.cancelling)

    def poll(self, cursor):
        with self.changed:
            if self.seq == cursor and self.code is None:
                self.changed.wait_for(lambda: self.seq != cursor or self.code is not None, 12)
            return dict(self.summary(), cursor=self.seq, truncated=cursor < self.discarded,
                        output="".join(text for number, text in self.events if number > cursor), prompt=self.prompt)

    def answer(self, prompt_id, value):
        if not isinstance(value, str) or len(value.encode()) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise RequestError(400, "Enter one line, up to 4096 bytes.")
        with self.changed:
            if self.cancelling or self.code is not None or not self.prompt or self.prompt["id"] != prompt_id:
                raise RequestError(409, "This prompt has already closed. Read the current output.")
            try:
                self.process.stdin.write((value + "\n").encode())
                self.process.stdin.flush()
            except (BrokenPipeError, ValueError):
                raise RequestError(409, "The command closed its input.") from None
            self.prompt = None
            self.notify()

    def cancel(self):
        with self.changed:
            if self.code is not None or self.cancelling:
                return
            self.cancelling = True
            self.prompt = None
            self.append("\n! Cancellation requested. Waiting for the command to finish recovery.\n")
            try:
                os.killpg(self.process.pid, signal.SIGINT)
            except ProcessLookupError:
                pass
            self.process.stdin.close()


class Control:
    def __init__(self, config):
        self.config = config
        self.env = dict(os.environ, BINUP_CONF=str(config), BINUP_WEB="1", TERM="dumb",
                        SYSTEMD_PAGER="cat", SYSTEMD_COLORS="0", SYSTEMD_ASK_PASSWORD_AGENT="0")
        self.env.pop("BINUP_PROMPT_FD", None)
        self.lock = threading.Lock()
        self.runs = {}
        self.stopping = False

    def entries(self):
        try:
            with self.config.open() as stream:
                entries = json.load(stream)
        except FileNotFoundError:
            return {}
        if not isinstance(entries, dict):
            raise RequestError(500, "Invalid binup configuration. Expected an object of registered apps.")
        return entries

    def command(self, *argv):
        return subprocess.run(["/bin/bash", SCRIPT, *argv], env=self.env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8",
                              errors="replace", timeout=25)

    def state(self):
        result = self.command("list", "--json")
        if result.returncode:
            raise RequestError(500, result.stderr.strip() or "Could not list applications.")
        with self.lock:
            runs = [run.summary() for run in reversed(list(self.runs.values()))]
        return dict(apps=json.loads(result.stdout), runs=runs)

    def app_name(self, value, *, new=False, all_apps=False):
        if all_apps and value == "all":
            return value
        if (not isinstance(value, str) or not value.strip() or len(value) > 255 or
                value in ("all", "-f", "--force") or any(ord(c) < 32 or ord(c) == 127 for c in value)):
            raise RequestError(400, "Choose a valid application name.")
        exists = value in self.entries()
        if new and exists:
            raise RequestError(409, "This app is already registered. Use Edit.")
        if not new and not exists:
            raise RequestError(404, "Application is no longer registered.")
        return value

    def begin(self, body):
        action = body.get("action")
        if action not in ("add", "edit", "check", "update", "reinstall", "remove", "start", "stop", "restart"):
            raise RequestError(400, "Unknown action.")
        target = self.app_name(body.get("app"), new=action == "add", all_apps=action in ("check", "update"))
        if action in ("start", "stop", "restart"):
            argv = ["service", target, action]
        elif action == "reinstall":
            argv = ["update", "--force", target]
        else:
            argv = [action, target]
        with self.lock:
            if self.stopping or any(run.summary()["code"] is None for run in self.runs.values()):
                raise RequestError(409, "A command is already running. Open its live output.")
            if len(self.runs) >= HISTORY_LIMIT:
                del self.runs[next(iter(self.runs))]
            run = Run(action, target, argv, self.env)
            self.runs[run.id] = run
            return run.summary()

    def lookup(self, identifier):
        with self.lock:
            run = self.runs.get(identifier)
        if run is None:
            raise RequestError(404, "This run is no longer in history.")
        return run

    def shutdown(self):
        with self.lock:
            self.stopping = True
            runs = list(self.runs.values())
        for run in runs:
            run.cancel()
        for run in runs:
            run.thread.join()


class Handler(BaseHTTPRequestHandler):
    server_version = "binup"
    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def log_message(self, fmt, *args):
        # Routine polls would drown out service errors in the journal.
        if args and len(args) >= 2 and str(args[1]).startswith("5"):
            super().log_message(fmt, *args)

    def send_bytes(self, status, content, mime):
        self.send_response(status)
        self.send_header("Content-Type", mime + "; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; "
                         "connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.end_headers()
        self.wfile.write(content)

    def body(self):
        if self.headers.get_content_type() != "application/json":
            raise RequestError(415, "Send a JSON object.")
        size = int(self.headers.get("Content-Length", "0"))
        if size < 2 or size > 32768:
            raise RequestError(400, "Invalid request size.")
        data = json.loads(self.rfile.read(size))
        if not isinstance(data, dict):
            raise RequestError(400, "Expected a JSON object.")
        return data

    def api(self, method, path, query):
        authority = self.headers["Host"].lower()
        origin = self.headers.get("Origin")
        if origin:
            source = urlsplit(origin)
            if source.scheme not in ("http", "https") or source.netloc.lower() != authority:
                raise RequestError(403, "Request origin does not match this server.")
        if self.headers.get("Sec-Fetch-Site") == "cross-site":
            raise RequestError(403, "Open Binup directly or through Cockpit.")
        control = self.server.control
        if method == "GET" and path == "/api/state":
            return control.state()
        if method == "GET" and path in ("/api/logs", "/api/status"):
            name = control.app_name(query.get("app", [""])[0])
            result = control.command(path.rsplit("/", 1)[1], name)
            return dict(output=result.stdout + result.stderr, code=result.returncode)
        if method == "POST" and path == "/api/runs":
            return control.begin(self.body())
        parts = path.strip("/").split("/")
        if len(parts) in (3, 4) and parts[:2] == ["api", "runs"]:
            run = control.lookup(parts[2])
            if method == "GET" and len(parts) == 3:
                cursor = int(query.get("after", ["-1"])[0])
                return run.poll(cursor)
            if method == "POST" and len(parts) == 4:
                body = self.body()
                if parts[3] == "input":
                    run.answer(body.get("id"), body.get("value"))
                    return {"ok": True}
                if parts[3] == "cancel":
                    run.cancel()
                    return {"ok": True}
        raise RequestError(404, "Unknown endpoint.")

    def dispatch(self, method):
        try:
            hosts = self.headers.get_all("Host", [])
            if len(hosts) != 1 or not self.server.access.permits_host(hosts[0]):
                self.send_bytes(403, b'{"error":"Use the server IP or a configured local hostname."}', "application/json")
                return
            url = urlsplit(self.path)
            if method == "GET" and url.path in self.server.files:
                mime, data = self.server.files[url.path]
                self.send_bytes(200, data, mime)
                return
            try:
                data = self.api(method, url.path, parse_qs(url.query, max_num_fields=8))
                status = 200
            except RequestError as error:
                status, data = error.status, {"error": str(error)}
            except (ValueError, UnicodeError):
                status, data = 400, {"error": "Invalid request or configuration data."}
            except subprocess.TimeoutExpired:
                status, data = 504, {"error": "Timed out waiting for the service manager."}
            except OSError as error:
                status, data = 500, {"error": str(error)}
            self.send_bytes(status, json.dumps(data).encode(), "application/json")
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("serve",))
    parser.add_argument("--config", type=Path, default=ROOT / "binup.json")
    # Units generated by older installers pass this argument until reinstalled.
    parser.add_argument("--token-file", help=argparse.SUPPRESS)
    parser.add_argument("--bind", default="::" if socket.has_dualstack_ipv6() else "0.0.0.0")
    parser.add_argument("--port", type=int, default=9098)
    args = parser.parse_args()
    access = LocalAccess(os.environ.get("BINUP_EXTRA_NETWORKS", "").split(),
                         os.environ.get("BINUP_HOSTNAMES", "").split())
    files = {url: (mime, (ROOT / "web" / name).read_bytes()) for url, (name, mime) in STATIC.items()}
    stopped = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: stopped.set())
    server_class = IPv6Server if ":" in args.bind else LocalServer
    with server_class((args.bind, args.port), Handler) as server:
        server.control = Control(args.config.resolve())
        server.files, server.access, server.timeout = files, access, 0.4
        print(f"Binup listening on {args.bind}:{server.server_port}", flush=True)
        try:
            while not stopped.is_set():
                server.handle_request()
        finally:
            server.control.shutdown()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(str(error))
