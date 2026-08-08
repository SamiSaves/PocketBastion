#!/usr/bin/env bash
# destroy-vm.sh — remove the mock VM, keep its disk image.
#
# The disk image is the mock's microSD card: the OS on it is disposable, but
# /mnt/state is not. `make local-up` reflashes it and the state comes back.
#
# To throw the card away entirely, run: make local-wipe-state
set -euo pipefail

VM_NAME="pocketbastion-local"
DISK="${VM_DISK:-/var/lib/libvirt/images/${VM_NAME}.raw}"

if ! virsh --connect qemu:///system dominfo "$VM_NAME" &>/dev/null; then
  echo "VM '$VM_NAME' does not exist; nothing to destroy."
  exit 0
fi

echo "Destroying VM: $VM_NAME"
virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
virsh --connect qemu:///system undefine "$VM_NAME" 2>/dev/null || true

echo "Disk image preserved: ${DISK}"
echo "Done."
