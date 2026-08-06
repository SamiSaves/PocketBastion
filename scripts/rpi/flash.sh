#!/usr/bin/env bash
# Writes Fedora CoreOS + U-Boot to a microSD for a Raspberry Pi 4, preserving
# any existing GPT partition named `state` on the same card. The first flash
# creates no such partition — Ignition does that on first boot — and every flash
# after must leave it alone, which the check at the end verifies.
#
# Usage: make rpi-flash DEVICE=/dev/sdX
# Requires: podman, sudo, jq, lsblk, sfdisk, rsync, envsubst, findmnt
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IGNITION_DIR="${REPO_ROOT}/config/ignition"
IMAGES_DIR="${REPO_ROOT}/images"

INSTALLER_IMAGE="quay.io/coreos/coreos-installer:release"

STREAM="stable"
ARCH="aarch64"
STREAM_URL="https://builds.coreos.fedoraproject.org/streams/${STREAM}.json"

# Must match the `state` partition label in config/butane/rpi.bu.
STATE_PARTLABEL="state"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

DEVICE="${1:-${DEVICE:-}}"
if [[ -z "$DEVICE" ]]; then
  echo "Usage: $0 /dev/sdX     (or: make rpi-flash DEVICE=/dev/sdX)" >&2
  echo >&2
  echo "Removable block devices currently attached:" >&2
  lsblk -dno NAME,SIZE,TYPE,RM,MODEL 2>/dev/null | awk '$4==1 {print "  /dev/"$0}' >&2 || true
  exit 1
fi

for tool in podman sudo jq lsblk sfdisk rsync envsubst findmnt; do
  command -v "$tool" >/dev/null 2>&1 || err "'$tool' not found. Install it and retry."
done

# ── Safety gates ─────────────────────────────────────────────────────────────

[[ -b "$DEVICE" ]] || err "$DEVICE is not a block device."

devtype="$(lsblk -dno TYPE "$DEVICE" 2>/dev/null || true)"
[[ "$devtype" == "disk" ]] \
  || err "$DEVICE is type '${devtype:-unknown}', not a whole disk. Pass the disk (/dev/sdb), not a partition (/dev/sdb1)."

# `lsblk -no PKNAME` returns empty for LVM-on-LUKS roots, silently disabling the
# guard on common desktop installs. `lsblk -s` walks lvm -> crypt -> part -> disk.
backing_disks() {
  lsblk -nrso NAME,TYPE "$1" 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}'
}

for critical_mnt in / /boot /boot/efi /home; do
  src="$(findmnt -no SOURCE "$critical_mnt" 2>/dev/null | sed 's/\[.*\]$//' || true)"
  [[ -n "$src" ]] || continue
  while IFS= read -r d; do
    if [[ "$d" == "$DEVICE" ]]; then
      err "$DEVICE backs this machine's '${critical_mnt}' filesystem. Refusing."
    fi
  done < <(backing_disks "$src")
done

mounted="$(lsblk -nro MOUNTPOINT "$DEVICE" | grep -v '^$' || true)"
if [[ -n "$mounted" ]]; then
  echo "$DEVICE has mounted partitions:" >&2
  while IFS= read -r m; do echo "  $m" >&2; done <<<"$mounted"
  err "Unmount them first."
fi

devname="$(basename "$DEVICE")"
if [[ -r "/sys/block/${devname}/removable" ]] \
   && [[ "$(cat "/sys/block/${devname}/removable")" != "1" ]]; then
  warn "$DEVICE is not reported as removable. Double-check this is your SD card."
fi

echo
echo "About to ERASE and reflash this device:"
echo
lsblk -o NAME,SIZE,TYPE,PARTLABEL,LABEL,FSTYPE,MOUNTPOINT,MODEL "$DEVICE"
echo
echo "The GPT partition named '${STATE_PARTLABEL}' (if present) will be PRESERVED."
echo "Everything else on the device will be destroyed."
echo
read -r -p "Type the device path (${DEVICE}) to confirm: " CONFIRM < /dev/tty
[[ "$CONFIRM" == "$DEVICE" ]] || err "Aborted."

read_state_start() {
  sudo sfdisk --json "$1" 2>/dev/null \
    | jq -r --arg L "$STATE_PARTLABEL" \
        '(.partitiontable.partitions // [])[] | select(.name == $L) | .start' \
    | head -n1
}

PRE_STATE_START="$(read_state_start "$DEVICE" || true)"
if [[ -n "$PRE_STATE_START" ]]; then
  info "Found existing '${STATE_PARTLABEL}' partition at sector ${PRE_STATE_START} — it will be preserved."
else
  info "No existing '${STATE_PARTLABEL}' partition (first flash). Ignition will create it on first boot."
fi

# ── Render Ignition ──────────────────────────────────────────────────────────
# Rendered here rather than reused, so every reflash re-validates deploy.env
# before anything is written.

