#!/bin/bash
set -euo pipefail

# Safe default in case no env file is present: closed to the public.
# Environments opt into public SSH via their firewall.env (local does).
ALLOW_PUBLIC_SSH_FOR_LOCAL_DEBUG=false
WG_PORT=51820

# Baked default (lives on the disposable OS disk).
[[ -f /etc/opencode-dev-server/firewall.env ]] && source /etc/opencode-dev-server/firewall.env

# Persistent override on the state disk — survives VM recreation.
# Flip the toggle here once WireGuard access is proven:
#   echo 'ALLOW_PUBLIC_SSH_FOR_LOCAL_DEBUG=false' \
#     | sudo tee /mnt/state/firewall/firewall.env
#   sudo systemctl restart firewall.service
[[ -f /mnt/state/firewall/firewall.env ]] && source /mnt/state/firewall/firewall.env

NFT_CONF=/etc/nftables/opencode-dev-server.nft
install -d -m 0755 /etc/nftables

# Only emit the public SSH rule when the debug toggle is enabled.
PUBLIC_SSH_RULE=""
if [[ "${ALLOW_PUBLIC_SSH_FOR_LOCAL_DEBUG,,}" == "true" ]]; then
  PUBLIC_SSH_RULE='tcp dport 22 accept comment "public SSH (local debug toggle)"'
fi

cat > "$NFT_CONF" << EOF
#!/usr/sbin/nft -f
# Rendered by firewall-setup.sh — do not edit by hand.
flush ruleset

table inet opencode_dev {
  chain input {
    type filter hook input priority filter; policy drop;

    ct state established,related accept
    ct state invalid drop
    iif "lo" accept

    # ICMP / ping
    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept

    # WireGuard handshake + tunnel — must reach the public interface
    udp dport ${WG_PORT} accept

    # Anything arriving through the VPN is trusted (SSH, OpenCode, Vite)
    iifname "wg0" accept

    # Optional: SSH from the normal/libvirt network (local debug only)
    ${PUBLIC_SSH_RULE}
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
EOF

nft -f "$NFT_CONF"
echo "Firewall applied (public SSH debug = ${ALLOW_PUBLIC_SSH_FOR_LOCAL_DEBUG})."
