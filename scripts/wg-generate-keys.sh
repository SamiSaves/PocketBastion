#!/usr/bin/env bash
# wg-generate-keys.sh — Generate a WireGuard keypair for a peer on the host.
#
# Usage:
#   scripts/wg-generate-keys.sh <peer-name>
#   scripts/wg-generate-keys.sh laptop
#
# Saves to:
#   secrets/wireguard/<name>.private   (chmod 600 — never commit)
#   secrets/wireguard/<name>.public    (safe to share)
#
# Next steps after generating:
#   make wg-server-pubkey              # get server public key from running VM
#   make wg-add-peer PEER=<name> IP=10.44.0.X
#   make wg-render-client PEER=<name> ENDPOINT=<vm-ip>
set -euo pipefail

PEER="${1:-}"
if [[ -z "$PEER" ]]; then
  echo "Usage: $0 <peer-name>" >&2
  echo "Example: $0 laptop" >&2
  exit 1
fi

command -v wg >/dev/null 2>&1 || {
  echo "ERROR: 'wg' not found. Install wireguard-tools:" >&2
  echo "  sudo apt install wireguard-tools" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/secrets/wireguard"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

PRIVATE="${SECRETS_DIR}/${PEER}.private"
PUBLIC="${SECRETS_DIR}/${PEER}.public"

if [[ -f "$PRIVATE" ]]; then
  echo "Key already exists: $PRIVATE"
  echo "Delete it first if you want to regenerate."
  exit 1
fi

wg genkey > "$PRIVATE"
chmod 600 "$PRIVATE"
wg pubkey < "$PRIVATE" > "$PUBLIC"

echo "Generated keypair for peer: $PEER"
echo "  Private: $PRIVATE"
echo "  Public:  $PUBLIC"
echo ""
echo "Public key:"
cat "$PUBLIC"
echo ""
echo "Next steps:"
echo "  1. make wg-server-pubkey                        (after VM first boot)"
echo "  2. make wg-add-peer PEER=$PEER IP=10.44.0.X"
echo "  3. make wg-render-client PEER=$PEER ENDPOINT=\$(make -s local-ip)"
