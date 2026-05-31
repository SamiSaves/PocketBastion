#!/usr/bin/env bash
# local-create-vm.sh — create (or replace) the local KVM dev VM.
# Prerequisites: check-prereqs.sh passes, ignition-local has been run.
set -euo pipefail

VM_NAME="game-dev-coreos-local"
IGNITION="$(dirname "$0")/../config/ignition/local.ign"
FCOS_IMAGE="${FCOS_IMAGE:-}"  # Set to path of downloaded CoreOS qcow2 image
STATE_DISK_SIZE="${STATE_DISK_SIZE:-20}"  # GiB
RAM_MB="${RAM_MB:-2048}"
VCPUS="${VCPUS:-2}"

if [[ ! -f "$IGNITION" ]]; then
  echo "ERROR: Ignition config not found at $IGNITION" >&2
  echo "Run: make ignition-local" >&2
  exit 1
fi

if [[ -z "$FCOS_IMAGE" ]]; then
  echo "ERROR: FCOS_IMAGE is not set." >&2
  echo "Download a Fedora CoreOS qcow2 image and set FCOS_IMAGE=/path/to/image.qcow2" >&2
  exit 1
fi

# Destroy existing VM if present
if virsh --connect qemu:///system dominfo "$VM_NAME" &>/dev/null; then
  echo "Destroying existing VM: $VM_NAME"
  virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
  virsh --connect qemu:///system undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
fi

# Create state disk (will be formatted and labelled on first use)
STATE_DISK_PATH="/var/lib/libvirt/images/${VM_NAME}-state.qcow2"
if [[ ! -f "$STATE_DISK_PATH" ]]; then
  echo "Creating state disk: $STATE_DISK_PATH (${STATE_DISK_SIZE}G)"
  qemu-img create -f qcow2 "$STATE_DISK_PATH" "${STATE_DISK_SIZE}G"
fi

echo "Creating VM: $VM_NAME"
virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --ram "$RAM_MB" \
  --vcpus "$VCPUS" \
  --os-variant fedora-coreos-stable \
  --import \
  --disk "path=$FCOS_IMAGE,format=qcow2,bus=virtio" \
  --disk "path=$STATE_DISK_PATH,format=qcow2,bus=virtio" \
  --network network=default \
  --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=$(realpath "$IGNITION")" \
  --noautoconsole \
  --wait 0

echo "VM created. Check IP with: make ip"
echo "SSH with: make ssh"
