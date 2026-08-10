#!/usr/bin/env bash
# Renders the config and asserts the two things the render is actually
# responsible for: the disk layout that costs a card's data if it drifts, and
# that a wide-open TRUSTED_CIDRS is refused rather than rendered. Butane
# --strict does the rest — a config that renders is structurally valid, so paths
# and unit names it copies verbatim from the .bu are not worth re-asserting here.
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
ORCA_EXTRA_PORTS="5173-5180"
ADMIN_PORT=8080
ADMIN_PASSWORD_HASH=scrypt:cmVuZGVyLXZhbGlkYXRpb24=:cmVuZGVyLXZhbGlkYXRpb24tcGxhY2Vob2xkZXI=
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

IGN="$OUT/pocketbastion.ign"

render 'TRUSTED_CIDRS="192.168.1.0/24"' >/dev/null

# Disk layout, asserted once: both the Pi and the mock VM boot this.
# The one invariant that costs data if broken: an omitted sizeMiB
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
render 'TRUSTED_CIDRS="0/0"' >/dev/null 2>&1 \
  && bad "TRUSTED_CIDRS=0/0 rendered instead of being refused"

# An ADMIN_PORT collision boots fine and silently loses the admin UI to a dev
# server, so it has to fail at render. The range form is the one that gets hit
# by accident — base.env publishes 5173-5180.
render 'TRUSTED_CIDRS="192.168.1.0/24"' ADMIN_PORT=5175 >/dev/null 2>&1 \
  && bad "ADMIN_PORT inside a published Orca range rendered instead of being refused"
render 'TRUSTED_CIDRS="192.168.1.0/24"' ADMIN_PORT=6768 >/dev/null 2>&1 \
  && bad "ADMIN_PORT=6768 (the Orca UI) rendered instead of being refused"
render 'TRUSTED_CIDRS="192.168.1.0/24"' ADMIN_PORT=22 >/dev/null 2>&1 \
  && bad "ADMIN_PORT=22 rendered instead of being refused"
render 'TRUSTED_CIDRS="192.168.1.0/24"' ADMIN_PASSWORD_HASH=REPLACE_ME >/dev/null 2>&1 \
  && bad "an unset ADMIN_PASSWORD_HASH rendered instead of being refused"

# ...and a valid one still renders, so the checks above are not just failing on
# everything. 8081 is outside 5173-5180.
render 'TRUSTED_CIDRS="192.168.1.0/24"' ADMIN_PORT=8081 >/dev/null 2>&1 \
  || bad "a valid ADMIN_PORT was refused"
render 'TRUSTED_CIDRS="192.168.1.0/24"' >/dev/null
# Butane emits inline files as a `data:,<url-encoded>` source, so match the
# encoded form rather than decoding.
jq -e '.storage.files[] | select(.path=="/etc/pocketbastion/firewall.env")
       | .contents.source | contains("ADMIN_PORT%3D%228080%22")' "$IGN" >/dev/null \
  || bad "ADMIN_PORT did not reach firewall.env; the admin port would be firewalled off"

if [[ "$fail" -ne 0 ]]; then
  echo "test-render: assertions FAILED" >&2
  exit 1
fi
echo "test-render: config renders correctly"
