// pbweb — the admin UI server (docs/admin-ui.md).
//
// Serves the static pages Astro built on the laptop, plus a small JSON API.
// Runs in a container from the Orca image, as uid 1000, holding no
// privilege: everything it does is a mount or the pb-priv socket.
//
// Node builtins only. There is no package.json on the box and no npm install
// at boot — the runtime is whatever the Orca image already has.
import { createServer } from 'node:http';
import { readFile, writeFile, statfs } from 'node:fs/promises';
import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { connect } from 'node:net';
import { loadavg, cpus } from 'node:os';

const PORT = Number(process.env.ADMIN_PORT || 8080);

// Empty on the box. scripts/test-pbweb.sh points it at a fixture tree so the
// server can be exercised on a laptop — booting a VM per edit is a slow loop.
const ROOT = process.env.PB_ROOT || '';

const ETC = `${ROOT}/app/etc`; // /etc/pocketbastion, read-only
const UI = `${ETC}/ui`;
const SEED_HASH = `${ETC}/admin.hash`;
const FIREWALL_ENV = `${ETC}/firewall.env`;
const HASH_FILE = `${ROOT}/state/admin/admin.hash`;
const STATUS_FILE = `${ROOT}/run/pocketbastion/agent-status.json`;
const PRIV_SOCK = `${ROOT}/run/pb-priv.sock`;

const SESSION_MS = 12 * 60 * 60 * 1000;
const RATE_WINDOW_MS = 60 * 1000;
const RATE_MAX = 5;

// ── helpers ──────────────────────────────────────────────────────────────────

const read = (path) => readFile(path, 'utf8');
const readOr = (path, fallback = '') => read(path).catch(() => fallback);

