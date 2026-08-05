#!/usr/bin/env bash
# Runtime checks that the live box matches the security model. Static checks
# live in validate.sh. What is asserted depends on NETWORK_MODE, which is read
# from the box rather than deploy.env — deploy.env may have moved on since the
# last render.
#
# Usage:
#   make harden-check
#   SERVER_HOST=192.168.1.42 make harden-check
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/server-host.sh"
VM_IP="$(server_host)"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

OUT=""

if git -C "$REPO_ROOT" ls-files | grep -iqE '\.(private|key|pem)$|deploy_key|/secrets/'; then
  OUT+=$'FAIL: secrets tracked by git\n'
else
  OUT+=$'PASS: no secrets tracked by git\n'
fi

OUT+="$(ssh "${SSH_OPTS[@]}" "core@${VM_IP}" 'bash -s' <<'REMOTE'
set -uo pipefail

NETWORK_MODE=wireguard
TRUSTED_CIDRS=""
OPENCODE_PORTS=4096
if [[ -r /etc/pocketbastion/firewall.env ]]; then
  # shellcheck source=/dev/null
  . /etc/pocketbastion/firewall.env
fi
echo "INFO: NETWORK_MODE=${NETWORK_MODE}"

ruleset="$(sudo nft list table inet pocketbastion 2>/dev/null)"
if [[ -z "$ruleset" ]]; then
  echo "FAIL: nftables table 'inet pocketbastion' is missing (firewall.service failed?)"
elif grep -qE 'type filter hook input .*policy drop' <<<"$ruleset"; then
  echo "PASS: firewall input chain defaults to drop"
else
  echo "FAIL: firewall input chain does not default to drop"
fi

sshd_val() { sudo sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==k{print tolower($2)}'; }
[[ "$(sshd_val passwordauthentication)" == "no" ]] \
  && echo "PASS: SSH password auth disabled" \
  || echo "FAIL: SSH password auth enabled"
[[ "$(sshd_val permitrootlogin)" == "no" ]] \
  && echo "PASS: root SSH disabled" \
  || echo "FAIL: root SSH disabled expected, got '$(sshd_val permitrootlogin)'"

if mountpoint -q /var/mnt/state; then
  echo "PASS: /mnt/state persists (separate mount)"
else
  echo "FAIL: /mnt/state is not a separate mount"
fi

# Quadlet is a systemd generator: an ignored PublishPort dropin yields a unit
# missing that flag, silently. This is where that shows up.
for port in $OPENCODE_PORTS; do
  [[ "$port" == *-* ]] && continue   # ss cannot match a range
  binds=$(ss -Hltn "sport = :$port" 2>/dev/null | awk '{print $4}' | sed 's/:[0-9]*$//')
  if [[ -z "$binds" ]]; then
    echo "FAIL: port $port is not listening (was the PublishPort dropin applied?)"
    continue
  fi
  echo "PASS: port $port is listening"
  [[ "$NETWORK_MODE" == wireguard ]] || continue
  bad=$(grep -vE '^(127\.0\.0\.1|\[::1\]|10\.44\.0\.1)$' <<<"$binds" || true)
  if [[ -z "$bad" ]]; then
    echo "PASS: port $port not listening on public interface"
  else
    echo "FAIL: port $port listening on: $(tr '\n' ' ' <<<"$bad")"
  fi
done

case "$NETWORK_MODE" in
wireguard)
  if ip link show wg0 &>/dev/null && ss -Huln 2>/dev/null | grep -q ':51820'; then
    echo "PASS: WireGuard listening"
  else
    echo "FAIL: WireGuard not listening (wg0 down or UDP 51820 closed)"
  fi

  if grep -q 'iifname "wg0" accept' <<<"$ruleset"; then
    echo "PASS: only wg0 traffic is accepted past the firewall"
  else
    echo "FAIL: firewall does not restrict access to the wg0 interface"
  fi
  ;;

lan)
  if [[ -z "${TRUSTED_CIDRS// /}" ]]; then
    echo "FAIL: lan mode with an empty TRUSTED_CIDRS (firewall is in lockdown)"
  else
    ok=1
    for cidr in $TRUSTED_CIDRS; do
      grep -qF "$cidr" <<<"$ruleset" || { echo "FAIL: trusted network $cidr is not in the ruleset"; ok=0; }
    done
    [[ $ok -eq 1 ]] && echo "PASS: firewall restricts access to TRUSTED_CIDRS (${TRUSTED_CIDRS})"
  fi

  # An accept rule with no source restriction would defeat the whole model.
  if grep -E '^\s+(tcp|udp) dport' <<<"$ruleset" | grep -qv 'saddr'; then
    echo "FAIL: firewall has a port accept rule with no source restriction"
  else
    echo "PASS: every port accept rule is source-restricted"
  fi

  if ip link show wg0 &>/dev/null; then
    echo "FAIL: wg0 exists in lan mode (stale config from a previous render?)"
  else
    echo "PASS: no WireGuard interface (as expected in lan mode)"
  fi

  if /usr/local/sbin/opencode-password-check.sh >/dev/null 2>&1; then
    echo "PASS: OpenCode server password is set"
  else
    echo "FAIL: OPENCODE_SERVER_PASSWORD is unset, empty or too short"
  fi
  ;;
esac
REMOTE
)"$'\n'

echo "$OUT"
if grep -q '^FAIL' <<<"$OUT"; then
  echo "RESULT: hardening checks FAILED." >&2
  exit 1
fi
echo "RESULT: all hardening checks passed."
