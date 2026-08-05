#!/usr/bin/env bash
# Renders every platform in every mode and asserts the result.
#
#   1. Regression guard on the layering: a shared block landing in only one
#      platform, or a WireGuard block surviving into lan mode, is caught here.
#   2. Proof that the fail-closed paths actually fail.
#
# Assertions are on file paths and unit names, which are plaintext in the
# Ignition JSON; file contents are data-URL encoded and decoded where needed.
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
note() { echo "  $*"; }
bad()  { echo "FAIL: $*"; fail=1; }

assert() { grep -q -- "$1" "$2" || bad "expected '$1' in $(basename "$2")"; }
refute() { grep -q -- "$1" "$2" && bad "'$1' must NOT be in $(basename "$2")"; return 0; }

# ign <file|unit|units> <ign> [name]
ign() {
  python3 - "$@" <<'PY'
import base64, gzip, json, sys, urllib.parse

mode, path = sys.argv[1], sys.argv[2]
doc = json.load(open(path))

if mode == "units":
    for u in doc.get("systemd", {}).get("units", []):
        print(u["name"])
    sys.exit(0)

name = sys.argv[3]

if mode == "unit":
    for u in doc.get("systemd", {}).get("units", []):
        if u["name"] == name:
            sys.stdout.write(u.get("contents", ""))
            sys.exit(0)
    sys.exit(1)

for f in doc["storage"]["files"]:
    if f["path"] != name:
        continue
    src = f.get("contents", {}).get("source", "")
    if not src:
        sys.exit(0)
    raw = urllib.parse.unquote_to_bytes(src.split(",", 1)[1])
    if f["contents"].get("compression") == "gzip":
        raw = gzip.decompress(base64.b64decode(raw))
    sys.stdout.write(raw.decode())
    sys.exit(0)
sys.exit(1)
PY
}

assert_contents() {  # <ign> <path> <needle>
  local got
  got="$(ign file "$1" "$2")" || { bad "$2 missing from $(basename "$1")"; return 0; }
  grep -qF -- "$3" <<<"$got" || bad "$2 in $(basename "$1") should contain '$3', got: $(tr '\n' '|' <<<"$got")"
}
refute_contents() {
  local got
  got="$(ign file "$1" "$2")" || return 0
  grep -qF -- "$3" <<<"$got" && bad "$2 in $(basename "$1") must NOT contain '$3'"
  return 0
}
assert_unit() { ign units "$1" | grep -qx -- "$2" || bad "unit '$2' missing from $(basename "$1")"; }
refute_unit() { ign units "$1" | grep -qx -- "$2" && bad "unit '$2' must NOT be in $(basename "$1")"; return 0; }

# expect_refusal <description> <target> VAR=val ...
expect_refusal() {
  local desc="$1" target="$2"; shift 2
  if render "$target" "$@" >/dev/null 2>&1; then
    bad "$desc — render SUCCEEDED but should have been refused"
  else
    note "refused as expected: $desc"
  fi
}

echo "== wireguard mode: local + digitalocean + rpi"
render all NETWORK_MODE=wireguard >/dev/null

LOCAL="$OUT/local.ign"
DO="$OUT/digitalocean.ign"
RPI="$OUT/rpi.ign"

for ign_file in "$LOCAL" "$DO" "$RPI"; do
  assert "/usr/local/sbin/firewall-setup.sh"                      "$ign_file"
  assert "/usr/local/sbin/git-setup.sh"                           "$ign_file"
  assert "/usr/local/sbin/opencode-password-check.sh"             "$ign_file"
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

  assert "/usr/local/sbin/wg-setup.sh"                            "$ign_file"
  assert "/etc/wireguard/bootstrap-peer.conf"                     "$ign_file"
  assert_unit "$ign_file" "wg-quick@wg0.service"
  assert_unit "$ign_file" "wg-setup.service"

  assert_contents "$ign_file" /etc/containers/systemd/users/1000/opencode.container.d/10-render.conf \
    "PublishPort=10.44.0.1:4096:4096"
  assert_contents "$ign_file" /etc/pocketbastion/firewall.env "NETWORK_MODE=wireguard"
  refute_contents "$ign_file" /etc/containers/systemd/users/1000/opencode.container.d/20-lan-guard.conf \
    "opencode-password-check.sh"
  refute_contents "$ign_file" /etc/containers/systemd/users/1000/opencode.container "PublishPort="
