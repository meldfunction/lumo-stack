// Sign-in helper for Lumo Home (internal network only, port 3010).
//   GET  /status          -> { valid, expires }
//   POST /login-password  -> { username, password, totp } Proton's direct login.
//                            Answers { ok } or { captcha: url } (login kept open)
//   POST /login-continue  -> { totp } after the CAPTCHA was solved
//   POST /login           -> copies the login from the sign-in browser (fallback)
// POSTs need the X-Lumo-Token header. Passwords are never logged or stored.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { lookup } from 'node:dns/promises';

const TOKEN = readFileSync('/run/secrets/helper-token', 'utf8').trim();
const strip = (s) => s.replace(/\x1b\[[0-9;]*m/g, '');

function tamer(args, input = '') {
  return new Promise((resolve) => {
    const p = spawn('tamer', args, { cwd: '/app' });
    let out = '';
    p.stdout.on('data', (d) => (out += d));
    p.stderr.on('data', (d) => (out += d));
    const t = setTimeout(() => p.kill('SIGTERM'), 120000);
    p.on('close', (code) => { clearTimeout(t); resolve({ code, out: strip(out) }); });
    p.stdin.end(input);
  });
}

async function status() {
  const { out } = await tamer(['auth', 'status']);
  const m = out.match(/expiresIn:\s*([^\n]+)/);
  return { valid: out.includes('configured and valid'), expires: m ? m[1].trim() : null };
}

let busy = false;
let pending = null;   // a direct login waiting for the CAPTCHA to be solved

// Start `tamer auth login` (Proton's SRP login, with Lumo Stack's CAPTCHA support)
// and keep it open, so a CAPTCHA can be solved in between.
function startLogin(username, password) {
  const proc = spawn('tamer', ['auth', 'login'], { cwd: '/app' });
  const st = { proc, out: '', mark: 0, exited: false, waiters: [] };
  const wake = () => st.waiters.splice(0).forEach((w) => w());
  proc.stdout.on('data', (d) => { st.out += strip(String(d)); wake(); });
  proc.stderr.on('data', (d) => { st.out += strip(String(d)); wake(); });
  proc.on('close', () => { st.exited = true; clearTimeout(st.timer); wake(); });
  st.timer = setTimeout(() => proc.kill('SIGTERM'), 10 * 60 * 1000);   // give up after 10 minutes
  proc.stdin.write(`${username}\n${password}\n`);
  return st;
}
function waitFor(st, pred, ms) {
  return new Promise((done) => {
    const t = setTimeout(done, ms);
    const check = () => { if (st.exited || pred()) { clearTimeout(t); done(); } else st.waiters.push(check); };
    check();
  });
}
// Answer prompts until the login finishes or needs a CAPTCHA.
async function drive(st, totp) {
  const fresh = () => st.out.slice(st.mark);
  await waitFor(st, () => /LUMO_HV_URL|2FA TOTP code:/.test(fresh()), 90000);
  const hv = fresh().match(/LUMO_HV_URL (\S+)/);
  if (hv && !st.exited) { pending = st; return { captcha: hv[1] }; }
  if (/2FA TOTP code:/.test(fresh()) && !st.exited) {
    if (!totp) { st.proc.kill('SIGTERM'); return { error: 'This account uses two-factor authentication. Enter your 2FA code and sign in again.' }; }
    st.proc.stdin.write(`${totp}\n`);
  }
  await waitFor(st, () => false, 90000);
  const s2 = await status();
  if (s2.valid) { spawn('pkill', ['-f', 'tamer server']); return { ok: true }; }
  const out = st.out;
  return { error: /9001|human verification|captcha/i.test(out) ? "Proton still wants a CAPTCHA. Solve it in the link, then press Continue; or use the sign-in browser: lumo login --browser"
    : /2FA failed/i.test(out) ? "That 2FA code didn't work. Use a fresh code and sign in again."
    : /Authentication failed|Incorrect|8002|invalid/i.test(out) ? "Proton didn't accept that email and password."
    : 'Sign-in didn\'t finish: ' + out.split('\n').filter((l) => l.trim() && !/password|username|LUMO_HV_URL/i.test(l)).slice(-2).join(' ') };
}
createServer(async (req, res) => {
  const send = (code, body) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };
  try {
    if (req.method === 'GET' && req.url === '/status') return send(200, await status());
    if (req.method === 'POST' && (req.url === '/login-password' || req.url === '/login-continue')) {
      if (req.headers['x-lumo-token'] !== TOKEN) return send(403, { error: 'bad token' });
      let body = '';
      for await (const chunk of req) { body += chunk; if (body.length > 4096) return send(413, { error: 'too large' }); }
      const input = JSON.parse(body || '{}');
      let st;
      if (req.url === '/login-password') {
        if (busy) return send(409, { error: 'A sign-in is already running.' });
        if (!input.username || !input.password) return send(400, { error: 'Enter your Proton email and password.' });
        if (pending) { pending.proc.kill('SIGTERM'); pending = null; }
        busy = true;
        st = startLogin(input.username, input.password);
      } else {
        if (!pending) return send(400, { error: 'No sign-in is waiting. Start again.' });
        st = pending; pending = null; busy = true;
        st.mark = st.out.length;
        st.proc.stdin.write('\n');            // "I solved the CAPTCHA"
      }
      const r = await drive(st, input.totp || '');
      busy = false;
      return send(r.ok ? 200 : (r.captcha ? 202 : 400), r);
    }
    if (req.method === 'POST' && req.url === '/login') {
      if (req.headers['x-lumo-token'] !== TOKEN) return send(403, { error: 'bad token' });
      if (busy) return send(409, { error: 'A sign-in is already running.' });
      busy = true;
      // Chromium only accepts debugging requests addressed to an IP (not the
      // container name), so resolve the sign-in browser first.
      let cdp;
      try { cdp = `http://${(await lookup('browser', { family: 4 })).address}:9222`; }
      catch { busy = false; return send(400, { error: "The sign-in browser isn't running. Run: lumo login" }); }
      // Refuse guest mode: Lumo works without an account, and a guest session
      // would replace a real login.
      const tabs = async () => { try { return (await (await fetch(`${cdp}/json/list`, { signal: AbortSignal.timeout(5000) })).json()).map((p) => p.url || ''); } catch { return []; } };
      const signedIn = (us) => us.some((u) => /lumo\.proton\.me\/u\//.test(u) && !u.includes('/guest'));
      let urls = await tabs();
      // Signed in on Proton's account page? Open Lumo in that browser ourselves:
      // the Proton session carries over, and Lumo lands on the signed-in app.
      if (!signedIn(urls)) {
        try { await fetch(`${cdp}/json/new?https://lumo.proton.me/`, { method: 'PUT', signal: AbortSignal.timeout(5000) }); } catch {}
        for (let i = 0; i < 20 && !signedIn(urls); i++) { await new Promise((r) => setTimeout(r, 1000)); urls = await tabs(); }
      }
      const lumo = urls.filter((u) => u.includes('lumo.proton.me'));
      if (!lumo.some((u) => /lumo\.proton\.me\/u\//.test(u) && !u.includes('/guest'))) {
        busy = false;
        return send(400, { error: lumo.some((u) => u.includes('/guest'))
          ? "You're not signed in to Proton yet. In the sign-in browser, sign in on Proton's page first, then try again."
          : "Couldn't find a signed-in Proton session in the sign-in browser. Sign in there first, then try again." });
      }
      const r = await tamer(['auth', 'browser'], `${cdp}\n`);
      busy = false;
      const ok = r.out.includes('configured and valid');
      if (ok) spawn('pkill', ['-f', 'tamer server']);   // start.sh restarts it
      return send(ok ? 200 : 400, ok ? { ok: true } : { error: r.out.split('\n').filter(Boolean).slice(-3).join(' ') });
    }
    send(404, { error: 'not found' });
  } catch (e) { busy = false; send(500, { error: String(e) }); }
}).listen(3010, '0.0.0.0');
