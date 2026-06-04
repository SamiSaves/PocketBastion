#!/usr/bin/env bash
# local-destroy-vm.sh — destroy the local KVM dev VM.
# The base image at /var/lib/libvirt/images/fedora-coreos-44.qcow2 is kept.
set -euo pipefail

VM_NAME="game-dev-coreos-local"
IMGDIR="/var/lib/libvirt/images"

if ! virsh --connect qemu:///system dominfo "$VM_NAME" &>/dev/null; then
  echo "VM '$VM_NAME' does not exist; nothing to destroy."
  exit 0
fi

echo "Destroying VM: $VM_NAME"
virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
virsh --connect qemu:///system undefine "$VM_NAME" 2>/dev/null || true

rm -f "${IMGDIR}/${VM_NAME}-os.qcow2" "${IMGDIR}/${VM_NAME}.ign"

echo "Done."
