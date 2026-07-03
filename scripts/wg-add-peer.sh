#!/usr/bin/env bash
# wg-add-peer.sh — Add a WireGuard peer to the running VM.
#
# Usage (via Makefile target):
#   make wg-add-peer PEER=laptop IP=10.44.0.2
#
# Reads the peer's public key from:
#   secrets/wireguard/<PEER>.public
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

if [[ -z "$PEER" || -z "$IP" ]]; then
  echo "Usage: PEER=<name> IP=<vpn-ip> $0" >&2
  echo "Example: PEER=laptop IP=10.44.0.2 $0" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_KEY_FILE="${REPO_ROOT}/secrets/wireguard/${PEER}.public"

if [[ ! -f "$PUBLIC_KEY_FILE" ]]; then
  echo "ERROR: Public key not found: $PUBLIC_KEY_FILE" >&2
  echo "Run: scripts/wg-generate-keys.sh $PEER" >&2
  exit 1
fi

PUBLIC_KEY=$(cat "$PUBLIC_KEY_FILE")
VM_IP="$("${REPO_ROOT}/scripts/local-ip.sh")"

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
