#!/usr/bin/env bash
# destroy-vm.sh — destroy the local KVM dev VM.
#
# The OS overlay disk and Ignition copy are deleted (they are recreated by
# local-create-vm.sh each time). The state disk is intentionally preserved
# so that /mnt/state data survives VM destruction.
#
# To also wipe the state disk, run: make local-wipe-state
set -euo pipefail

VM_NAME="opencode-dev-server-local"
IMGDIR="/var/lib/libvirt/images"

if ! virsh --connect qemu:///system dominfo "$VM_NAME" &>/dev/null; then
  echo "VM '$VM_NAME' does not exist; nothing to destroy."
  exit 0
fi

echo "Destroying VM: $VM_NAME"
virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
virsh --connect qemu:///system undefine "$VM_NAME" 2>/dev/null || true

rm -f "${IMGDIR}/${VM_NAME}-os.qcow2" "${IMGDIR}/${VM_NAME}.ign"

echo "State disk preserved: ${IMGDIR}/${VM_NAME}-state.qcow2"
echo "Done."
