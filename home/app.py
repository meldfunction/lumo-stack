#!/usr/bin/env python3
"""Lumo Home (container edition): status, Proton sign-in, files, links to Chat and Code.

Runs inside Docker with no access to Docker itself. It reaches the other
services by name on the internal network, and the workspace through its mounts:
  /lumo/inbox (rw)  /lumo/out (rw)  /lumo/code (ro, for project zips)
Actions need the per-run token embedded in the page, and requests must name
localhost, so other web pages can't drive it.
"""
import io
import ipaddress
import json
import os
import re
import secrets
import socket
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORTS = (os.environ.get("LUMO_PUBLIC_PORTS") or "8080,4096,8090,3001").split(",")
WEBUI_PORT, CODEWEB_PORT, HOME_PORT, LOGIN_PORT = PORTS
TOKEN = secrets.token_urlsafe(24)
HELPER_TOKEN = Path("/run/secrets/helper-token").read_text().strip()
ALLOWED_HOSTS = {f"127.0.0.1:{HOME_PORT}", f"localhost:{HOME_PORT}"}
AREAS = {"inbox": Path("/lumo/inbox"), "out": Path("/lumo/out"), "code": Path("/lumo/code")}
MAX_FILE = 200 * 1024 * 1024


def http_ok(url, timeout=2):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status < 500
    except urllib.error.HTTPError as e:
        return e.code < 500          # 401 = up but password-protected
    except Exception:
        return False


