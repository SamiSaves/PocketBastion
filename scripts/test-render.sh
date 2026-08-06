#!/usr/bin/env bash
# Renders every platform and asserts the layering: a shared block landing in
# only one platform, or a WireGuard block surviving into lan mode, is caught
# here. Butane --strict does the rest — a config that renders at all is
# structurally valid.
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

fail=0
bad() { echo "FAIL: $*"; fail=1; }

assert() { grep -q -- "$1" "$2" || bad "expected '$1' in $(basename "$2")"; }
refute() { grep -q -- "$1" "$2" && bad "'$1' must NOT be in $(basename "$2")"; return 0; }

echo "== wireguard mode: local + digitalocean + rpi"
for target in local digitalocean rpi; do
  render "$target" NETWORK_MODE=wireguard >/dev/null
done

LOCAL="$OUT/local.ign"
DO="$OUT/digitalocean.ign"
RPI="$OUT/rpi.ign"

for ign_file in "$LOCAL" "$DO" "$RPI"; do
  assert "/usr/local/sbin/firewall-setup.sh"                      "$ign_file"
  assert "/usr/local/sbin/git-setup.sh"                           "$ign_file"
  assert "/etc/containers/systemd/users/1000/opencode.container"  "$ign_file"
  assert "/etc/containers/systemd/users/1000/opencode.build"      "$ign_file"
  assert "/etc/pocketbastion/Containerfile"                       "$ign_file"
  assert "/etc/pocketbastion/gitconfig"                           "$ign_file"
  assert "/etc/pocketbastion/firewall.env"                        "$ign_file"
  assert "state-dirs.service"                                     "$ign_file"
  assert "git-setup.service"                                      "$ign_file"
  assert "firewall.service"                                       "$ign_file"
  # Break-glass console password hash.
  # shellcheck disable=SC2016
  assert '\$6\$uxZJIlbecCN0'                                      "$ign_file"

  # The WireGuard feature layer.
  assert "/usr/local/sbin/wg-setup.sh"                            "$ign_file"
  assert "/etc/wireguard/bootstrap-peer.conf"                     "$ign_file"
  assert "wg-quick@wg0.service"                                   "$ign_file"
  assert "wg-setup.service"                                       "$ign_file"
done

assert "/etc/containers/systemd/users/1000/hello.container" "$LOCAL"
assert "What=/dev/vdb"                                      "$LOCAL"
refute "by-label/state"                                     "$LOCAL"

assert "What=/dev/disk/by-label/state" "$DO"
refute "hello.container"               "$DO"
refute "What=/dev/vdb"                 "$DO"

assert "coreos-boot-disk"          "$RPI"
assert "by-partlabel/state"        "$RPI"
refute "hello.container"           "$RPI"
# The one disk-layout invariant that costs data if broken: an omitted sizeMiB
# makes Ignition adopt the existing partition. See docs/raspberry-pi.md.
python3 -c 'import json,sys; p=[x for x in json.load(open(sys.argv[1]))["storage"]["disks"][0]["partitions"] if x.get("label")=="state"][0]; sys.exit("sizeMiB" in p)' "$RPI" \
  || bad "rpi state partition specifies sizeMiB; a reflash would abort in the initramfs"

echo "== lan mode: rpi ships no WireGuard at all"
render rpi NETWORK_MODE=lan 'TRUSTED_CIDRS="192.168.1.0/24"' >/dev/null

refute "/usr/local/sbin/wg-setup.sh"        "$RPI"
refute "/etc/wireguard/bootstrap-peer.conf" "$RPI"
refute "wg-quick@wg0.service"               "$RPI"
refute "wg-setup.service"                   "$RPI"
refute "10.44.0.1"                          "$RPI"

if [[ "$fail" -ne 0 ]]; then
  echo "test-render: assertions FAILED" >&2
  exit 1
fi
echo "test-render: all platforms and modes render correctly"
