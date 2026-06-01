#!/usr/bin/env bash
# local-create-vm.sh — create (or replace) the local KVM dev VM.
# Prerequisites: check-prereqs.sh passes, ignition config has been rendered.
#
# Usage:
#   FCOS_IMAGE=/path/to/fedora-coreos-*.qcow2 ./scripts/local-create-vm.sh
#
# Download image from:
#   https://fedoraproject.org/coreos/download?stream=stable&arch=x86_64
#   Choose: Bare Metal & Virtualized → QEMU (qcow2.xz), then: xz -d *.qcow2.xz
set -euo pipefail

VM_NAME="game-dev-coreos-local"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IGNITION="${REPO_ROOT}/config/ignition/local.ign"
FCOS_IMAGE="${FCOS_IMAGE:-}"
RAM_MB="${RAM_MB:-2048}"
VCPUS="${VCPUS:-2}"

# ── Pre-flight checks ────────────────────────────────────────────────────────

if [[ ! -f "$IGNITION" ]]; then
  echo "ERROR: Ignition config not found at $IGNITION" >&2
  echo "Run: make ignition" >&2
  exit 1
fi

if [[ -z "$FCOS_IMAGE" ]]; then
  echo "ERROR: FCOS_IMAGE is not set." >&2
  echo "Download a Fedora CoreOS stable qcow2 image and set FCOS_IMAGE=/path/to/image.qcow2" >&2
  echo "  https://fedoraproject.org/coreos/download?stream=stable&arch=x86_64" >&2
  exit 1
fi

if [[ ! -f "$FCOS_IMAGE" ]]; then
  echo "ERROR: FCOS_IMAGE not found: $FCOS_IMAGE" >&2
  exit 1
fi

# ── Destroy existing VM if present ──────────────────────────────────────────

if virsh --connect qemu:///system dominfo "$VM_NAME" &>/dev/null; then
  echo "Destroying existing VM: $VM_NAME"
  virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
  virsh --connect qemu:///system undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
fi

# ── Create VM ────────────────────────────────────────────────────────────────

echo "Creating VM: $VM_NAME"
virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --ram "$RAM_MB" \
  --vcpus "$VCPUS" \
  --os-variant fedora-coreos-stable \
  --import \
  --disk "path=$(realpath "$FCOS_IMAGE"),format=qcow2,bus=virtio" \
  --network network=default \
  --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=$(realpath "$IGNITION")" \
  --noautoconsole \
  --wait 0

echo ""
echo "VM '${VM_NAME}' created. Wait ~30s for first boot, then:"
echo "  make local-ip    # get the IP address"
echo "  make local-ssh   # open an SSH session"