def helper(path, method="GET", timeout=10, payload=None):
    data = json.dumps(payload).encode() if payload is not None else (b"" if method == "POST" else None)
    req = urllib.request.Request(f"http://tamer:3010{path}", method=method, data=data,
                                 headers={"X-Lumo-Token": HELPER_TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return json.load(e)
        except Exception:
            return {"error": f"HTTP {e.code}"}
    except Exception as e:
        return {"error": f"lumo-tamer isn't answering ({e.__class__.__name__})"}


def status():
    login = helper("/status", timeout=30)
    return {
        "services": [
            {"name": "lumo-tamer", "detail": "Lumo bridge", "up": http_ok("http://tamer:3003/health")},
            {"name": "LiteLLM", "detail": f"model router, also on localhost for claude-lumo", "up": http_ok("http://litellm:4000/health/liveliness")},
            {"name": "Chat", "detail": f"Open WebUI, localhost:{WEBUI_PORT}", "up": http_ok("http://webui:8080/health")},
            {"name": "Code", "detail": f"coding agent in the browser, localhost:{CODEWEB_PORT}", "up": http_ok("http://code-web:4096")},
            {"name": "Sign-in browser", "detail": f"only while signing in, localhost:{LOGIN_PORT}", "up": http_ok("http://browser:3000")},
        ],
        "login": {"valid": bool(login.get("valid")), "expires": login.get("expires"), "error": login.get("error")},
        "ports": {"webui": WEBUI_PORT, "codeweb": CODEWEB_PORT, "login": LOGIN_PORT},
        "projects": sorted(p.name for p in AREAS["code"].iterdir() if p.is_dir() and not p.name.startswith(".")) if AREAS["code"].exists() else [],
    }


# --- Files in and out of the jail ---------------------------------------------
def safe_name(name):
    name = re.sub(r"[^A-Za-z0-9._ -]", "_", os.path.basename(name or "")).strip(" .")
    return name[:120] or "file"


def unique_path(folder, name):
    p, stem, ext, n = folder / name, Path(name).stem, Path(name).suffix, 1
    while p.exists():
        p, n = folder / f"{stem} ({n}){ext}", n + 1
    return p


def resolve_in(area, rel):
    base = AREAS[area].resolve()
    p = (base / rel).resolve()
    if p != base and base not in p.parents:
        raise ValueError("outside the folder")
    return p


def list_files(area):
    base = AREAS[area]
    out = []
    for p in sorted(base.rglob("*")) if base.exists() else []:
        if p.is_file() and not p.is_symlink() and ".git" not in p.parts:
            st = p.stat()
            out.append({"path": str(p.relative_to(base)), "size": st.st_size})
    return out[:500]


def fetch_url(url):
    u = urllib.parse.urlparse(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError("Use a full http(s) address.")
    for info in socket.getaddrinfo(u.hostname, None):
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
            raise ValueError("Local and private-network addresses aren't allowed.")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Lumo Home)"})
    with urllib.request.urlopen(req, timeout=60) as r:
        m = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)', r.headers.get("Content-Disposition", ""))
        name = safe_name(urllib.parse.unquote(m.group(1)) if m else urllib.parse.unquote(u.path.rsplit("/", 1)[-1]) or u.hostname)
        if "." not in name:
            name += {"text/html": ".html", "application/pdf": ".pdf", "text/plain": ".txt",
                     "application/json": ".json"}.get(r.headers.get_content_type(), "")
        dest, size = unique_path(AREAS["inbox"], name), 0
        with open(dest, "wb") as f:
            while chunk := r.read(1 << 16):
                size += len(chunk)
                if size > MAX_FILE:
                    f.close()
                    dest.unlink(missing_ok=True)
                    raise ValueError("Larger than 200 MB.")
                f.write(chunk)
    return dest.name, size


def zip_project(name):
    base = resolve_in("code", name)
    if not name or not base.is_dir():
        raise ValueError("No such project.")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(base.rglob("*")):
            if p.is_file() and not p.is_symlink() and ".git" not in p.relative_to(base).parts:
                z.write(p, f"{name}/{p.relative_to(base)}")
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode() if ctype == "application/json" else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(body)

    def _host_ok(self):
        return self.headers.get("Host", "") in ALLOWED_HOSTS

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, {"error": "bad host"})
        if self.path in ("/", "/index.html"):
            return self._send(200, PAGE.replace("__TOKEN__", TOKEN), "text/html")
        if self.path == "/api/status":
            return self._send(200, status())
        if self.path == "/api/files":
            return self._send(200, {"inbox": list_files("inbox"), "out": list_files("out")})
        if self.path.startswith("/api/download?"):
            q = {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).items()}
            if not secrets.compare_digest(q.get("t", ""), TOKEN):
                return self._send(403, {"error": "Reload the page."})
            try:
                if q.get("area") == "project":
                    body, fname, ctype = zip_project(q.get("name", "")), safe_name(q.get("name", "")) + ".zip", "application/zip"
                elif q.get("area") in ("inbox", "out"):
                    p = resolve_in(q["area"], q.get("path", ""))
                    if not p.is_file():
                        raise ValueError("No such file.")
                    body, fname, ctype = p.read_bytes(), safe_name(p.name), "application/octet-stream"
                else:
                    raise ValueError("Unknown area.")
            except ValueError as e:
                return self._send(400, {"error": str(e)})
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Disposition", f'attachment; filename="{fname}"')
            self.end_headers()
            self.wfile.write(body)
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._host_ok() or not secrets.compare_digest(self.headers.get("X-Lumo-Token", ""), TOKEN):
            return self._send(403, {"error": "Reload the page."})
        length = int(self.headers.get("Content-Length") or 0)
        if self.path == "/api/upload":
            if not 0 < length <= MAX_FILE:
                return self._send(413, {"error": "Empty or larger than 200 MB."})
            dest = unique_path(AREAS["inbox"], safe_name(urllib.parse.unquote(self.headers.get("X-Filename", ""))))
            remaining = length
            with open(dest, "wb") as f:
                while remaining:
                    chunk = self.rfile.read(min(remaining, 1 << 16))
                    if not chunk:
                        break
                    f.write(chunk)
                    remaining -= len(chunk)
            return self._send(200, {"ok": True, "name": dest.name})
        data = json.loads(self.rfile.read(length) or b"{}") if 0 < length < 10000 else {}
        if self.path == "/api/login-password":
            # Forwarded once to lumo-tamer for Proton's login handshake; never logged or stored here.
            creds = {k: str(data.get(k, ""))[:512] for k in ("username", "password", "totp")}
            r = helper("/login-password", "POST", timeout=150, payload=creds)
            creds.clear()
            return self._send(200 if r.get("ok") else 202 if r.get("captcha") else 400, r)
        if self.path == "/api/login-continue":
            r = helper("/login-continue", "POST", timeout=150, payload={"totp": str(data.get("totp", ""))[:16]})
            return self._send(200 if r.get("ok") else 202 if r.get("captcha") else 400, r)
        if self.path == "/api/login":
            if not http_ok("http://browser:3000"):
                return self._send(400, {"error": "The sign-in browser isn't running. Run: lumo login"})
            r = helper("/login", "POST", timeout=150)
            return self._send(200 if r.get("ok") else 400, r)
        if self.path == "/api/fetch":
            try:
                name, size = fetch_url(str(data.get("url", "")).strip())
                return self._send(200, {"ok": True, "name": name, "size": size})
            except Exception as e:
                return self._send(400, {"error": f"Couldn't fetch it: {e}"})
        if self.path == "/api/delete":
            try:
                area = data.get("area")
                if area not in ("inbox", "out"):
                    raise ValueError("Unknown area.")
                p = resolve_in(area, str(data.get("path", "")))
                if not p.is_file():
                    raise ValueError("No such file.")
                p.unlink()
                return self._send(200, {"ok": True})
            except ValueError as e:
                return self._send(400, {"error": str(e)})
        self._send(404, {"error": "not found"})


PAGE = (Path(__file__).parent / "index.html").read_text()

if __name__ == "__main__":
    print(f"Lumo Home on http://localhost:{HOME_PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8090), Handler).serve_forever()
