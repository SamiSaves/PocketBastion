#!/usr/bin/env bash
# wg-server-pubkey.sh — Fetch the server's WireGuard public key from the VM.
#
# Reads /mnt/state/wireguard/server_public.key from the running VM and saves
# it to secrets/wireguard/server.public on the host.
#
# Run once after the VM's first boot (wg-setup.service generates the key).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/secrets/wireguard"
VM_IP="$("${REPO_ROOT}/scripts/local/ip.sh")"

if [[ -z "$VM_IP" ]]; then
  echo "ERROR: Could not determine VM IP. Is the VM running?" >&2
  exit 1
fi

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

echo "Fetching server public key from core@${VM_IP} ..."
ssh -o StrictHostKeyChecking=no "core@${VM_IP}" \
  sudo cat /mnt/state/wireguard/server_public.key \
  > "${SECRETS_DIR}/server.public"

echo "Saved to: ${SECRETS_DIR}/server.public"
echo ""
echo "Server public key:"
cat "${SECRETS_DIR}/server.public"
