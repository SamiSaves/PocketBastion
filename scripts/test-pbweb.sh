#!/usr/bin/env bash
# test-pbweb.sh — exercise the admin UI server against a fixture tree, on the
# laptop, with no VM and no box.
#
# Covers what is logic rather than plumbing: the login gate (wrong password,
# rate limit, session cookie), that /api/status answers with the keys
# index.astro asks for, the password change (sessions invalidated, new password
# live), and that the pairing API relays the status file. Everything it cannot
# fake — the pb-priv socket, the status timer, SELinux labels, the Quadlet — is
# what the VM run is for.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/config/butane/files/etc/pocketbastion/pbweb.mjs"
UI_DIST="$ROOT/ui/dist"

command -v node >/dev/null || { echo "SKIP: node not installed"; exit 0; }
[[ -f "$UI_DIST/index.html" ]] || { echo "SKIP: ui/dist not built (make ui)"; exit 0; }

PB_ROOT="$(mktemp -d)"
PORT=18080
trap 'kill "${PID:-}" 2>/dev/null || true; rm -rf "$PB_ROOT"' EXIT

# ── fixture ──────────────────────────────────────────────────────────────────
PASSWORD='correct horse battery staple'
mkdir -p "$PB_ROOT/app/etc/ui" "$PB_ROOT/state/admin" "$PB_ROOT/run/pocketbastion"
cp "$UI_DIST"/*.html "$PB_ROOT/app/etc/ui/"

# shellcheck disable=SC2016  # single quotes on purpose: this is JS, not shell
printf '%s' "$PASSWORD" | node -e '
  const c = require("crypto");
  let pw = ""; process.stdin.on("data", d => (pw += d)).on("end", () => {
    const s = c.randomBytes(16);
    console.log(`scrypt:${s.toString("base64")}:${c.scryptSync(pw, s, 32).toString("base64")}`);
  });
' > "$PB_ROOT/app/etc/admin.hash"

cat > "$PB_ROOT/app/etc/firewall.env" <<'EOF'
TRUSTED_CIDRS="192.168.122.0/24"
ORCA_PORTS="6768 5173-5180"
ADMIN_PORT="8080"
EOF
# A status file as pb-status.sh would write it: GitHub unauthenticated (the
# warn the assertions check), one agent authed, a ready-line, one repo.
cat > "$PB_ROOT/run/pocketbastion/agent-status.json" <<'EOF'
{"github": null, "gitEmail": "you@example.com", "claude": true, "codex": false,
 "ready": {"type": "orca_server_ready", "webUrl": "http://192.0.2.1:6768",
           "pairing": "orca://pair?offer=fixture"},
 "devices": [{"name": "fixture phone", "created": "2026-08-01"}],
 "repos": [{"name": "demo", "kb": 2048}]}
EOF

# ── run ──────────────────────────────────────────────────────────────────────
PB_ROOT="$PB_ROOT" ADMIN_PORT="$PORT" node "$SERVER" >"$PB_ROOT/log" 2>&1 &
PID=$!
for _ in $(seq 50); do
  curl -fsS -o /dev/null "http://127.0.0.1:$PORT/login.html" 2>/dev/null && break
  sleep 0.1
done

fail=0
bad() { echo "FAIL: $*"; fail=1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
login() { curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/login" \
            -H 'content-type: application/json' --data "{\"password\":\"$1\"}" "${@:2}"; }

# The seed only happens once, and it is what the status page reports as "still
# the one from deploy.env".
[[ -s "$PB_ROOT/state/admin/admin.hash" ]] \
  || bad "the rendered hash was not seeded to the state copy"

# Unauthenticated: pages redirect so a bookmark lands somewhere useful, the API
# answers 401 so fetch() in index.astro can react.
[[ "$(code "http://127.0.0.1:$PORT/")" == 303 ]] \
  || bad "/ served the status page without a session"
[[ "$(code "http://127.0.0.1:$PORT/api/status")" == 401 ]] \
  || bad "/api/status answered without a session"
[[ "$(code "http://127.0.0.1:$PORT/login.html")" == 200 ]] \
  || bad "/login.html needs a session, so nobody could ever log in"

[[ "$(login 'wrong')" == 401 ]] || bad "a wrong password was accepted"

# Rate limit: 5 failures per minute, and the counter is global. Four more.
for _ in 1 2 3 4; do login 'wrong' >/dev/null; done
[[ "$(login 'wrong')" == 429 ]] || bad "the login rate limit did not trigger"
# ...and it must not lock out the real password forever — a correct login
# clears the window. Restart rather than wait 60s for it.
kill "$PID"; wait "$PID" 2>/dev/null || true
PB_ROOT="$PB_ROOT" ADMIN_PORT="$PORT" node "$SERVER" >>"$PB_ROOT/log" 2>&1 &
PID=$!
for _ in $(seq 50); do
  curl -fsS -o /dev/null "http://127.0.0.1:$PORT/login.html" 2>/dev/null && break
  sleep 0.1
done

JAR="$PB_ROOT/jar"
[[ "$(login "$PASSWORD" -c "$JAR")" == 200 ]] || bad "the correct password was rejected"
grep -q 'pb' "$JAR" || bad "no session cookie was set"

STATUS="$(curl -s -b "$JAR" "http://127.0.0.1:$PORT/api/status")"
# temperature is deliberately absent: the row exists only where the thermal
# zone does, and this laptop's reading is not the fixture's.
for key in networks ports adminPassword github agents gitIdentity repos memory load containers disk; do
  node -e 'process.exit(JSON.parse(process.argv[1])[process.argv[2]]?.value ? 0 : 1)' \
    "$STATUS" "$key" || bad "status row '$key' is missing or empty (index.astro renders it)"
done
# The seeded password and the unauthenticated GitHub credential are the two
# warnings the fixture is built to produce; if they read 'ok' the flags are not
# wired to anything. The repo row must carry the du result from the status file.
node -e 'const s=JSON.parse(process.argv[1]);
  if (s.adminPassword.state !== "warn") { console.error("adminPassword not flagged"); process.exit(1) }
  if (s.github.state !== "warn") { console.error("github not flagged"); process.exit(1) }
  if (!s.repos.value.includes("demo")) { console.error("repos ignores the status file"); process.exit(1) }' \
  "$STATUS" || bad "status flags are not derived from the fixture state"

# The pairing API relays the ready-line and device list from the status file.
PAIRING="$(curl -s -b "$JAR" "http://127.0.0.1:$PORT/api/pairing")"
node -e 'const p=JSON.parse(process.argv[1]);
  if (!p.ready?.pairing?.startsWith("orca://")) process.exit(1);
  if (p.devices?.[0]?.name !== "fixture phone") process.exit(1);' \
  "$PAIRING" || bad "/api/pairing does not relay the status file"

for page in "" pairing.html logs.html password.html; do
  [[ "$(code -b "$JAR" "http://127.0.0.1:$PORT/$page")" == 200 ]] \
    || bad "a logged-in GET /$page did not serve the page"
done

# Password change: wrong current refused, weak refused, then a real change —
# which must invalidate every session (the caller's too) and make the new
# password the one that logs in.
pwchange() { curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -X POST "http://127.0.0.1:$PORT/api/password" \
               -H 'content-type: application/json' --data "$1"; }
[[ "$(pwchange '{"current":"wrong","next":"longenough"}')" == 403 ]] \
  || bad "a password change with the wrong current password was accepted"
[[ "$(pwchange "{\"current\":\"$PASSWORD\",\"next\":\"short\"}")" == 400 ]] \
  || bad "a 5-character password was accepted"
NEW_PASSWORD='an entirely new passphrase'
[[ "$(pwchange "{\"current\":\"$PASSWORD\",\"next\":\"$NEW_PASSWORD\"}")" == 200 ]] \
  || bad "a valid password change was refused"
[[ "$(code -b "$JAR" "http://127.0.0.1:$PORT/api/status")" == 401 ]] \
  || bad "the caller's session survived the password change"
[[ "$(login "$PASSWORD")" == 401 ]] || bad "the old password still logs in"
[[ "$(login "$NEW_PASSWORD" -c "$JAR")" == 200 ]] || bad "the new password does not log in"
cmp -s "$PB_ROOT/app/etc/admin.hash" "$PB_ROOT/state/admin/admin.hash" \
  && bad "the changed password did not reach the state copy"

if [[ "$fail" -ne 0 ]]; then
  echo "--- server log ---"; cat "$PB_ROOT/log"
  echo "test-pbweb: assertions FAILED" >&2
  exit 1
fi
echo "test-pbweb: login gate and status API behave"
