#!/usr/bin/env bash
# create-vm.sh — create (or replace) the local KVM dev VM.
#
# Prerequisites (one-time host setup):
#   scripts/local/setup.sh       — run once after installing packages
#
# Base image must be placed at:
#   /var/lib/libvirt/images/fedora-coreos-44.qcow2
#
# Override the base image path with:
#   FCOS_IMAGE=/path/to/fedora-coreos.qcow2 make local-up
#
# Download from:
#   https://fedoraproject.org/coreos/download?stream=stable&arch=x86_64
#   Choose: Bare Metal & Virtualized → QEMU (qcow2.xz)
#   Then:  xz -d fedora-coreos-*.qcow2.xz
#   Then:  sudo mv fedora-coreos-*.qcow2 /var/lib/libvirt/images/fedora-coreos-44.qcow2
set -euo pipefail

VM_NAME="opencode-dev-server-local"
VOL_NAME="${VM_NAME}-os.qcow2"
STATE_VOL_NAME="${VM_NAME}-state.qcow2"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IGNITION="${REPO_ROOT}/config/ignition/local.ign"
IMGDIR="/var/lib/libvirt/images"
# FCOS_IMAGE may be set to an absolute path or a path relative to the repo root.
if [[ -n "${FCOS_IMAGE:-}" ]]; then
  [[ "$FCOS_IMAGE" != /* ]] && FCOS_IMAGE="${REPO_ROOT}/${FCOS_IMAGE}"
  BASE_IMAGE="$FCOS_IMAGE"
else
  BASE_IMAGE="${IMGDIR}/fedora-coreos-44.qcow2"
fi
IGNITION_COPY="${IMGDIR}/${VM_NAME}.ign"
RAM_MB="${RAM_MB:-2048}"
VCPUS="${VCPUS:-2}"
STATE_DISK_GB="${STATE_DISK_GB:-10}"

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
  echo "Run: scripts/local/setup.sh" >&2
  exit 1
fi

# ── Create or reuse state disk ────────────────────────────────────────────────

if virsh --connect qemu:///system vol-info --pool "$POOL" "$STATE_VOL_NAME" &>/dev/null; then
  echo "Reusing existing state disk: ${IMGDIR}/${STATE_VOL_NAME}"
else
  echo "Creating state disk (${STATE_DISK_GB}GB) ..."
  virsh --connect qemu:///system vol-create-as \
    "$POOL" "$STATE_VOL_NAME" "${STATE_DISK_GB}G" --format qcow2
fi

# ── Destroy existing VM if present ──────────────────────────────────────────

if virsh --connect qemu:///system dominfo "$VM_NAME" &>/dev/null; then
  echo "Destroying existing VM: $VM_NAME"
  virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
  virsh --connect qemu:///system undefine "$VM_NAME" 2>/dev/null || true
fi

# ── Create OS overlay disk via libvirt (keeps pool registry in sync) ─────────

echo "Creating OS overlay disk ..."
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
IGN_VOL_NAME="${VM_NAME}.ign"
IGN_SIZE=$(stat -c%s "$IGNITION")
virsh --connect qemu:///system vol-delete --pool "$POOL" "$IGN_VOL_NAME" 2>/dev/null || true
virsh --connect qemu:///system vol-create-as "$POOL" "$IGN_VOL_NAME" "$IGN_SIZE" --format raw
virsh --connect qemu:///system vol-upload --pool "$POOL" "$IGN_VOL_NAME" "$IGNITION"

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
  --disk "vol=${POOL}/${STATE_VOL_NAME},format=qcow2,bus=virtio" \
  --network network=default \
  --sysinfo "type=fwcfg,entry0.name=opt/com.coreos/config,entry0.file=${IGNITION_COPY}" \
  --noautoconsole \
  --wait 0

echo ""
echo "VM '${VM_NAME}' created. Wait ~30s for first boot, then:"
echo "  make local-ip    # get the IP address"
echo "  make local-ssh   # open an SSH session"