IGN="${IGNITION_DIR}/rpi.ign"
"${REPO_ROOT}/scripts/render-ignition.sh" rpi

# ── Preflight: is the device big enough? ─────────────────────────────────────
# A too-small card flashes fine and then fails inside Ignition's disks stage, in
# the initramfs, before networking — which on a Pi looks like nothing at all.
# root comes from the rendered Ignition so it cannot drift from rpi.bu; the
# 3 GiB covers FCOS's pre-root partitions plus a usable minimum for state.
ROOT_SIZE_MIB="$(jq -r '.storage.disks[0].partitions[]? | select(.label=="root") | .sizeMiB // empty' "$IGN" | head -n1)"
[[ -n "$ROOT_SIZE_MIB" ]] || err "Could not read the root partition size out of ${IGN}."

DEV_MIB=$(( $(cat "/sys/block/${devname}/size" 2>/dev/null || echo 0) / 2048 ))
REQUIRED_MIB=$(( ROOT_SIZE_MIB + 3072 ))
(( DEV_MIB >= REQUIRED_MIB )) \
  || err "$DEVICE is too small: ${DEV_MIB} MiB, need at least ${REQUIRED_MIB} MiB (root ${ROOT_SIZE_MIB} MiB + state)."
info "Device size OK: ${DEV_MIB} MiB available, ${REQUIRED_MIB} MiB required."

# ── Fetch the FCOS image ─────────────────────────────────────────────────────

info "Resolving FCOS ${STREAM}/${ARCH} metal image..."
STREAM_JSON="$(curl -fsSL "$STREAM_URL")" || err "Could not fetch $STREAM_URL"

FCOS_RELEASE="$(jq -r '.architectures.'"$ARCH"'.artifacts.metal.release' <<<"$STREAM_JSON")"
IMAGE_URL="$(jq -r '.architectures.'"$ARCH"'.artifacts.metal.formats["raw.xz"].disk.location' <<<"$STREAM_JSON")"
[[ -n "$FCOS_RELEASE" && "$FCOS_RELEASE" != "null" ]] || err "Could not resolve FCOS release from stream metadata."
[[ -n "$IMAGE_URL" && "$IMAGE_URL" != "null" ]] || err "Could not resolve image URL from stream metadata."

IMAGE_FILE="${IMAGES_DIR}/$(basename "$IMAGE_URL")"
mkdir -p "$IMAGES_DIR"

if [[ -f "$IMAGE_FILE" && -f "${IMAGE_FILE}.sig" ]]; then
  info "Using cached image: $(basename "$IMAGE_FILE")"
else
  info "Downloading FCOS ${FCOS_RELEASE} (~1 GB, cached for next time)..."
  podman run --rm -v "${IMAGES_DIR}":/images:z "$INSTALLER_IMAGE" \
    download -s "$STREAM" -a "$ARCH" -p metal -f raw.xz -C /images --fetch-retries 3
  [[ -f "$IMAGE_FILE" ]] || err "Download finished but $IMAGE_FILE is missing."
fi

# ── Install, preserving the state partition ──────────────────────────────────

info "Installing FCOS ${FCOS_RELEASE} to ${DEVICE} (preserving partlabel '${STATE_PARTLABEL}')..."
# -v /run/udev:/run/udev is required: coreos-installer re-reads the partition
# table via udev and aborts with "udevd socket missing" without it.
sudo podman run --rm --privileged \
  -v /dev:/dev \
  -v /run/udev:/run/udev \
  -v "${IMAGES_DIR}":/images:ro \
  -v "${IGNITION_DIR}":/ign:ro \
  "$INSTALLER_IMAGE" \
  install \
    --architecture "$ARCH" \
    --image-file "/images/$(basename "$IMAGE_FILE")" \
    --ignition-file "/ign/$(basename "$IGN")" \
    --save-partlabel "$STATE_PARTLABEL" \
    "$DEVICE"

sudo udevadm settle || true
sudo partprobe "$DEVICE" 2>/dev/null || true
sudo udevadm settle || true

# The GPT still describes a ~2.8 GiB disk (the image's size), not the card. Do
# NOT fix that with `sgdisk -e` here: FCOS relocates the secondary header itself
# in the initramfs, and only while the disk GUID is still the uninitialized one
# the image ships with. Randomizing it here would suppress that.

# ── Plant U-Boot + Raspberry Pi firmware on the ESP ──────────────────────────
# A Pi has no UEFI. Fedora's uboot-images-armv8 + bcm283x-firmware RPMs provide
# U-Boot and a ready-made config.txt, so we author no firmware config ourselves.

FEDORA_RELEASE="${FCOS_RELEASE%%.*}"
UBOOT_DIR="${IMAGES_DIR}/rpi-uboot-f${FEDORA_RELEASE}"

