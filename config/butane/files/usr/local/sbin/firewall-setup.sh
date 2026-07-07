#!/bin/bash
set -euo pipefail

# WireGuard is the only entry point: the public interface exposes just the WG
# handshake port; everything else is reachable only over the wg0 tunnel. SSH is
# not opened on the public network at all — break-glass is the serial console.
WG_PORT=51820

NFT_CONF=/etc/nftables/opencode-dev-server.nft
install -d -m 0755 /etc/nftables

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
echo "Firewall applied (WireGuard-only; SSH reachable via wg0)."
