#!/usr/bin/env bash
# local-wipe-state.sh — permanently delete the local state disk.
#
# WARNING: This destroys all data in /mnt/state (repos, opencode sessions,
# caches, WireGuard keys). There is no recovery. Use only when you want a
# completely fresh start.
#
# The VM must be destroyed first (make local-down).
set -euo pipefail

VM_NAME="game-dev-coreos-local"
IMGDIR="/var/lib/libvirt/images"
STATE_VOL="${VM_NAME}-state.qcow2"

# Refuse to wipe while VM is running.
if virsh --connect qemu:///system domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
  echo "ERROR: VM '$VM_NAME' is still running. Run 'make local-down' first." >&2
  exit 1
fi

if ! virsh --connect qemu:///system vol-info --pool default "$STATE_VOL" &>/dev/null; then
  # Try to find the right pool
  POOL=$(virsh --connect qemu:///system pool-list --all --name \
    | while read -r p; do
        [[ -z "$p" ]] && continue
        virsh --connect qemu:///system pool-dumpxml "$p" 2>/dev/null \
          | grep -q "<path>${IMGDIR}</path>" && echo "$p" && break
      done)
  if [[ -z "$POOL" ]] || ! virsh --connect qemu:///system vol-info --pool "$POOL" "$STATE_VOL" &>/dev/null; then
    echo "State disk not found: ${IMGDIR}/${STATE_VOL}"
    echo "Nothing to wipe."
    exit 0
  fi
else
  POOL="default"
fi

echo "WARNING: About to permanently delete ${IMGDIR}/${STATE_VOL}"
read -r -p "Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

virsh --connect qemu:///system vol-delete --pool "$POOL" "$STATE_VOL"
echo "State disk deleted."
