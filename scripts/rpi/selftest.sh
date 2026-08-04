#!/usr/bin/env bash
# Proves `make rpi-flash` preserves the state partition, using a 64 GiB sparse
# file instead of a real SD card:
#
#   flash #1            -> writes FCOS, no state partition yet
#   simulate first boot -> what FCOS does: move the secondary GPT header, pin
#                          root, create partition 5 `state`, write a canary
#   flash #2            -> must preserve partition 5 byte-for-byte
#   verify              -> canary intact, partition at the same sector
#
# test-render.sh asserts the other half: that rpi.bu omits size_mib for `state`,
# without which Ignition would reject the preserved partition on the next boot.
#
# Usage: make rpi-selftest
# Requires: sudo, losetup, sgdisk, mkfs.ext4, podman, jq
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLASH="${REPO_ROOT}/scripts/rpi/flash.sh"

IMG=/tmp/pocketbastion-rpi-selftest.img
IMG_SIZE=64G
IGN_FILE="${REPO_ROOT}/config/ignition/rpi.ign"
CANARY_TEXT="pocketbastion-canary-$(date +%s)"

# Read out of the rendered Ignition after flash #1, so this cannot drift from rpi.bu.
ROOT_SIZE_MIB=""

LOOP=""
MNT=""

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo; echo "### $*"; }

cleanup() {
  if [[ -n "$MNT" ]] && mountpoint -q "$MNT" 2>/dev/null; then sudo umount "$MNT" || true; fi
  if [[ -n "$MNT" ]]; then rmdir "$MNT" 2>/dev/null || true; fi
  if [[ -n "$LOOP" ]]; then sudo losetup -d "$LOOP" 2>/dev/null || true; fi
  rm -f "$IMG"
}
trap cleanup EXIT

for tool in sudo losetup sgdisk mkfs.ext4 podman jq; do
  command -v "$tool" >/dev/null 2>&1 || err "'$tool' not found."
done

# Read the device node out of sfdisk's JSON rather than assuming the array index
# matches the partition number.
state_dev() {
  sudo sfdisk --json "$LOOP" 2>/dev/null \
    | jq -r '(.partitiontable.partitions // [])[] | select(.name=="state") | .node' \
    | head -n1
}
state_start() {
  sudo sfdisk --json "$LOOP" 2>/dev/null \
    | jq -r '(.partitiontable.partitions // [])[] | select(.name=="state") | .start' \
    | head -n1
}
part_start() {
  sudo sfdisk --json "$LOOP" 2>/dev/null \
    | jq -r --arg n "$1" \
        '(.partitiontable.partitions // [])[] | select(.node | test("p?" + $n + "$")) | .start' \
    | head -n1
}

info "Creating ${IMG_SIZE} sparse image at ${IMG}"
rm -f "$IMG"
truncate -s "$IMG_SIZE" "$IMG"

LOOP="$(sudo losetup -fP --show "$IMG")"
info "Loop device: ${LOOP}"

info "FLASH #1 — fresh card, no state partition yet"
RPI_FLASH_ALLOW_LOOP=1 RPI_FLASH_ASSUME_YES=1 "$FLASH" "$LOOP"

sudo partprobe "$LOOP"; sudo udevadm settle
[[ -z "$(state_start)" ]] || err "Flash #1 unexpectedly produced a 'state' partition."
info "OK: FCOS written, no state partition (as expected)."

ROOT_SIZE_MIB="$(jq -r '.storage.disks[0].partitions[]? | select(.label=="root") | .sizeMiB // empty' "$IGN_FILE" | head -n1)"
[[ -n "$ROOT_SIZE_MIB" ]] || err "Could not read the root partition size out of ${IGN_FILE}."
info "Using ROOT_SIZE_MIB=${ROOT_SIZE_MIB} (read from the rendered Ignition)."

# The shipped image's GPT describes a ~2.8 GiB disk, so its secondary header is
# stranded mid-card and any partition past that fails to create. FCOS fixes this
# in the initramfs before Ignition runs; skipping it here would test something
# FCOS never does.
info "Simulating coreos-gpt-setup: moving secondary GPT header to end of disk"
sudo sgdisk --disk-guid=R --move-second-header "$LOOP" >/dev/null
sudo partprobe "$LOOP"; sudo udevadm settle

info "Simulating Ignition disks stage: pinning root to ${ROOT_SIZE_MIB} MiB, creating 'state'"
P4_START="$(part_start 4)"
[[ -n "$P4_START" ]] || err "Could not find partition 4 (root) after flash #1."

sudo sgdisk -d 4 "$LOOP" >/dev/null
sudo sgdisk -n "4:${P4_START}:+${ROOT_SIZE_MIB}M" -c 4:root -t 4:8305 "$LOOP" >/dev/null
sudo sgdisk -n "5:0:0" -c 5:state "$LOOP" >/dev/null
sudo partprobe "$LOOP"; sudo udevadm settle

STATE_DEV="$(state_dev)"
[[ -n "$STATE_DEV" ]] || err "Failed to create the 'state' partition."
[[ -b "$STATE_DEV" ]] || err "${STATE_DEV} did not appear as a block device."

sudo mkfs.ext4 -q -L state "$STATE_DEV"

MNT="$(mktemp -d)"
sudo mount "$STATE_DEV" "$MNT"
echo "$CANARY_TEXT" | sudo tee "${MNT}/canary.txt" >/dev/null
echo "boot 1" | sudo tee "${MNT}/boots.log" >/dev/null
sudo sync
sudo umount "$MNT"

STATE_START_BEFORE="$(state_start)"
info "OK: ${STATE_DEV} created at sector ${STATE_START_BEFORE}, canary written."

info "FLASH #2 — reflash; the state partition MUST survive"
RPI_FLASH_ALLOW_LOOP=1 RPI_FLASH_ASSUME_YES=1 "$FLASH" "$LOOP"

sudo partprobe "$LOOP"; sudo udevadm settle

STATE_START_AFTER="$(state_start)"
[[ -n "$STATE_START_AFTER" ]] || err "FAIL: the 'state' partition is gone after reflashing."
[[ "$STATE_START_AFTER" == "$STATE_START_BEFORE" ]] \
  || err "FAIL: 'state' moved from sector ${STATE_START_BEFORE} to ${STATE_START_AFTER}."

STATE_DEV="$(state_dev)"
[[ -b "$STATE_DEV" ]] || err "FAIL: ${STATE_DEV} is not a block device after reflashing."
sudo mount "$STATE_DEV" "$MNT"
GOT="$(sudo cat "${MNT}/canary.txt" 2>/dev/null || true)"
BOOTS="$(sudo cat "${MNT}/boots.log" 2>/dev/null || true)"
sudo umount "$MNT"

[[ "$GOT" == "$CANARY_TEXT" ]] \
  || err "FAIL: canary content changed. expected '${CANARY_TEXT}', got '${GOT}'."
[[ "$BOOTS" == "boot 1" ]] \
  || err "FAIL: boots.log changed. expected 'boot 1', got '${BOOTS}'."

cat <<EOF

PASS: state preserved at sector ${STATE_START_AFTER}, canary survived.
EOF
