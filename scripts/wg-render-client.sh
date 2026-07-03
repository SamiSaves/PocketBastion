#!/usr/bin/env bash
# wg-render-client.sh — Render a WireGuard client config for a peer.
#
# Usage (via Makefile target):
#   make wg-render-client PEER=laptop ENDPOINT=192.168.122.100
#
# ENDPOINT is the VM's libvirt IP for local dev, or DNS name for DigitalOcean.
#
# Requires:
#   secrets/wireguard/<PEER>.private    — run: make wg-generate-keys PEER=<name>
#   secrets/wireguard/server.public     — run: make wg-server-pubkey
#
# Output:
#   secrets/wireguard/<PEER>-local.conf   (chmod 600)
#
# VPN address assignments:
#   server:  10.44.0.1
#   laptop:  10.44.0.2
#   desktop: 10.44.0.3
#   phone:   10.44.0.4
set -euo pipefail

PEER="${PEER:-}"
ENDPOINT="${ENDPOINT:-}"

if [[ -z "$PEER" || -z "$ENDPOINT" ]]; then
  echo "Usage: PEER=<name> ENDPOINT=<ip-or-hostname> $0" >&2
  echo "Example: PEER=laptop ENDPOINT=192.168.122.100 $0" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/secrets/wireguard"
PRIVATE_KEY_FILE="${SECRETS_DIR}/${PEER}.private"
SERVER_PUBKEY_FILE="${SECRETS_DIR}/server.public"

[[ -f "$PRIVATE_KEY_FILE" ]] || {
  echo "ERROR: ${PRIVATE_KEY_FILE} not found." >&2
  echo "Run: make wg-generate-keys PEER=$PEER" >&2
  exit 1
}
[[ -f "$SERVER_PUBKEY_FILE" ]] || {
  echo "ERROR: ${SERVER_PUBKEY_FILE} not found." >&2
  echo "Run: make wg-server-pubkey" >&2
  exit 1
}

# Stable VPN IP per peer name; override with CLIENT_IP env var
case "$PEER" in
  laptop)   VPN_IP="10.44.0.2" ;;
  desktop)  VPN_IP="10.44.0.3" ;;
  phone)    VPN_IP="10.44.0.4" ;;
  *)        VPN_IP="${CLIENT_IP:-}" ;;
esac

if [[ -z "$VPN_IP" ]]; then
  echo "ERROR: Unknown peer '$PEER'. Set CLIENT_IP=10.44.0.X to override." >&2
  exit 1
fi

CLIENT_PRIVATE_KEY=$(cat "$PRIVATE_KEY_FILE")
SERVER_PUBLIC_KEY=$(cat "$SERVER_PUBKEY_FILE")
PORT="${WG_PORT:-51820}"
OUT="${SECRETS_DIR}/${PEER}-local.conf"

cat > "$OUT" << EOF
[Interface]
Address    = ${VPN_IP}/24
PrivateKey = ${CLIENT_PRIVATE_KEY}

[Peer]
PublicKey           = ${SERVER_PUBLIC_KEY}
Endpoint            = ${ENDPOINT}:${PORT}
AllowedIPs          = 10.44.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 "$OUT"
echo "Client config written to: $OUT"
echo ""
echo "To connect from this machine:"
echo "  sudo wg-quick up $OUT"
echo "  ping 10.44.0.1"
echo "  ssh core@10.44.0.1"
