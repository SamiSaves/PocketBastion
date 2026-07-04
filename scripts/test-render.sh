#!/usr/bin/env bash
# test-render.sh — render both environments from base.bu + overlay and assert
# each one got the right content.
#
# The merge itself (base.bu *+ overlay) is validated by `butane --strict` inside
# render-ignition.sh; these grep assertions are the regression guard that catches
# a shared block accidentally landing in only one environment (the exact bug that
# left DigitalOcean stale before the base/overlay split).
#
# Notes on what is greppable in the rendered Ignition JSON:
#   - storage file *paths* and systemd unit *names/contents* are plaintext
#   - storage file *contents* are data-URL encoded, so we assert on paths, not
#     on inline file bodies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Render without needing a real key on the machine (validation only).
export SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-ssh-ed25519 AAAAtest render-validation-placeholder}"
bash "$ROOT/scripts/render-ignition.sh" all >/dev/null

LOCAL="$ROOT/config/ignition/local.ign"
DO="$ROOT/config/ignition/digitalocean.ign"

fail=0
assert() { grep -q -- "$1" "$2" || { echo "FAIL: expected '$1' in $(basename "$2")"; fail=1; }; }
refute() { if grep -q -- "$1" "$2"; then echo "FAIL: '$1' must NOT be in $(basename "$2")"; fail=1; fi; }

# Shared base must be present in BOTH environments.
for ign in "$LOCAL" "$DO"; do
  assert "/usr/local/sbin/wg-setup.sh"                            "$ign"
  assert "/usr/local/sbin/firewall-setup.sh"                      "$ign"
  assert "/etc/containers/systemd/users/1000/opencode.container"  "$ign"
  assert "wg-quick@wg0.service"                                   "$ign"
  assert "state-dirs.service"                                     "$ign"
done

# Local-only: smoke-test container + /dev/vdb format-on-first-boot.
assert "/etc/containers/systemd/users/1000/hello.container" "$LOCAL"
assert "format-state-disk.service"                          "$LOCAL"
assert "What=/dev/vdb"                                       "$LOCAL"
refute "by-label/state"                                      "$LOCAL"

# DigitalOcean-only: sshd masked, state disk mounted by label, no format/hello.
assert "sshd.service"                 "$DO"
assert "What=/dev/disk/by-label/state" "$DO"
refute "hello.container"              "$DO"
refute "format-state-disk.service"   "$DO"
refute "What=/dev/vdb"               "$DO"

if [[ "$fail" -ne 0 ]]; then
  echo "test-render: assertions FAILED" >&2
  exit 1
fi
echo "test-render: local + digitalocean render correctly"
