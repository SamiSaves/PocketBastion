#!/bin/bash
# pairing-address.sh — record the box's LAN address for Orca's pairing offers.
#
# Orca embeds an endpoint in every pairing code, and the client dials exactly
# that. The container is on its own netns, so left to itself Orca advertises a
# podman-internal address that nothing on the LAN can reach. The address is
# DHCP-assigned, so it is not knowable at render time either — hence, boot.
set -euo pipefail

OUT=/run/pocketbastion/pairing.env

# The interface the box reaches its LAN on is the one a client on that LAN can
# reach back. `hostname -I` would pick the first of several — podman bridges
# included — with no such guarantee.
addr=$(ip -4 -o route get 1.1.1.1 | grep -oP 'src \K[0-9.]+' || true)

mkdir -p "$(dirname "$OUT")"
printf 'PAIRING_ADDRESS=%s\n' "$addr" > "$OUT"
chmod 644 "$OUT"

# Quadlet's EnvironmentFile has no optional variant, so the file must exist
# either way — but an empty address is a broken box, and failing here says so
# in `systemctl status` instead of at pairing time.
[[ -n "$addr" ]] || {
  echo "ERROR: no IPv4 address on the default route; Orca has nothing to advertise." >&2
  exit 1
}
