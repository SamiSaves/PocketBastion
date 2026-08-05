#!/bin/bash
# Renders and applies the nftables ruleset, reading its mode and parameters from
# /etc/pocketbastion/firewall.env (written by scripts/render-ignition.sh).
#
# Fails CLOSED: an unknown mode, or lan mode with no TRUSTED_CIDRS, applies a
# lockdown ruleset. Fedora CoreOS ships no default ruleset, so exiting non-zero
# here would leave the box wide open.
set -euo pipefail

FW_ENV=/etc/pocketbastion/firewall.env
NFT_CONF=/etc/nftables/pocketbastion.nft
WG_PORT=51820

NETWORK_MODE=wireguard
TRUSTED_CIDRS=""
OPENCODE_PORTS=""

if [[ -r "$FW_ENV" ]]; then
  # shellcheck source=/dev/null
  source "$FW_ENV"
else
  echo "WARNING: $FW_ENV missing; defaulting to NETWORK_MODE=wireguard." >&2
fi

install -d -m 0755 /etc/nftables

# "a b" -> "{ a, b }". Loops rather than "${s// /, }" so stray whitespace cannot
# produce a trailing comma: nft would reject the file and leave the box unfiltered.
nft_set() {
  local out=""
  for item in $1; do out+="${out:+, }$item"; done
  printf '{ %s }' "$out"
}

# IPv4 only: every service binds 0.0.0.0, so an `ip6 saddr` rule would open
# ports nothing listens on. render-ignition.sh already refuses a v6 entry, so
# one can only appear here if firewall.env was hand-edited. Drop it rather than
# emit a rule nft rejects — a rejected file fails `nft -f` and, under set -e,
# would leave the box with no ruleset at all.
CIDRS=""
for cidr in ${TRUSTED_CIDRS:-}; do
  if [[ "$cidr" == *:* ]]; then
    echo "WARNING: ignoring IPv6 entry '${cidr}' in TRUSTED_CIDRS; IPv4 only." >&2
  else
    CIDRS+="${CIDRS:+ }${cidr}"
  fi
done

MODE_RULES=""
BANNER=""

case "$NETWORK_MODE" in
  wireguard)
    BANNER="wireguard — only the WireGuard port is public; SSH and OpenCode are on wg0"
    MODE_RULES=$(cat <<EOF
    udp dport ${WG_PORT} accept
    iifname "wg0" accept
EOF
)
    ;;

  lan)
    if [[ -z "$CIDRS" ]]; then
      echo "ERROR: NETWORK_MODE=lan with no usable IPv4 TRUSTED_CIDRS. Locking down." >&2
      BANNER="LOCKDOWN — lan mode with no TRUSTED_CIDRS"
      MODE_RULES="    # Nothing is trusted."
    else
      BANNER="lan — SSH and OpenCode open to ${CIDRS}"
      MODE_RULES="    ip saddr $(nft_set "$CIDRS") tcp dport $(nft_set "22 ${OPENCODE_PORTS}") accept"
    fi
    ;;

  *)
    echo "ERROR: unknown NETWORK_MODE='${NETWORK_MODE}'. Locking down." >&2
    BANNER="LOCKDOWN — unknown NETWORK_MODE '${NETWORK_MODE}'"
    MODE_RULES="    # Nothing is trusted."
    ;;
esac

cat > "$NFT_CONF" << EOF
#!/usr/sbin/nft -f
# Rendered by firewall-setup.sh (mode: ${NETWORK_MODE}) — do not edit by hand.
flush ruleset

table inet pocketbastion {
  chain input {
    type filter hook input priority filter; policy drop;

    ct state established,related accept
    ct state invalid drop
    iif "lo" accept

    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept

${MODE_RULES}
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
echo "Firewall applied (${BANNER})."
