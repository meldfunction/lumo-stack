#!/usr/bin/env python3
"""Lumo Home: a local dashboard for the Lumo stack on http://127.0.0.1:8090.

Shows what's running, opens Chat (Open WebUI) and Code (OpenCode web), and runs
the one-click Proton login (lumo-login). Listens on 127.0.0.1 only; actions
need the per-run token embedded in the page, and requests must name this host,
so other web pages can't drive it.
"""
import json
import os
import secrets
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8090
HOME = Path.home()
STACK = Path(__file__).resolve().parent


def _settings():
    """Paths from lib.zsh (defaults + this machine's lumo.env)."""
    out = subprocess.run(["/bin/zsh", "-c", f"source {STACK}/lib.zsh && "
                          'print -r -- "$LUMO_HOME|$TAMER_DIR|$BIN_DIR"'],
                         capture_output=True, text=True, timeout=10).stdout.strip()
    lumo_home, tamer_dir, bin_dir = out.split("|")
    return Path(lumo_home), Path(tamer_dir), bin_dir


LUMO, TAMER, BIN_DIR = _settings()
STATE = STACK / ".login-state"
TOKEN = secrets.token_urlsafe(24)
ALLOWED_HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}
ENV = dict(os.environ, PATH=f"{BIN_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
           LUMO_NO_OPEN="1", LUMO_WEB_NO_OPEN="1")

login_proc = None
login_cache = {"t": 0, "value": None}
jobs = {}  # name -> {"running": bool, "ok": bool|None, "msg": str}

# --- Files in and out of the jail -------------------------------------------
# inbox: what the coding assistant can read (read-only inside the jail)
# out:   what it hands back;  code: project folders (downloaded as zip)
AREAS = {"inbox": LUMO / "inbox", "out": LUMO / "out", "code": LUMO / "code"}
MAX_FILE = 200 * 1024 * 1024


def safe_name(name):
    import re
    name = re.sub(r"[^A-Za-z0-9._ -]", "_", os.path.basename(name or "")).strip(" .")
    return name[:120] or "file"


def unique_path(folder, name):
    p, stem, ext, n = folder / name, Path(name).stem, Path(name).suffix, 1
    while p.exists():
        p, n = folder / f"{stem} ({n}){ext}", n + 1
    return p


def resolve_in(area, rel):
    """A path inside an area, refusing anything that escapes it (.., symlinks)."""
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
            out.append({"path": str(p.relative_to(base)), "size": st.st_size, "mtime": int(st.st_mtime)})
    return out[:500]


def fetch_url(url):
    """Download a URL on the Mac into the inbox (the jail itself stays offline)."""
    import ipaddress, re, socket, urllib.parse
    u = urllib.parse.urlparse(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError("Use a full http(s) address.")
    for info in socket.getaddrinfo(u.hostname, None):
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
            raise ValueError("Addresses on this Mac or your local network aren't allowed.")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Lumo Home)"})
    with urllib.request.urlopen(req, timeout=60) as r:
        cd = r.headers.get("Content-Disposition", "")
        m = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)', cd)
        name = safe_name(urllib.parse.unquote(m.group(1)) if m else
                         urllib.parse.unquote(u.path.rsplit("/", 1)[-1]) or u.hostname)
        if "." not in name:
            name += {"text/html": ".html", "application/pdf": ".pdf", "text/plain": ".txt",
                     "application/json": ".json"}.get(r.headers.get_content_type(), "")
        dest = unique_path(AREAS["inbox"], name)
        size = 0
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
    import io, zipfile
    base = resolve_in("code", name)
    if not name or not base.is_dir():
        raise ValueError("No such project.")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(base.rglob("*")):
            if p.is_file() and not p.is_symlink() and ".git" not in p.relative_to(base).parts:
                z.write(p, f"{name}/{p.relative_to(base)}")
    return buf.getvalue()


