#!/bin/bash
# Every Orca pairing code embeds the endpoint its client will dial. The
# container's netns knows only a podman-internal address, and the box's real one
# is DHCP-assigned, so the render cannot supply it either — hence, at boot.
set -euo pipefail

OUT=/run/pocketbastion/pairing.env

# The interface the box reaches its LAN on is the one a client there can reach
# back. `hostname -I` would pick the first of several, podman bridges included.
addr=$(ip -4 -o route get 1.1.1.1 | grep -oP 'src \K[0-9.]+' || true)

mkdir -p "$(dirname "$OUT")"
printf 'PAIRING_ADDRESS=%s\n' "$addr" > "$OUT"
chmod 644 "$OUT"

# The file must exist either way: Quadlet's EnvironmentFile has no optional
# variant. Failing here reports an empty address at boot rather than at pairing.
[[ -n "$addr" ]] || {
  echo "ERROR: no IPv4 address on the default route; Orca has nothing to advertise." >&2
  exit 1
}