if [[ -f "${UBOOT_DIR}/boot/efi/rpi-u-boot.bin" ]]; then
  info "Using cached Raspberry Pi firmware for Fedora ${FEDORA_RELEASE}"
else
  info "Fetching U-Boot + Pi firmware from Fedora ${FEDORA_RELEASE} (aarch64)..."
  rm -rf "$UBOOT_DIR"
  mkdir -p "$UBOOT_DIR"
  podman run --rm -v "${UBOOT_DIR}":/out:z \
    "registry.fedoraproject.org/fedora:${FEDORA_RELEASE}" \
    bash -euo pipefail -c '
      dnf -q install -y cpio >/dev/null 2>&1
      dnf download --resolve --releasever='"${FEDORA_RELEASE}"' --forcearch=aarch64 \
        --destdir=/tmp/rpm uboot-images-armv8 bcm283x-firmware bcm283x-overlays
      cd /out
      for r in /tmp/rpm/*.rpm; do rpm2cpio "$r" | cpio -idmu --quiet; done
      # U-Boot ships as u-boot.bin; the Fedora config.txt expects rpi-u-boot.bin.
      mv usr/share/uboot/rpi_arm64/u-boot.bin boot/efi/rpi-u-boot.bin
    '
  [[ -f "${UBOOT_DIR}/boot/efi/rpi-u-boot.bin" ]] || err "U-Boot extraction failed."
  [[ -f "${UBOOT_DIR}/boot/efi/config.txt" ]]     || err "config.txt missing from Fedora firmware RPMs."
fi

info "Locating the FCOS EFI system partition..."
ESP="$(lsblk -J -o LABEL,PATH "$DEVICE" \
        | jq -r '[.blockdevices[] | recurse(.children[]?) | select(.label == "EFI-SYSTEM") | .path] | first // empty')"
[[ -n "$ESP" ]] || err "Could not find an EFI-SYSTEM partition on ${DEVICE}."
info "ESP is ${ESP}"

ESP_MNT="$(mktemp -d)"
cleanup() {
  if mountpoint -q "$ESP_MNT" 2>/dev/null; then sudo umount "$ESP_MNT" || true; fi
  rmdir "$ESP_MNT" 2>/dev/null || true
}
trap cleanup EXIT

sudo mount "$ESP" "$ESP_MNT"
info "Copying Raspberry Pi firmware onto the ESP..."
# The ESP is vfat, so `rsync -a` fails on chown. --ignore-existing so we never
# clobber the EFI files FCOS just wrote.
sudo rsync -rt --no-perms --no-owner --no-group --ignore-existing \
  "${UBOOT_DIR}/boot/efi/" "${ESP_MNT}/"
sudo sync

# Without these the Pi's ROM will not chain into U-Boot. Checked as root: vfat
# mount masks can hide files from an unprivileged read.
for required in config.txt rpi-u-boot.bin start4.elf fixup4.dat bcm2711-rpi-4-b.dtb; do
  sudo test -f "${ESP_MNT}/${required}" \
    || err "Firmware copy incomplete: ${required} is missing from the ESP."
done
sudo test -d "${ESP_MNT}/overlays" \
  || err "Firmware copy incomplete: overlays/ is missing from the ESP."
sudo grep -q '^kernel=rpi-u-boot.bin' "${ESP_MNT}/config.txt" \
  || err "config.txt on the ESP does not chainload rpi-u-boot.bin."
info "Firmware verified on ESP."

sudo umount "$ESP_MNT"
trap - EXIT
rmdir "$ESP_MNT" 2>/dev/null || true

sudo udevadm settle || true

echo
info "Resulting layout:"
lsblk -o NAME,SIZE,TYPE,PARTLABEL,LABEL,FSTYPE "$DEVICE"
echo

if [[ -n "$PRE_STATE_START" ]]; then
  POST_STATE_START="$(read_state_start "$DEVICE" || true)"
  [[ -n "$POST_STATE_START" ]] \
    || err "DATA LOSS: the '${STATE_PARTLABEL}' partition is GONE after flashing. Do not reboot the Pi; investigate."
  [[ "$POST_STATE_START" == "$PRE_STATE_START" ]] \
    || err "DATA LOSS RISK: '${STATE_PARTLABEL}' moved from sector ${PRE_STATE_START} to ${POST_STATE_START}."
  info "PASS: '${STATE_PARTLABEL}' preserved at sector ${POST_STATE_START}."
else
  info "No state partition to preserve on this pass. Ignition creates it on first boot."
fi

cat <<EOF

Done. FCOS ${FCOS_RELEASE} written to ${DEVICE}.

Put the card in the Pi, attach ethernet, power on. First boot takes 3-5 minutes,
then ssh core@pocketbastion-rpi. In lan mode OpenCode will not start until
OPENCODE_SERVER_PASSWORD is set — see docs/raspberry-pi.md.
EOF
