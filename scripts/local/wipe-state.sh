#!/usr/bin/env bash
# wipe-state.sh — permanently delete the mock VM's disk image.
#
# WARNING: This destroys all data in /mnt/state (repos, orca sessions,
# caches, deploy keys). There is no recovery.
#
# On the Pi, root and state share one card; the mock is the same, so this
# discards both. The next `make local-up` is then a FIRST flash — which is the
# code path worth testing after a config change to the disk layout.
#
# The VM must be destroyed first (make local-down).
set -euo pipefail

VM_NAME="pocketbastion-local"
DISK="${VM_DISK:-/var/lib/libvirt/images/${VM_NAME}.raw}"

if virsh --connect qemu:///system domstate "$VM_NAME" 2>/dev/null | grep -q running; then
  echo "ERROR: VM '$VM_NAME' is still running. Run 'make local-down' first." >&2
  exit 1
fi

if [[ ! -f "$DISK" ]]; then
  echo "No disk image at ${DISK}. Nothing to wipe."
  exit 0
fi

echo "WARNING: About to permanently delete ${DISK}"
read -r -p "Type 'yes' to confirm: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }

sudo rm -f "$DISK"
echo "Disk image deleted."