def http_ok(url, timeout=2):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status < 500
    except urllib.error.HTTPError as e:
        return e.code < 500   # 401 = up but password-protected
    except Exception:
        return False


def run(cmd, timeout=20, cwd=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=ENV, cwd=cwd)
        return p.returncode, p.stdout + p.stderr
    except Exception as e:
        return 1, str(e)


def container_running(name):
    code, out = run(["docker", "inspect", "-f", "{{.State.Running}}", name], 5)
    return code == 0 and out.strip() == "true"


def login_status():
    if time.time() - login_cache["t"] < 30 and login_cache["value"]:
        return login_cache["value"]
    code, out = run(["node", "dist/src/tamer.js", "auth", "status"], 20, cwd=TAMER) if TAMER.exists() else (1, "")
    import re
    out = re.sub(r"\x1b\[[0-9;]*m", "", out)
    m = re.search(r"expiresIn:\s*([^\n]+)", out)
    value = {"valid": "configured and valid" in out, "expires": m.group(1).strip() if m else None}
    login_cache.update(t=time.time(), value=value)
    return value


def status():
    docker_up = run(["docker", "info"], 5)[0] == 0
    return {
        "services": [
            {"name": "lumo-tamer", "detail": "Lumo proxy, 127.0.0.1:3003", "up": http_ok("http://127.0.0.1:3003/health")},
            {"name": "LiteLLM", "detail": "model router, 127.0.0.1:4000", "up": http_ok("http://127.0.0.1:4000/health/liveliness")},
            {"name": "OrbStack", "detail": "containers", "up": docker_up},
            {"name": "Jail relay", "detail": "only network path for the coding agent", "up": docker_up and container_running("lumo-relay")},
            {"name": "Chat", "detail": "Open WebUI, localhost:8080", "up": http_ok("http://127.0.0.1:8080/health")},
            {"name": "Code", "detail": "OpenCode in the browser, localhost:4096", "up": http_ok("http://127.0.0.1:4096")},
        ],
        "login": login_status(),
        "login_flow": read_login_state(),
        "jobs": jobs,
        "projects": sorted(p.name for p in (LUMO / "code").iterdir() if p.is_dir() and not p.name.startswith(".")) if (LUMO / "code").exists() else [],
    }


def read_login_state():
    running = login_proc is not None and login_proc.poll() is None
    try:
        phase, msg, ts = STATE.read_text().strip().split("|", 2)
    except Exception:
        phase, msg, ts = "idle", "", "0"
    return {"running": running, "phase": phase, "message": msg, "at": int(ts)}


