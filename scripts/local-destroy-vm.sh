#!/usr/bin/env bash
# local-destroy-vm.sh — destroy the local KVM dev VM (OS disk only).
# The state disk at /var/lib/libvirt/images/game-dev-coreos-local-state.qcow2
# is intentionally preserved. Pass --wipe-state to also remove it.
set -euo pipefail

VM_NAME="game-dev-coreos-local"
STATE_DISK="/var/lib/libvirt/images/${VM_NAME}-state.qcow2"
WIPE_STATE=0

for arg in "$@"; do
  [[ "$arg" == "--wipe-state" ]] && WIPE_STATE=1
done

if ! virsh --connect qemu:///system dominfo "$VM_NAME" &>/dev/null; then
  echo "VM '$VM_NAME' does not exist; nothing to destroy."
  exit 0
fi

echo "Destroying VM: $VM_NAME"
virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
virsh --connect qemu:///system undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true

if [[ "$WIPE_STATE" -eq 1 ]]; then
  if [[ -f "$STATE_DISK" ]]; then
    echo "Removing state disk: $STATE_DISK"
    rm -f "$STATE_DISK"
  fi
else
  echo "State disk preserved: $STATE_DISK"
  echo "Pass --wipe-state to also remove it."
fi

echo "Done."
