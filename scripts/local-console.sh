#!/usr/bin/env bash
# local-console.sh — open the serial console of the local KVM dev VM.
# Exit with Ctrl+]
set -euo pipefail

VM_NAME="opencode-dev-server-local"

echo "Attaching to serial console for '$VM_NAME'."
echo "Exit with: Ctrl+]"
exec virsh --connect qemu:///system console "$VM_NAME"