def start_job(name, cmd, timeout=300):
    if jobs.get(name, {}).get("running"):
        return
    jobs[name] = {"running": True, "ok": None, "msg": "Working..."}

    def work():
        code, out = run(cmd, timeout)
        lines = [l for l in out.strip().splitlines() if l.strip()]
        jobs[name] = {"running": False, "ok": code == 0, "msg": (lines[-1] if lines else "") if code else "Done."}
        login_cache["t"] = 0
    threading.Thread(target=work, daemon=True).start()


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
            from urllib.parse import urlparse, parse_qs
            q = {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}
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
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        global login_proc
        if not self._host_ok() or not secrets.compare_digest(self.headers.get("X-Lumo-Token", ""), TOKEN):
            return self._send(403, {"error": "Reload the page."})
        length = int(self.headers.get("Content-Length") or 0)
        if self.path == "/api/upload":
            from urllib.parse import unquote
            if not 0 < length <= MAX_FILE:
                return self._send(413, {"error": "Empty or larger than 200 MB."})
            dest = unique_path(AREAS["inbox"], safe_name(unquote(self.headers.get("X-Filename", ""))))
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
        if self.path == "/api/login":
            if login_proc is None or login_proc.poll() is not None:
                login_proc = subprocess.Popen([str(STACK / "lumo-login")], env=ENV,
                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                login_cache["t"] = 0
            return self._send(200, {"ok": True})
        if self.path == "/api/login/cancel":
            if login_proc and login_proc.poll() is None:
                login_proc.terminate()
            return self._send(200, {"ok": True})
        if self.path == "/api/start":
            start_job("start", [str(STACK / "lumo-up"), "--docker"])
            return self._send(200, {"ok": True})
        if self.path == "/api/chat":
            start_job("chat", [str(STACK / "lumo-web")])
            return self._send(200, {"ok": True})
        if self.path == "/api/code":
            project = str(data.get("project") or "")
            if project and not all(c.isalnum() or c in "._-" for c in project):
                return self._send(400, {"error": "Project names: letters, digits, . _ - only."})
            cmd = [str(STACK / "lumo-code")] + (["-p", project] if project else []) + ["--web"]
            start_job("code", cmd)
            return self._send(200, {"ok": True})
        if self.path == "/api/code/stop":
            start_job("code", ["docker", "rm", "-f", "lumo-code-web"], 30)
            return self._send(200, {"ok": True})
        self._send(404, {"error": "not found"})


PAGE = r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lumo Home</title>
<style>
  :root { --bg:#f5f6f8; --card:#fff; --ink:#1b1f24; --muted:#5f6b7a; --line:#dde1e6;
          --accent:#6d4aff; --ok:#1f845a; --bad:#c9372c; --warn:#b26b00; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#14161a; --card:#1d2026; --ink:#e6e8eb; --muted:#9aa3ae; --line:#323843;
            --accent:#9b82ff; --ok:#4bce97; --bad:#f87168; --warn:#f5b041; } }
  * { box-sizing:border-box }
  body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 system-ui,-apple-system,sans-serif }
  main { max-width:880px; margin:0 auto; padding:28px 16px 48px }
  h1 { font-size:22px; margin:0 } .sub { color:var(--muted); margin:2px 0 22px }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(250px,1fr)); gap:14px }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:16px }
  .card h2 { font-size:16px; margin:0 0 6px } .card p { margin:0 0 12px; color:var(--muted); font-size:14px }
  button, .btn { display:inline-block; padding:9px 14px; border:0; border-radius:8px; background:var(--accent);
    color:#fff; font:inherit; font-weight:600; cursor:pointer; text-decoration:none }
  button.ghost { background:transparent; color:var(--ink); border:1px solid var(--line) }
  button:disabled { opacity:.55; cursor:default }
  input { padding:8px 10px; border:1px solid var(--line); border-radius:8px; background:var(--bg); color:var(--ink); font:inherit; width:100% ; margin-bottom:10px }
  .msg { font-size:13px; margin-top:10px; color:var(--muted); min-height:1.2em }
  .msg.ok { color:var(--ok) } .msg.bad { color:var(--bad) }
  ul.svc { list-style:none; margin:0; padding:0 } ul.svc li { display:flex; gap:10px; align-items:baseline; padding:6px 0; border-top:1px solid var(--line) }
  ul.svc li:first-child { border-top:0 }
  .dot { width:9px; height:9px; border-radius:50%; flex:none; background:var(--bad); transform:translateY(1px) }
  .dot.up { background:var(--ok) } .svc small { color:var(--muted); margin-left:auto; text-align:right }
  .pill { display:inline-block; font-size:12px; font-weight:600; padding:2px 8px; border-radius:20px; background:var(--line) }
  .pill.ok { background:color-mix(in srgb, var(--ok) 18%, transparent); color:var(--ok) }
  .pill.bad { background:color-mix(in srgb, var(--bad) 18%, transparent); color:var(--bad) }
  .wide { grid-column:1/-1 } code { font-size:13px }
  .row { display:flex; gap:8px; flex-wrap:wrap }
  .files { display:grid; grid-template-columns:1fr 1fr; gap:20px }
  @media (max-width:640px) { .files { grid-template-columns:1fr } }
  h3 { font-size:14px; margin:0 0 8px } h3 small { color:var(--muted); font-weight:400 }
  .drop { border:2px dashed var(--line); border-radius:10px; padding:18px; text-align:center; color:var(--muted); cursor:pointer }
  .drop.over { border-color:var(--accent); color:var(--ink) }
  ul.flist { list-style:none; margin:8px 0 0; padding:0; font-size:14px }
  ul.flist li { display:flex; gap:8px; align-items:center; padding:5px 0; border-top:1px solid var(--line) }
  ul.flist li span.n { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
  ul.flist li small { color:var(--muted) } ul.flist .empty { color:var(--muted); border:0 }
  ul.flist a, ul.flist button.link { color:var(--accent); background:none; border:0; padding:0; font:inherit; cursor:pointer; text-decoration:none }
</style></head><body><main>
<h1>Lumo Home</h1>
<p class="sub">Proton Lumo on this Mac: chat, a locked-down coding assistant, and your Proton login.</p>
<div class="grid">
  <section class="card">
    <h2>Proton login <span id="loginPill" class="pill">checking</span></h2>
    <p id="loginText">Checking your login...</p>
    <div class="row"><button id="loginBtn">Log in to Proton</button>
      <button id="cancelBtn" class="ghost" hidden>Cancel</button></div>
    <div id="loginMsg" class="msg"></div>
  </section>
  <section class="card">
    <h2>Chat</h2>
    <p>Talk to Lumo in Open WebUI. No tools, no file access.</p>
    <button id="chatBtn">Open Chat</button>
    <div id="chatMsg" class="msg"></div>
  </section>
  <section class="card">
    <h2>Code</h2>
    <p>OpenCode on Lumo in the browser, jailed to <code>~/lumo</code> with no internet.</p>
    <input id="project" list="projects" placeholder="Project (blank = ~/lumo/code)">
    <datalist id="projects"></datalist>
    <div class="row"><button id="codeBtn">Open Code</button><button id="codeStop" class="ghost">Stop</button></div>
    <div id="codeMsg" class="msg">Login: <code>lumo</code>; password in Keychain (lumo-stack / code-web).</div>
  </section>
  <section class="card wide">
    <h2>Files</h2>
    <div class="files">
      <div>
        <h3>Into the jail <small>~/lumo/inbox · read-only for Lumo</small></h3>
        <div id="drop" class="drop" tabindex="0">Drop files here or <u>choose files</u></div>
        <input id="pick" type="file" multiple hidden>
        <form id="fetchForm" class="row" style="margin-top:8px">
          <input id="url" type="url" placeholder="https://… document to download into the inbox" style="flex:1;margin:0">
          <button>Fetch</button></form>
        <div id="inMsg" class="msg"></div>
        <ul id="inbox" class="flist"></ul>
      </div>
      <div>
        <h3>Out of the jail <small>~/lumo/out and projects</small></h3>
        <ul id="out" class="flist"></ul>
        <h3 style="margin-top:14px">Projects <small>download as .zip</small></h3>
        <ul id="projList" class="flist"></ul>
      </div>
    </div>
  </section>
  <section class="card wide">
    <h2>Services</h2>
    <ul id="svc" class="svc"></ul>
    <div class="row" style="margin-top:12px"><button id="startBtn" class="ghost">Start everything</button></div>
    <div id="startMsg" class="msg"></div>
  </section>
</div>
</main>
<script>
(function(){
  var TOKEN = "__TOKEN__", $ = function(id){ return document.getElementById(id); };
  function post(path, body){
    return fetch(path, {method:'POST', headers:{'X-Lumo-Token':TOKEN,'Content-Type':'application/json'},
      body: JSON.stringify(body||{})}).then(function(r){ return r.json(); });
  }
  function msg(el, text, cls){ el.textContent = text||''; el.className = 'msg' + (cls ? ' '+cls : ''); }
  var pending = {};   // job -> {url, win}: tab opened on click, pointed at url once ready
  function tab(name, url){ var w = window.open('', '_blank'); if (w) { w.opener = null; w.document.title = 'Starting...'; w.document.body.textContent = 'Starting ' + name + '...'; } pending[name] = {url:url, win:w}; }
  function job(name, j, el){
    if (!j) return;
    if (j.running) msg(el, 'Starting...');
    else if (j.ok === false) msg(el, j.msg || 'Failed.', 'bad');
    else if (j.ok && pending[name]) { msg(el, 'Ready.', 'ok'); var p = pending[name]; delete pending[name];
      if (p.win && !p.win.closed) p.win.location = p.url; else window.open(p.url, '_blank'); }
  }
  function render(s){
    var ul = $('svc'); ul.textContent = '';
    s.services.forEach(function(x){
      var li = document.createElement('li'), d = document.createElement('span'), n = document.createElement('strong'), sm = document.createElement('small');
      d.className = 'dot' + (x.up ? ' up' : ''); n.textContent = x.name; sm.textContent = x.detail + (x.up ? '' : ' (down)');
      li.append(d, n, sm); ul.append(li);
    });
    var L = s.login, F = s.login_flow, pill = $('loginPill');
    pill.textContent = L.valid ? 'signed in' : 'signed out'; pill.className = 'pill ' + (L.valid ? 'ok' : 'bad');
    $('loginText').textContent = L.valid ? ('Valid' + (L.expires ? ', renews automatically (' + L.expires + ' left)' : '') + '.')
                                         : 'Lumo needs you to sign in to Proton.';
    $('loginBtn').disabled = F.running; $('cancelBtn').hidden = !F.running;
    $('loginBtn').textContent = L.valid ? 'Log in again' : 'Log in to Proton';
    if (F.running || (F.phase !== 'idle' && Date.now()/1000 - F.at < 120))
      msg($('loginMsg'), F.message, F.phase === 'done' ? 'ok' : F.phase === 'failed' ? 'bad' : '');
    var dl = $('projects'); dl.textContent = '';
    s.projects.forEach(function(p){ var o = document.createElement('option'); o.value = p; dl.append(o); });
    job('chat', s.jobs.chat, $('chatMsg')); job('code', s.jobs.code, $('codeMsg')); job('start', s.jobs.start, $('startMsg'));
    if (s.jobs.start && s.jobs.start.ok) msg($('startMsg'), 'Everything is up.', 'ok');
  }
  function refresh(){ fetch('/api/status').then(function(r){ return r.json(); }).then(render).catch(function(){}); }
  $('loginBtn').onclick = function(){ msg($('loginMsg'), 'Opening a browser window...'); post('/api/login').then(refresh); };
  $('cancelBtn').onclick = function(){ post('/api/login/cancel').then(refresh); };
  $('chatBtn').onclick = function(){ tab('chat', 'http://localhost:8080'); post('/api/chat').then(refresh); };
  $('codeBtn').onclick = function(){ tab('code', 'http://localhost:4096'); post('/api/code', {project: $('project').value.trim()}).then(function(r){ if (r.error) msg($('codeMsg'), r.error, 'bad'); refresh(); }); };
  $('codeStop').onclick = function(){ post('/api/code/stop').then(function(){ msg($('codeMsg'), 'Stopped.'); refresh(); }); };
  $('startBtn').onclick = function(){ post('/api/start').then(refresh); };
  // --- Files ---
  function size(n){ return n < 1024 ? n + ' B' : n < 1048576 ? (n/1024).toFixed(1) + ' KB' : (n/1048576).toFixed(1) + ' MB'; }
  function dl(q){ return '/api/download?t=' + encodeURIComponent(TOKEN) + '&' + q; }
  function li(name, meta, actions){
    var l = document.createElement('li'), n = document.createElement('span'), m = document.createElement('small');
    n.className = 'n'; n.textContent = name; n.title = name; m.textContent = meta; l.append(n, m);
    actions.forEach(function(a){ l.append(a); }); return l;
  }
  function link(text, href){ var a = document.createElement('a'); a.textContent = text; a.href = href; return a; }
  function del(area, path){
    var b = document.createElement('button'); b.className = 'link'; b.textContent = 'Delete';
    b.onclick = function(){ if (confirm('Delete ' + path + '?')) post('/api/delete', {area:area, path:path}).then(files); };
    return b;
  }
  function fill(ul, items, empty){ ul.textContent = ''; if (!items.length) { var e = document.createElement('li'); e.className = 'empty'; e.textContent = empty; ul.append(e); } else items.forEach(function(i){ ul.append(i); }); }
  var lastProjects = [];
  function files(){
    fetch('/api/files').then(function(r){ return r.json(); }).then(function(f){
      fill($('inbox'), f.inbox.map(function(x){ return li(x.path, size(x.size), [del('inbox', x.path)]); }), 'Empty');
      fill($('out'), f.out.map(function(x){ return li(x.path, size(x.size), [link('Download', dl('area=out&path=' + encodeURIComponent(x.path))), del('out', x.path)]); }), 'Nothing yet');
    });
    fill($('projList'), lastProjects.map(function(p){ return li(p, '', [link('Download .zip', dl('area=project&name=' + encodeURIComponent(p)))]); }), 'No projects yet');
  }
  function upload(list){
    var n = list.length, done = 0, failed = 0;
    if (!n) return; msg($('inMsg'), 'Uploading ' + n + ' file' + (n > 1 ? 's' : '') + '...');
    Array.prototype.forEach.call(list, function(f){
      fetch('/api/upload', {method:'POST', headers:{'X-Lumo-Token':TOKEN, 'X-Filename':encodeURIComponent(f.name), 'Content-Type':'application/octet-stream'}, body:f})
        .then(function(r){ if (!r.ok) failed++; }).catch(function(){ failed++; })
        .then(function(){ if (++done === n) { msg($('inMsg'), failed ? failed + ' failed (max 200 MB each).' : 'Uploaded to the inbox.', failed ? 'bad' : 'ok'); files(); } });
    });
  }
  var drop = $('drop');
  drop.onclick = function(){ $('pick').click(); };
  drop.onkeydown = function(e){ if (e.key === 'Enter' || e.key === ' ') $('pick').click(); };
  $('pick').onchange = function(){ upload($('pick').files); $('pick').value = ''; };
  ['dragenter','dragover'].forEach(function(t){ drop.addEventListener(t, function(e){ e.preventDefault(); drop.classList.add('over'); }); });
  ['dragleave','drop'].forEach(function(t){ drop.addEventListener(t, function(e){ e.preventDefault(); drop.classList.remove('over'); }); });
  drop.addEventListener('drop', function(e){ upload(e.dataTransfer.files); });
  $('fetchForm').onsubmit = function(e){
    e.preventDefault(); var u = $('url').value.trim(); if (!u) return;
    msg($('inMsg'), 'Downloading...');
    post('/api/fetch', {url:u}).then(function(r){
      if (r.error) msg($('inMsg'), r.error, 'bad'); else { msg($('inMsg'), 'Saved ' + r.name + ' (' + size(r.size) + ') to the inbox.', 'ok'); $('url').value = ''; }
      files();
    });
  };
  var baseRender = render;
  render = function(s){ baseRender(s); if (JSON.stringify(s.projects) !== JSON.stringify(lastProjects)) { lastProjects = s.projects; files(); } };

  refresh(); files(); setInterval(refresh, 3000); setInterval(files, 10000);
})();
</script></body></html>
"""

if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Lumo Home on http://127.0.0.1:{PORT}", flush=True)
    server.serve_forever()
