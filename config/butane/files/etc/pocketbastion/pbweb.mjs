// pbweb — the admin UI server (docs/admin-ui.md).
//
// Serves the static pages Astro built on the laptop, plus a small JSON API.
// Runs in a container from the OpenCode image, as uid 1000, holding no
// privilege: everything it does is a mount or the pb-priv socket.
//
// Node builtins only. There is no package.json on the box and no npm install
// at boot — the runtime is whatever the OpenCode image already has.
import { createServer } from 'node:http';
import { readFile, writeFile, readdir, statfs } from 'node:fs/promises';
import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { connect } from 'node:net';

const PORT = Number(process.env.ADMIN_PORT || 8080);

// Empty on the box. scripts/test-pbweb.sh points it at a fixture tree so the
// server can be exercised on a laptop — booting a VM per edit is a slow loop.
const ROOT = process.env.PB_ROOT || '';

const ETC = `${ROOT}/app/etc`; // /etc/pocketbastion, read-only
const UI = `${ETC}/ui`;
const SEED_HASH = `${ETC}/admin.hash`;
const FIREWALL_ENV = `${ETC}/firewall.env`;
const HASH_FILE = `${ROOT}/state/admin/admin.hash`;
const OPENCODE_ENV = `${ROOT}/state/secrets/opencode.env`;
const GIT_SECRETS = `${ROOT}/state/secrets/git`;
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
// attacker worth rate-limiting (the OpenCode container) shares the box's
// address anyway, so per-IP would buy nothing.
let failures = [];
function rateLimited() {
  const cutoff = Date.now() - RATE_WINDOW_MS;
  failures = failures.filter((t) => t > cutoff);
  return failures.length >= RATE_MAX;
}

// ── status ───────────────────────────────────────────────────────────────────

const fmtBytes = (n) => `${(n / 1024 ** 3).toFixed(1)} GB`;

async function status() {
  const fw = parseEnv(await readOr(FIREWALL_ENV));
  const rows = {};

  rows.networks = { value: fw.TRUSTED_CIDRS || 'none — box is locked down', state: fw.TRUSTED_CIDRS ? 'ok' : 'bad' };
  rows.ports = { value: ['22', fw.ADMIN_PORT, fw.OPENCODE_PORTS].filter(Boolean).join(' ') };

  const oc = parseEnv(await readOr(OPENCODE_ENV));
  rows.opencodePassword = oc.OPENCODE_SERVER_PASSWORD
    ? { value: 'set', state: 'ok' }
    : { value: 'not set — the UI is open to anyone who can reach it', state: 'bad' };

  rows.adminPassword = (await usingSeedPassword())
    ? { value: 'still the one from deploy.env', state: 'warn' }
    : { value: 'changed on the box', state: 'ok' };

  const metas = await readdir(GIT_SECRETS).then((f) => f.filter((n) => n.endsWith('.meta'))).catch(() => []);
  const parsed = await Promise.all(metas.map(async (n) => parseEnv(await readOr(`${GIT_SECRETS}/${n}`))));
  const unverified = parsed.filter((m) => m.verified !== 'true').length;
  rows.repos = parsed.length === 0
    ? { value: 'none configured' }
    : unverified
      ? { value: `${parsed.length}, ${unverified} unverified`, state: 'warn' }
      : { value: `${parsed.length}, all verified`, state: 'ok' };

  const mem = parseEnv((await readOr('/proc/meminfo')).replace(/:\s+/g, '='));
  const total = Number.parseInt(mem.MemTotal, 10) * 1024;
  const avail = Number.parseInt(mem.MemAvailable, 10) * 1024;
  const swap = Number.parseInt(mem.SwapTotal || '0', 10) * 1024;
  rows.memory = {
    value: `${fmtBytes(avail)} free of ${fmtBytes(total)}${swap ? `, ${fmtBytes(swap)} zram` : ', no swap'}`,
    state: avail / total < 0.1 ? 'bad' : avail / total < 0.2 ? 'warn' : 'ok',
  };

  const active = await priv('is-active opencode').catch((e) => `unreachable (${e.message})`);
  rows.containers = active === 'active'
    ? { value: 'OpenCode running', state: 'ok' }
    : { value: `OpenCode ${active}`, state: 'bad' };

  const fs = await statfs(`${ROOT}/state`).catch(() => null);
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

const adminHash = await loadHash();

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

    if (req.method === 'GET' && (path === '/' || path === '/index.html')) {
      return send(res, 200, await read(`${UI}/index.html`), { 'content-type': 'text/html; charset=utf-8' });
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
