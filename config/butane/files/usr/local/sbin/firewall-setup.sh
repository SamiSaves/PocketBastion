#!/bin/bash
# Renders and applies the nftables ruleset, reading its mode and parameters from
# /etc/pocketbastion/firewall.env (written by scripts/render-ignition.sh).
#
# Fails CLOSED: an unknown mode, lan mode with no TRUSTED_CIDRS, or a ruleset
# nft rejects all end in a lockdown ruleset. Fedora CoreOS ships no default
# ruleset, so exiting non-zero here would leave the box wide open.
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

# Empty MODE_RULES is the lockdown ruleset: nothing beyond lo, established and
# ICMP is accepted. Both error paths below fall through to it.
MODE_RULES="    # Nothing is trusted."
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
    if [[ -z "${TRUSTED_CIDRS// /}" ]]; then
      echo "ERROR: NETWORK_MODE=lan with no TRUSTED_CIDRS. Locking down." >&2
      BANNER="LOCKDOWN — lan mode with no TRUSTED_CIDRS"
    else
      BANNER="lan — SSH and OpenCode open to ${TRUSTED_CIDRS}"
      MODE_RULES="    ip saddr $(nft_set "$TRUSTED_CIDRS") tcp dport $(nft_set "22 ${OPENCODE_PORTS}") accept"
    fi
    ;;

  *)
    echo "ERROR: unknown NETWORK_MODE='${NETWORK_MODE}'. Locking down." >&2
    BANNER="LOCKDOWN — unknown NETWORK_MODE '${NETWORK_MODE}'"
    ;;
esac

write_ruleset() {  # <mode-rules>
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

$1
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
EOF
}

write_ruleset "$MODE_RULES"

# nft -f is atomic, so a rejected file leaves the PREVIOUS ruleset in place —
# which on boot is none at all. Anything malformed in firewall.env lands here
# (a hand-edited IPv6 CIDR, a bad port), so fall back rather than exit.
if ! nft -f "$NFT_CONF"; then
  echo "ERROR: nft rejected the generated ruleset. Locking down." >&2
  BANNER="LOCKDOWN — generated ruleset was invalid"
  write_ruleset "    # Nothing is trusted."
  nft -f "$NFT_CONF"
fi

echo "Firewall applied (${BANNER})."
