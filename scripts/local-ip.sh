#!/usr/bin/env bash
# local-ip.sh — print the IP address of the local KVM dev VM.
set -euo pipefail

VM_NAME="game-dev-coreos-local"

IP=$(virsh --connect qemu:///system domifaddr "$VM_NAME" --source lease \
  | awk '/ipv4/ {split($4, a, "/"); print a[1]}' \
  | head -n1)

if [[ -z "$IP" ]]; then
  echo "ERROR: could not get IP for '$VM_NAME'. Is it running?" >&2
  exit 1
fi

echo "$IP"
