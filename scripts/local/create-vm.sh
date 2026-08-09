#!/usr/bin/env bash
# create-vm.sh — build the local KVM mock of the Raspberry Pi.
#
# The mock is not a lookalike: it boots the SAME Ignition config, written by the
# SAME scripts/rpi/flash.sh, onto a disk image partitioned the same way. Only
# the architecture and the U-Boot/EEPROM boot path differ, because those cannot
# be reproduced off the hardware.
#
#   disk image  --> losetup    (a real block device, so flash.sh works unchanged)
#               --> flash.sh   (coreos-installer + --save-partlabel state)
#               --> virt-install --import
#
# Re-running this is a REFLASH, exactly as on the Pi: the OS is replaced and
# /mnt/state is preserved, and flash.sh verifies the state partition did not
# move. Use it to try a deploy.env or Butane change before committing a card.
#
#   make local-up                       # create/reflash and boot
#   VM_DISK_GB=32 make local-up         # smaller image (first run only)
#   RAM_MB=2048 VCPUS=2 make local-up   # trim if the host is small
set -euo pipefail

VM_NAME="pocketbastion-local"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Lives where libvirt already has permission and the right SELinux/AppArmor
# labels. Sparse, so VM_DISK_GB costs only what the guest actually writes.
DISK="${VM_DISK:-/var/lib/libvirt/images/${VM_NAME}.raw}"
# Root is pinned at 16 GiB by the Butane config and state takes the rest, so
# anything under ~24 GB leaves too little state to be a useful devbox.
VM_DISK_GB="${VM_DISK_GB:-64}"
# The Pi this mocks is a 4 GB board. Match it, so memory limits are tested too.
RAM_MB="${RAM_MB:-4096}"
VCPUS="${VCPUS:-2}"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

for tool in virsh virt-install losetup; do
  command -v "$tool" >/dev/null 2>&1 || err "'$tool' not found. Install it and retry."
done

(( VM_DISK_GB >= 24 )) || err "VM_DISK_GB=${VM_DISK_GB} is too small; root alone is 16 GiB. Use 24 or more."

# ── The VM must be gone before its disk is rewritten underneath it ────────────

if virsh --connect qemu:///system dominfo "$VM_NAME" &>/dev/null; then
  info "Removing the existing VM definition (its disk image is kept)."
  virsh --connect qemu:///system destroy "$VM_NAME" &>/dev/null || true
  virsh --connect qemu:///system undefine "$VM_NAME" &>/dev/null || true
fi

# ── Disk image ───────────────────────────────────────────────────────────────

if [[ -f "$DISK" ]]; then
  info "Reusing disk image ${DISK} — this is a reflash, /mnt/state is preserved."
else
  info "Allocating a sparse ${VM_DISK_GB}GB disk image at ${DISK} (first flash)."
  sudo install -d -m 0711 "$(dirname "$DISK")"
  sudo truncate -s "${VM_DISK_GB}G" "$DISK"
fi

# ── Flash it exactly as the Pi is flashed ────────────────────────────────────

LOOP="$(sudo losetup --find --show --partscan "$DISK")" \
  || err "Could not attach ${DISK} to a loop device."
info "Attached ${DISK} as ${LOOP}"
# shellcheck disable=SC2064  # LOOP must be expanded now, not at trap time
trap "sudo losetup --detach '$LOOP' 2>/dev/null || true" EXIT

# ARCH: the host's, not the Pi's. CONSOLE: FCOS metal defaults to the graphical
# console, and without this `make local-console` would show nothing — and
# watching a failed boot is what the mock is for.
# FLASH_YES: safe here and nowhere else; this script allocated the target.
ARCH="$(uname -m)" CONSOLE="ttyS0,115200n8" FLASH_YES=1 \
  "${REPO_ROOT}/scripts/rpi/flash.sh" "$LOOP"

sudo losetup --detach "$LOOP"
trap - EXIT

# ── Boot ─────────────────────────────────────────────────────────────────────
# No --sysinfo/fwcfg Ignition injection: coreos-installer already embedded the
# config in the disk, the same way the Pi gets it.

info "Creating VM ${VM_NAME} (${RAM_MB}MB RAM, ${VCPUS} vCPU)"
virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --ram "$RAM_MB" \
  --vcpus "$VCPUS" \
  --os-variant fedora-coreos-stable \
  --machine q35 \
  --import \
  --disk "path=${DISK},format=raw,bus=virtio" \
  --network network=default \
  --console pty,target_type=serial \
  --noautoconsole \
  --wait 0

cat <<EOF

VM '${VM_NAME}' is booting. First boot takes 3-5 minutes: it creates the state
filesystem, grows root, then builds the OpenCode container image.

  make local-console   # watch it boot, no network needed
  make local-ip        # its address on the libvirt network
  make local-ssh       # ssh core@ its libvirt address
EOF
