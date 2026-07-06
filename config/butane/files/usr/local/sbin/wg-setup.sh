#!/bin/bash
set -euo pipefail

WG_STATE=/mnt/state/wireguard
WG_CONF=/etc/wireguard/wg0.conf

install -d -m 0700 "$WG_STATE"
install -d -m 0700 /etc/wireguard

# Generate server keypair once; persist to state disk so it survives
# VM recreation (the public key is needed to configure client peers).
if [[ ! -f "$WG_STATE/server_private.key" ]]; then
  wg genkey > "$WG_STATE/server_private.key"
  chmod 600 "$WG_STATE/server_private.key"
  echo "Generated new WireGuard server private key."
fi

wg pubkey < "$WG_STATE/server_private.key" > "$WG_STATE/server_public.key"
chmod 644 "$WG_STATE/server_public.key"

SERVER_PRIVATE_KEY=$(cat "$WG_STATE/server_private.key")

# Render wg0.conf header
cat > "$WG_CONF" << EOF
[Interface]
Address    = 10.44.0.1/24
ListenPort = 51820
PrivateKey = ${SERVER_PRIVATE_KEY}
EOF

# Append peers from state disk (populated by wg-add-peer.sh on the host)
PEERS_FILE="$WG_STATE/peers.conf"
if [[ -s "$PEERS_FILE" ]]; then
  printf '\n' >> "$WG_CONF"
  cat "$PEERS_FILE" >> "$WG_CONF"
fi

# Append the provision-time bootstrap peer if present. DigitalOcean bakes this
# in via Ignition so the tunnel is up on first boot, before SSH exists; local
# never ships the file so this is a no-op there.
# ponytail: no dedup — if you later re-add the bootstrap device via wg-add-peer
# you'll get a duplicate [Peer]; just don't re-add the laptop that seeded boot.
BOOTSTRAP_FILE=/etc/wireguard/bootstrap-peer.conf
if [[ -s "$BOOTSTRAP_FILE" ]]; then
  printf '\n' >> "$WG_CONF"
  cat "$BOOTSTRAP_FILE" >> "$WG_CONF"
fi

chmod 600 "$WG_CONF"
echo "wg0.conf rendered ($(grep -c '^\[Peer\]' "$WG_CONF" || true) peer(s))."
