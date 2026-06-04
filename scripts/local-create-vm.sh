#!/usr/bin/env bash
# local-create-vm.sh — create (or replace) the local KVM dev VM.
#
# Prerequisites (one-time host setup):
#   scripts/local-setup.sh       — run once after installing packages
#
# Base image must be placed at:
#   /var/lib/libvirt/images/fedora-coreos-44.qcow2
#
# Download from:
#   https://fedoraproject.org/coreos/download?stream=stable&arch=x86_64
#   Choose: Bare Metal & Virtualized → QEMU (qcow2.xz)
#   Then:  xz -d fedora-coreos-*.qcow2.xz
#   Then:  sudo mv fedora-coreos-*.qcow2 /var/lib/libvirt/images/fedora-coreos-44.qcow2
set -euo pipefail

VM_NAME="game-dev-coreos-local"
VOL_NAME="${VM_NAME}-os.qcow2"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IGNITION="${REPO_ROOT}/config/ignition/local.ign"
IMGDIR="/var/lib/libvirt/images"
BASE_IMAGE="${IMGDIR}/fedora-coreos-44.qcow2"
IGNITION_COPY="${IMGDIR}/${VM_NAME}.ign"
RAM_MB="${RAM_MB:-2048}"
VCPUS="${VCPUS:-2}"

# ── Pre-flight checks ────────────────────────────────────────────────────────

if [[ ! -f "$IGNITION" ]]; then
  echo "ERROR: Ignition config not found at $IGNITION" >&2
  echo "Run: make ignition" >&2
  exit 1
fi

if [[ ! -f "$BASE_IMAGE" ]]; then
  echo "ERROR: Base image not found at $BASE_IMAGE" >&2
  echo "  1. Download from https://fedoraproject.org/coreos/download?stream=stable&arch=x86_64" >&2
  echo "     (Bare Metal & Virtualized → QEMU → qcow2.xz)" >&2
  echo "  2. xz -d fedora-coreos-*.qcow2.xz" >&2
  echo "  3. sudo mv fedora-coreos-*.qcow2 $BASE_IMAGE" >&2
  exit 1
fi

# Locate the libvirt storage pool that owns IMGDIR.
POOL=$(virsh --connect qemu:///system pool-list --all --name \
  | while read -r p; do
      [[ -z "$p" ]] && continue
      virsh --connect qemu:///system pool-dumpxml "$p" 2>/dev/null \
        | grep -q "<path>${IMGDIR}</path>" && echo "$p" && break
    done)

if [[ -z "$POOL" ]]; then
  echo "ERROR: No libvirt storage pool found for $IMGDIR" >&2
  echo "Run: scripts/local-setup.sh" >&2
  exit 1
fi

# ── Destroy existing VM if present ──────────────────────────────────────────

if virsh --connect qemu:///system dominfo "$VM_NAME" &>/dev/null; then
  echo "Destroying existing VM: $VM_NAME"
  virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
  virsh --connect qemu:///system undefine "$VM_NAME" 2>/dev/null || true
fi

# ── Create overlay disk via libvirt (keeps pool registry in sync) ────────────

echo "Creating overlay disk ..."
virsh --connect qemu:///system vol-delete --pool "$POOL" "$VOL_NAME" 2>/dev/null || true
virsh --connect qemu:///system vol-create --pool "$POOL" /dev/stdin << VOLEOF
<volume>
  <name>${VOL_NAME}</name>
  <capacity unit="bytes">0</capacity>
  <target><format type='qcow2'/></target>
  <backingStore>
    <path>${BASE_IMAGE}</path>
    <format type='qcow2'/>
  </backingStore>
</volume>
VOLEOF

echo "Copying Ignition config ..."
cp -f "$IGNITION" "$IGNITION_COPY"

# ── Create VM ────────────────────────────────────────────────────────────────

echo "Creating VM: $VM_NAME"
virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --ram "$RAM_MB" \
  --vcpus "$VCPUS" \
  --os-variant fedora-coreos-stable \
  --machine q35 \
  --import \
  --disk "vol=${POOL}/${VOL_NAME},format=qcow2,bus=virtio" \
  --network network=default \
  --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGNITION_COPY}" \
  --noautoconsole \
  --wait 0

echo ""
echo "VM '${VM_NAME}' created. Wait ~30s for first boot, then:"
echo "  make local-ip    # get the IP address"
echo "  make local-ssh   # open an SSH session"