/** KEY=value / KEY="value" lines, as written by render-ignition.sh and by hand. */
function parseEnv(text) {
  const out = {};
  for (const line of text.split('\n')) {
    const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (m) out[m[1]] = m[2].trim().replace(/^(["'])(.*)\1$/, '$2');
  }
  return out;
}

/**
 * One line in, one line out. systemd starts a fresh root process per
 * connection; the verb allowlist lives there, not here.
 */
function priv(line) {
  return new Promise((resolve, reject) => {
    const sock = connect(PRIV_SOCK);
    let out = '';
    sock.setTimeout(5000, () => sock.destroy(new Error('pb-priv timed out')));
    sock.on('connect', () => sock.end(`${line}\n`));
    sock.on('data', (d) => (out += d));
    sock.on('end', () => resolve(out.trim()));
    sock.on('error', reject);
  });
}

// ── password ─────────────────────────────────────────────────────────────────

function makeHash(password) {
  const salt = randomBytes(16);
  return `scrypt:${salt.toString('base64')}:${scryptSync(password, salt, 32).toString('base64')}`;
}

/** scrypt:<salt-b64>:<hash-b64>, as produced by scripts/admin-hash.sh. */
function verifyPassword(password, stored) {
  const [scheme, saltB64, hashB64] = stored.trim().split(':');
  if (scheme !== 'scrypt' || !saltB64 || !hashB64) return false;
  const expect = Buffer.from(hashB64, 'base64');
  const got = scryptSync(password, Buffer.from(saltB64, 'base64'), expect.length);
  return got.length === expect.length && timingSafeEqual(got, expect);
}

/**
 * Seed the state copy from the rendered one on first start, then never look at
 * the rendered one again — so a password changed in the UI survives a reflash.
 * Deleting the state copy over SSH is the documented reset path.
 */
async function loadHash() {
  const state = (await readOr(HASH_FILE)).trim();
  if (state) return state;

  const seed = (await read(SEED_HASH)).trim();
  await writeFile(HASH_FILE, `${seed}\n`, { mode: 0o600 });
  console.log(`seeded ${HASH_FILE} from ${SEED_HASH}`);
  return seed;
}

/**
 * Whether the password is still the one rendered from deploy.env. Compared
 * rather than remembered: "did I seed it during this start" is false on every
 * restart after the first, which would report an unchanged password as changed.
 */
async function usingSeedPassword() {
  const [state, seed] = await Promise.all([readOr(HASH_FILE), readOr(SEED_HASH)]);
  return state.trim() !== '' && state.trim() === seed.trim();
}

// ── sessions ─────────────────────────────────────────────────────────────────

// ponytail: in-memory, so a container restart logs everyone out. That is the
// whole session store; persist it only if restarts ever become frequent enough
// to notice.
const sessions = new Map(); // token -> expiry ms

function newSession() {
  const token = randomBytes(32).toString('base64url');
  sessions.set(token, Date.now() + SESSION_MS);
  return token;
}

function validSession(req) {
  const cookie = /(?:^|;\s*)pb=([A-Za-z0-9_-]+)/.exec(req.headers.cookie || '');
  if (!cookie) return false;
  const expiry = sessions.get(cookie[1]);
  if (!expiry) return false;
  if (expiry < Date.now()) return sessions.delete(cookie[1]), false;
  return cookie[1];
}

// ponytail: one global window, not per-IP — there is one account, and the
// attacker worth rate-limiting (the Orca container) shares the box's
// address anyway, so per-IP would buy nothing.
let failures = [];
function rateLimited() {
  const cutoff = Date.now() - RATE_WINDOW_MS;
  failures = failures.filter((t) => t > cutoff);
  return failures.length >= RATE_MAX;
}

// ── status ───────────────────────────────────────────────────────────────────

const fmtBytes = (n) =>
  n >= 1024 ** 3 ? `${(n / 1024 ** 3).toFixed(1)} GB` : `${Math.max(1, Math.round(n / 1024 ** 2))} MB`;

/** The root-written status file (docs/admin-ui.md); null until the timer runs. */
async function agentStatus() {
  try {
    return JSON.parse(await read(STATUS_FILE));
  } catch {
    return null;
  }
}

async function status() {
  const fw = parseEnv(await readOr(FIREWALL_ENV));
  const rows = {};

  rows.networks = { value: fw.TRUSTED_CIDRS || 'none — box is locked down', state: fw.TRUSTED_CIDRS ? 'ok' : 'bad' };
  rows.ports = { value: ['22', fw.ADMIN_PORT, fw.ORCA_PORTS].filter(Boolean).join(' ') };

  rows.adminPassword = (await usingSeedPassword())
    ? { value: 'still the one from deploy.env', state: 'warn' }
    : { value: 'changed on the box', state: 'ok' };

  // The amber rows below all point at the same place: the one-time setup in
  // the Orca terminal (docs/admin-ui.md). The status file is up to a minute
  // stale, so "just done" shows for a moment as still missing.
  const ag = await agentStatus();
  const stale = { value: 'unknown — no status file yet', state: 'warn' };
  rows.github = !ag
    ? stale
    : ag.github
      ? { value: `authed as ${ag.github}`, state: 'ok' }
      : { value: 'not authed — gh auth login in the Orca terminal', state: 'warn' };
  const agents = [ag?.claude && 'Claude', ag?.codex && 'Codex'].filter(Boolean);
  rows.agents = !ag
    ? stale
    : agents.length
      ? { value: `${agents.join(' + ')} authed`, state: 'ok' }
      : { value: 'neither authed — run claude or codex in the Orca terminal', state: 'warn' };
  rows.gitIdentity = !ag
    ? stale
    : ag.gitEmail
      ? { value: ag.gitEmail, state: 'ok' }
      : { value: 'unset — git config in the Orca terminal', state: 'warn' };
  rows.repos = !ag
    ? stale
    : ag.repos?.length
      ? { value: ag.repos.map((r) => `${r.name} (${fmtBytes(r.kb * 1024)})`).join(', ') }
      : { value: 'none — clone from the Orca terminal' };

  const mem = parseEnv((await readOr('/proc/meminfo')).replace(/:\s+/g, '='));
  const total = Number.parseInt(mem.MemTotal, 10) * 1024;
  const avail = Number.parseInt(mem.MemAvailable, 10) * 1024;
  const swap = Number.parseInt(mem.SwapTotal || '0', 10) * 1024;
  rows.memory = {
    value: `${fmtBytes(avail)} free of ${fmtBytes(total)}${swap ? `, ${fmtBytes(swap)} zram` : ', no swap'}`,
    state: avail / total < 0.1 ? 'bad' : avail / total < 0.2 ? 'warn' : 'ok',
  };

  const load = loadavg()[0];
  const ncpu = cpus().length;
  rows.load = { value: `${load.toFixed(2)} (${ncpu} cpus)`, state: load > ncpu ? 'warn' : 'ok' };

  // The Pi throttles around 80 °C. The zone file is absent on the mock VM, and
  // the row is simply omitted with it.
  const milli = Number.parseInt(await readOr('/sys/class/thermal/thermal_zone0/temp'), 10);
  if (Number.isFinite(milli)) {
    const temp = milli / 1000;
    rows.temperature = {
      value: `${temp.toFixed(0)} °C`,
      state: temp >= 80 ? 'bad' : temp >= 70 ? 'warn' : 'ok',
    };
  }

  const active = await priv('is-active orca').catch((e) => `unreachable (${e.message})`);
  rows.containers = active === 'active'
    ? { value: 'Orca running', state: 'ok' }
    : { value: `Orca ${active}`, state: 'bad' };

  const fs = await statfs(`${ROOT}/state/admin`).catch(() => null);
  if (fs) {
    const free = fs.bavail * fs.bsize;
    const size = fs.blocks * fs.bsize;
    rows.disk = {
      value: `${fmtBytes(free)} free of ${fmtBytes(size)}`,
      state: free / size < 0.1 ? 'bad' : free / size < 0.2 ? 'warn' : 'ok',
    };
  }

  return rows;
}

// ── server ───────────────────────────────────────────────────────────────────

let adminHash = await loadHash();

function send(res, code, body, headers = {}) {
  res.writeHead(code, { 'cache-control': 'no-store', ...headers });
  res.end(body);
}

const json = (res, code, obj, headers) =>
  send(res, code, JSON.stringify(obj), { 'content-type': 'application/json', ...headers });

async function body(req, limit = 4096) {
  let data = '';
  for await (const chunk of req) {
    data += chunk;
    if (data.length > limit) throw new Error('body too large');
  }
  return data ? JSON.parse(data) : {};
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://box');
  const path = url.pathname;

  try {
    if (req.method === 'POST' && path === '/api/login') {
      if (rateLimited()) return json(res, 429, { error: 'too many attempts' });
      const { password } = await body(req);
      if (typeof password !== 'string' || !verifyPassword(password, adminHash)) {
        failures.push(Date.now());
        return json(res, 401, { error: 'wrong password' });
      }
      failures = [];
      return json(res, 200, { ok: true }, {
        'set-cookie': `pb=${newSession()}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${SESSION_MS / 1000}`,
      });
    }

    if (req.method === 'POST' && path === '/api/logout') {
      const token = validSession(req);
      if (token) sessions.delete(token);
      return send(res, 303, '', { location: '/login.html', 'set-cookie': 'pb=; HttpOnly; Path=/; Max-Age=0' });
    }

    if (path === '/login.html') return send(res, 200, await read(`${UI}/login.html`), { 'content-type': 'text/html; charset=utf-8' });

    // Everything below needs a session. Pages redirect so a bookmarked URL
    // lands somewhere useful; the API answers 401 so fetch() can react.
    if (!validSession(req)) {
      if (path.startsWith('/api/')) return json(res, 401, { error: 'not logged in' });
      return send(res, 303, '', { location: '/login.html' });
    }

    if (req.method === 'GET' && path === '/api/status') {
      return json(res, 200, await status());
    }

    if (req.method === 'GET' && path === '/api/pairing') {
      const ag = await agentStatus();
      return json(res, 200, { ready: ag?.ready ?? null, devices: ag?.devices ?? null });
    }

    if (req.method === 'GET' && path === '/api/logs') {
      return send(res, 200, await priv('logs orca'), { 'content-type': 'text/plain; charset=utf-8' });
    }

    if (req.method === 'POST' && (path === '/api/restart' || path === '/api/reset-pairing')) {
      const out = await priv(path === '/api/restart' ? 'restart orca' : 'reset-pairing');
      return out === 'OK' ? json(res, 200, { ok: true }) : json(res, 502, { error: out });
    }

    if (req.method === 'POST' && path === '/api/password') {
      const { current, next } = await body(req);
      if (typeof current !== 'string' || !verifyPassword(current, adminHash)) {
        return json(res, 403, { error: 'wrong current password' });
      }
      if (typeof next !== 'string' || next.length < 8) {
        return json(res, 400, { error: 'new password must be at least 8 characters' });
      }
      adminHash = makeHash(next);
      await writeFile(HASH_FILE, `${adminHash}\n`, { mode: 0o600 });
      // Every session, the caller's included: if the change was made out of
      // suspicion, that is the behaviour you want (docs/admin-ui.md).
      sessions.clear();
      return json(res, 200, { ok: true });
    }

    // The static pages. The pattern admits no dot and no slash, so there is
    // nothing to traverse; an unknown name falls through to the 404.
    if (req.method === 'GET' && (path === '/' || /^\/[a-z-]+\.html$/.test(path))) {
      const html = await readOr(`${UI}${path === '/' ? '/index.html' : path}`);
      if (html) return send(res, 200, html, { 'content-type': 'text/html; charset=utf-8' });
    }

    return send(res, 404, 'not found', { 'content-type': 'text/plain' });
  } catch (e) {
    console.error(`${req.method} ${path}:`, e);
    return send(res, 500, 'server error', { 'content-type': 'text/plain' });
  }
});

// node is PID 1 in the container, and PID 1 gets no default signal handling —
// without this, every restart sits through podman's 10s stop timeout and dies
// on SIGKILL. Nothing here needs flushing: sessions are deliberately in-memory.
process.on('SIGTERM', () => process.exit(0));

server.listen(PORT, '0.0.0.0', () => console.log(`pbweb listening on ${PORT}`));
