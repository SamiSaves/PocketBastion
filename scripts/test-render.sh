#!/usr/bin/env bash
# Renders the config and asserts what the render is actually responsible for:
# that every expected file and unit is present, and that a missing TRUSTED_CIDRS
# is refused rather than rendered into a wide-open box. Butane --strict does the
# rest — a config that renders is structurally valid.
#
# Assertions are on file paths and unit names, which are plaintext in the
# Ignition JSON; file contents are data-URL encoded and not asserted on.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Scratch dir: these placeholder keys must never overwrite a real artifact.
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
export IGNITION_OUT_DIR="$OUT"

# render-ignition.sh reads DEPLOY_ENV, so every case is just a throwaway file.
cat > "$OUT/base.env" <<EOF
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAAtest render-validation-placeholder"
GIT_USER_NAME="render validation"
GIT_USER_EMAIL=render@validation
OPENCODE_EXTRA_PORTS="5173"
EOF

# render [VAR=val ...]
render() {
  local env_file="$OUT/case.env"
  cp "$OUT/base.env" "$env_file"
  printf '%s\n' "$@" >> "$env_file"
  DEPLOY_ENV="$env_file" bash "$ROOT/scripts/render-ignition.sh"
}

fail=0
bad() { echo "FAIL: $*"; fail=1; }

assert() { grep -q -- "$1" "$2" || bad "expected '$1' in $(basename "$2")"; }

IGN="$OUT/pocketbastion.ign"

render 'TRUSTED_CIDRS="192.168.1.0/24"' >/dev/null

assert "/usr/local/sbin/firewall-setup.sh"                      "$IGN"
assert "/usr/local/sbin/git-setup.sh"                           "$IGN"
assert "/etc/containers/systemd/users/1000/opencode.container"  "$IGN"
assert "/etc/containers/systemd/users/1000/opencode.build"      "$IGN"
assert "/etc/pocketbastion/Containerfile"                       "$IGN"
assert "/etc/pocketbastion/gitconfig"                           "$IGN"
assert "/etc/pocketbastion/firewall.env"                        "$IGN"
assert "state-dirs.service"                                     "$IGN"
assert "git-setup.service"                                      "$IGN"
assert "firewall.service"                                       "$IGN"
# Break-glass console password hash.
# shellcheck disable=SC2016
assert '\$6\$uxZJIlbecCN0'                                      "$IGN"

# Disk layout. Both the Pi and the mock VM boot this, so it is asserted once.
assert "coreos-boot-disk"   "$IGN"
assert "by-partlabel/state" "$IGN"
# The one disk-layout invariant that costs data if broken: an omitted sizeMiB
# makes Ignition adopt the existing partition. See docs/raspberry-pi.md.
jq -e '.storage.disks[0].partitions[] | select(.label=="state") | has("sizeMiB") | not' "$IGN" >/dev/null \
  || bad "state partition specifies sizeMiB; a reflash would abort in the initramfs"
# Root's size is what --save-partlabel pins `state` against across a reflash.
jq -e '.storage.disks[0].partitions[] | select(.label=="root") | .sizeMiB == 16384' "$IGN" >/dev/null \
  || bad "root is no longer 16384 MiB; a reflash would resize into the state partition"

# TRUSTED_CIDRS is the only access control this box has, so a render without it
# must fail rather than produce a config nothing filters.
render TRUSTED_CIDRS= >/dev/null 2>&1 \
  && bad "an empty TRUSTED_CIDRS rendered instead of being refused"
render 'TRUSTED_CIDRS="0.0.0.0/0"' >/dev/null 2>&1 \
  && bad "TRUSTED_CIDRS=0.0.0.0/0 rendered instead of being refused"

if [[ "$fail" -ne 0 ]]; then
  echo "test-render: assertions FAILED" >&2
  exit 1
fi
echo "test-render: config renders correctly"
