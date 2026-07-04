#!/usr/bin/env bash
# setup.sh — one-time host setup for local KVM development.
#
# Run this once after installing packages and before using make local-up.
# Safe to run multiple times (idempotent).
set -euo pipefail

IMGDIR="/var/lib/libvirt/images"

echo "=== local-setup: one-time libvirt configuration ==="

# ── Storage pool ─────────────────────────────────────────────────────────────
# Ensure a pool pointing at the standard images directory exists and is active.

POOL=$(virsh --connect qemu:///system pool-list --all --name \
  | while read -r p; do
      [[ -z "$p" ]] && continue
      virsh --connect qemu:///system pool-dumpxml "$p" 2>/dev/null \
        | grep -q "<path>${IMGDIR}</path>" && echo "$p" && break
    done)

if [[ -z "$POOL" ]]; then
  echo "Creating storage pool 'default' -> $IMGDIR"
  virsh --connect qemu:///system pool-define-as default dir --target "$IMGDIR"
  virsh --connect qemu:///system pool-autostart default
  POOL="default"
else
  echo "Storage pool '$POOL' already exists."
fi

POOL_STATE=$(virsh --connect qemu:///system pool-info "$POOL" | awk '/^State:/{print $2}')
if [[ "$POOL_STATE" != "running" ]]; then
  echo "Starting pool '$POOL' ..."
  virsh --connect qemu:///system pool-start "$POOL"
else
  echo "Pool '$POOL' is already active."
fi

echo ""
echo "=== Setup complete. You can now run: make local-up ==="
