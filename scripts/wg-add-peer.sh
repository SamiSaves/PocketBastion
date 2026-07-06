#!/usr/bin/env bash
# wg-add-peer.sh — Register a WireGuard peer on the running VM.
#
# Security model: the peer's keypair is generated ON the peer device (the
# WireGuard phone app, or `wg genkey` on a laptop) and its PRIVATE key never
# leaves that device. This script only ever handles the peer's PUBLIC key,
# pasted in on the command line.
#
# Usage (via Makefile target):
#   make wg-add-peer PEER=phone IP=10.44.0.4 PUBKEY=<client-public-key>
#
# Appends a [Peer] block to /mnt/state/wireguard/peers.conf on the VM
# (persists across VM recreations), then restarts WireGuard.
#
# VPN address assignments:
#   server:  10.44.0.1
#   laptop:  10.44.0.2
#   desktop: 10.44.0.3
#   phone:   10.44.0.4
set -euo pipefail

PEER="${PEER:-}"
IP="${IP:-}"
PUBKEY="${PUBKEY:-}"

if [[ -z "$PEER" || -z "$IP" || -z "$PUBKEY" ]]; then
  echo "Usage: PEER=<name> IP=<vpn-ip> PUBKEY=<client-public-key> $0" >&2
  echo "Example: PEER=phone IP=10.44.0.4 PUBKEY=abcd...= $0" >&2
  echo >&2
  echo "PUBKEY is the device's PUBLIC key — generate the keypair ON the device" >&2
  echo "(WireGuard app or 'wg genkey'); its private key must never leave it." >&2
  exit 1
fi

# Boundary check: WireGuard keys are 44-char base64 (32 bytes). Reject anything
# else so a truncated paste or the wrong string never reaches the server config.
if [[ ! "$PUBKEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "ERROR: PUBKEY is not a valid WireGuard key (expected 44-char base64)." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_KEY="$PUBKEY"
VM_IP="$("${REPO_ROOT}/scripts/local/ip.sh")"

if [[ -z "$VM_IP" ]]; then
  echo "ERROR: Could not determine VM IP. Is the VM running?" >&2
  exit 1
fi

# Check peer not already present
if ssh -o StrictHostKeyChecking=no "core@${VM_IP}" \
    grep -qF "$PUBLIC_KEY" /mnt/state/wireguard/peers.conf 2>/dev/null; then
  echo "Peer '$PEER' is already present in peers.conf — skipping."
  exit 0
fi

echo "Adding peer '$PEER' ($IP) to VM ..."

# Append [Peer] block to peers.conf on the state disk (survives VM recreation)
printf '\n[Peer]\n# %s\nPublicKey  = %s\nAllowedIPs = %s/32\n' \
  "$PEER" "$PUBLIC_KEY" "$IP" \
  | ssh -o StrictHostKeyChecking=no "core@${VM_IP}" \
      sudo tee -a /mnt/state/wireguard/peers.conf > /dev/null

# Re-run wg-setup.service to regenerate wg0.conf, then reload WireGuard
ssh -o StrictHostKeyChecking=no "core@${VM_IP}" \
  "sudo systemctl restart wg-setup.service && sudo systemctl restart wg-quick@wg0.service"

echo "Done. Peer '$PEER' added and WireGuard reloaded."
