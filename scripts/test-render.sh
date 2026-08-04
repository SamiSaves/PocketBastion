#!/usr/bin/env bash
# test-render.sh — render both environments and assert each got the right blocks.
# Regression guard: catches a shared block landing in only one environment.
# Assert on file paths + unit names (plaintext); file contents are data-URL encoded.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Scratch dir: these placeholder keys must never overwrite a real artifact.
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
export IGNITION_OUT_DIR="$OUT"

# render-ignition.sh reads DEPLOY_ENV, so every case is just a throwaway file.
cat > "$OUT/base.env" <<EOF
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAAtest render-validation-placeholder"
WG_BOOTSTRAP_PUBKEY=$(printf '0%.0s' {1..43})=
WG_BOOTSTRAP_IP=10.44.0.2
GIT_USER_NAME="render validation"
GIT_USER_EMAIL=render@validation
OPENCODE_EXTRA_PORTS="5173"
EOF

# render <target> [VAR=val ...]
render() {
  local target="$1"; shift
  local env_file="$OUT/case.env"
  cp "$OUT/base.env" "$env_file"
  printf '%s\n' "$@" >> "$env_file"
  DEPLOY_ENV="$env_file" bash "$ROOT/scripts/render-ignition.sh" "$target"
}

render all >/dev/null

LOCAL="$OUT/local.ign"
DO="$OUT/digitalocean.ign"

fail=0
assert() { grep -q -- "$1" "$2" || { echo "FAIL: expected '$1' in $(basename "$2")"; fail=1; }; }
refute() { if grep -q -- "$1" "$2"; then echo "FAIL: '$1' must NOT be in $(basename "$2")"; fail=1; fi; }

# Shared base must be present in BOTH environments.
for ign in "$LOCAL" "$DO"; do
  assert "/usr/local/sbin/wg-setup.sh"                            "$ign"
  assert "/usr/local/sbin/firewall-setup.sh"                      "$ign"
  assert "/etc/containers/systemd/users/1000/opencode.container"  "$ign"
  assert "/etc/containers/systemd/users/1000/opencode.build"      "$ign"
  assert "/etc/opencode/Containerfile"                            "$ign"
  assert "/etc/wireguard/bootstrap-peer.conf"                     "$ign"
  assert "wg-quick@wg0.service"                                   "$ign"
  assert "state-dirs.service"                                     "$ign"
  assert "/usr/local/sbin/git-setup.sh"                          "$ign"
  assert "git-setup.service"                                      "$ign"
  assert "/etc/opencode/gitconfig"                                "$ign"
  # Break-glass console login: default password hash baked into the core user.
  # shellcheck disable=SC2016
  assert '\$6\$uxZJIlbecCN0'                                     "$ign"
done

# Local-only: smoke-test container + /dev/vdb format-on-first-boot.
assert "/etc/containers/systemd/users/1000/hello.container" "$LOCAL"
assert "format-state-disk.service"                          "$LOCAL"
assert "What=/dev/vdb"                                       "$LOCAL"
refute "by-label/state"                                      "$LOCAL"

# DigitalOcean-only: state disk mounted by label, no format/hello smoke-test.
assert "What=/dev/disk/by-label/state" "$DO"
refute "hello.container"              "$DO"
refute "format-state-disk.service"   "$DO"
refute "What=/dev/vdb"               "$DO"

if [[ "$fail" -ne 0 ]]; then
  echo "test-render: assertions FAILED" >&2
  exit 1
fi
echo "test-render: local + digitalocean render correctly"