done

# wg-setup.sh creates /mnt/state/wireguard itself, and the dir must not appear on
# a box with no WireGuard at all.
ign unit "$DO" state-dirs.service | grep '^ExecStart' | grep -q '/mnt/state/wireguard' \
  && bad "state-dirs.service still creates /mnt/state/wireguard"

# base.bu must not reference units that only exist in the WireGuard feature.
ign unit "$DO" firewall.service | grep -E '^(After|Before|Requires|Wants)=' | grep -q 'wg-' \
  && bad "firewall.service is ordered against a WireGuard unit that lan mode does not have"

assert "/etc/containers/systemd/users/1000/hello.container" "$LOCAL"
assert "format-state-disk.service"                          "$LOCAL"
assert "What=/dev/vdb"                                      "$LOCAL"
refute "by-label/state"                                     "$LOCAL"

assert "What=/dev/disk/by-label/state" "$DO"
refute "hello.container"               "$DO"
refute "format-state-disk.service"     "$DO"
refute "What=/dev/vdb"                 "$DO"

assert "coreos-boot-disk"          "$RPI"
assert "by-partlabel/state"        "$RPI"
refute "hello.container"           "$RPI"
# The one disk-layout invariant that costs data if broken: an omitted sizeMiB
# makes Ignition adopt the existing partition. See docs/raspberry-pi.md.
python3 -c 'import json,sys; p=[x for x in json.load(open(sys.argv[1]))["storage"]["disks"][0]["partitions"] if x.get("label")=="state"][0]; sys.exit("sizeMiB" in p)' "$RPI" \
  || bad "rpi state partition specifies sizeMiB; a reflash would abort in the initramfs"

echo "== lan mode: rpi"
render rpi NETWORK_MODE=lan \
  'TRUSTED_CIDRS="192.168.1.0/24 10.9.0.0/16"' >/dev/null

refute "/usr/local/sbin/wg-setup.sh"        "$RPI"
refute "/etc/wireguard/bootstrap-peer.conf" "$RPI"
refute_unit "$RPI" "wg-quick@wg0.service"
refute_unit "$RPI" "wg-setup.service"
refute "10.44.0.1"                          "$RPI"

assert_contents "$RPI" /etc/containers/systemd/users/1000/opencode.container.d/10-render.conf \
  "PublishPort=0.0.0.0:4096:4096"
assert_contents "$RPI" /etc/containers/systemd/users/1000/opencode.container.d/10-render.conf \
  "PublishPort=0.0.0.0:5173:5173"
assert_contents "$RPI" /etc/pocketbastion/firewall.env "NETWORK_MODE=lan"
assert_contents "$RPI" /etc/pocketbastion/firewall.env 'TRUSTED_CIDRS="192.168.1.0/24 10.9.0.0/16"'
# The firewall must open exactly the ports that are published, no more.
assert_contents "$RPI" /etc/pocketbastion/firewall.env 'OPENCODE_PORTS="4096 5173"'
assert_contents "$RPI" /etc/containers/systemd/users/1000/opencode.container.d/20-lan-guard.conf \
  "ExecStartPre=/usr/local/sbin/opencode-password-check.sh"

echo "== fail-closed paths"
expect_refusal "lan mode with no TRUSTED_CIDRS" rpi \
  NETWORK_MODE=lan TRUSTED_CIDRS=

expect_refusal "lan mode trusting the whole internet" rpi \
  NETWORK_MODE=lan TRUSTED_CIDRS=0.0.0.0/0

# Services bind 0.0.0.0, so a v6 rule would open ports nothing listens on.
expect_refusal "lan mode with an IPv6 CIDR" rpi \
  NETWORK_MODE=lan 'TRUSTED_CIDRS="fd00::/8"'

expect_refusal "lan mode on a public droplet" "do" \
  NETWORK_MODE=lan 'TRUSTED_CIDRS="192.168.1.0/24"'

if [[ "$fail" -ne 0 ]]; then
  echo "test-render: assertions FAILED" >&2
  exit 1
fi
echo "test-render: all platforms and modes render correctly"
