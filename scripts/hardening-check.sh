#!/usr/bin/env bash
# hardening-check.sh — Runtime checks that the live VM matches the security model.
#
# Static checks live in validate.sh (shellcheck + butane render); this script
# talks to the running VM and asserts the phase-10 hardening properties.
#
# Usage:
#   make harden-check
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM_IP="$("${REPO_ROOT}/scripts/local/ip.sh")"

if [[ -z "$VM_IP" ]]; then
  echo "ERROR: Could not determine VM IP. Is the VM running?" >&2
  exit 1
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

OUT=""

# ── Host-side check: no secrets tracked by git ───────────────────────────────
if git -C "$REPO_ROOT" ls-files | grep -iqE '\.(private|key|pem)$|deploy_key|/secrets/'; then
  OUT+=$'FAIL: secrets tracked by git\n'
else
  OUT+=$'PASS: no secrets tracked by git\n'
fi

# ── VM-side checks (one SSH session) ─────────────────────────────────────────
OUT+="$(ssh "${SSH_OPTS[@]}" "core@${VM_IP}" 'bash -s' <<'REMOTE'
set -uo pipefail

# A service is "public" if it listens anywhere other than loopback or the
# WireGuard IP (10.44.0.1). Wildcard binds (0.0.0.0 / [::]) are the real risk.
check_not_public() {
  local port=$1 label=$2 bad
  bad=$(ss -Hltn "sport = :$port" 2>/dev/null \
    | awk '{print $4}' | sed 's/:[0-9]*$//' \
    | grep -vE '^(127\.0\.0\.1|\[::1\]|10\.44\.0\.1)$' || true)
  if [[ -z "$bad" ]]; then
    echo "PASS: port $port ($label) not listening on public interface"
  else
    echo "FAIL: port $port ($label) listening on: $(echo "$bad" | tr '\n' ' ')"
  fi
}

check_not_public 4096 OpenCode
check_not_public 5173 Vite

sshd_val() { sudo sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==k{print tolower($2)}'; }
[[ "$(sshd_val passwordauthentication)" == "no" ]] \
  && echo "PASS: SSH password auth disabled" \
  || echo "FAIL: SSH password auth enabled"
[[ "$(sshd_val permitrootlogin)" == "no" ]] \
  && echo "PASS: root SSH disabled" \
  || echo "FAIL: root SSH enabled"

if ip link show wg0 &>/dev/null && ss -Huln 2>/dev/null | grep -q ':51820'; then
  echo "PASS: WireGuard listening"
else
  echo "FAIL: WireGuard not listening (wg0 down or UDP 51820 closed)"
fi

if mountpoint -q /var/mnt/state; then
  echo "PASS: /mnt/state persists (separate mount)"
else
  echo "FAIL: /mnt/state is not a separate mount"
fi
REMOTE
)"$'\n'

# ── SSH over WireGuard (needs the tunnel up on THIS host) ─────────────────────
if ssh "${SSH_OPTS[@]}" -o BatchMode=yes core@10.44.0.1 true &>/dev/null; then
  OUT+=$'PASS: SSH works over WireGuard\n'
else
  OUT+=$'SKIP: SSH over WireGuard (bring the tunnel up on this host to test)\n'
fi

echo "$OUT"
if grep -q '^FAIL' <<<"$OUT"; then
  echo "RESULT: hardening checks FAILED." >&2
  exit 1
fi
echo "RESULT: all hardening checks passed."
