#!/usr/bin/env bash
# wg-server-pubkey.sh — Fetch the server's WireGuard public key from the VM.
#
# Reads /mnt/state/wireguard/server_public.key from the running VM and saves
# it to secrets/wireguard/server.public on the host.
#
# BOOTSTRAP NOTE: this key is needed to bring the tunnel UP, but SSH is
# WireGuard-only. On FIRST boot, read it from the serial console instead:
#   sudo cat /mnt/state/wireguard/server_public.key
# This SSH-based fetch is only a convenience once the tunnel is already up.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/secrets/wireguard"
# Over the tunnel — 10.44.0.1 on both envs. Override SERVER_IP for local bootstrap.
VM_IP="${SERVER_IP:-10.44.0.1}"

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
