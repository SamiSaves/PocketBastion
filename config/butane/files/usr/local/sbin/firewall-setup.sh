#!/bin/bash
# Renders and applies the nftables ruleset, reading TRUSTED_CIDRS and the
# published ports from /etc/pocketbastion/firewall.env (written by
# scripts/render-ignition.sh).
#
# This box runs no VPN of its own: TRUSTED_CIDRS is the whole access-control
# boundary in front of an AI agent with a shell.
#
# Fails CLOSED: no TRUSTED_CIDRS, or a ruleset nft rejects, both end in a
# lockdown ruleset. Fedora CoreOS ships no default ruleset, so exiting non-zero
# here would leave the box wide open.
set -euo pipefail

FW_ENV=/etc/pocketbastion/firewall.env
NFT_CONF=/etc/nftables/pocketbastion.nft

TRUSTED_CIDRS=""
OPENCODE_PORTS=""

if [[ -r "$FW_ENV" ]]; then
  # shellcheck source=/dev/null
  source "$FW_ENV"
else
  echo "WARNING: $FW_ENV missing. Locking down." >&2
fi

install -d -m 0755 /etc/nftables

# "a  b " -> "{ a,b }". Word-splits rather than "${s// /,}" so stray whitespace
# cannot produce a trailing comma: nft would reject the file, and on boot that
# leaves the box unfiltered.
nft_set() {
  # shellcheck disable=SC2086  # deliberate split
  set -- $1
  local IFS=,
  printf '{ %s }' "$*"
}

# The default is the lockdown ruleset: nothing beyond lo, established and ICMP
# is accepted. Every error path below falls through to it.
TRUST_RULE="    # Nothing is trusted."
BANNER="LOCKDOWN — no TRUSTED_CIDRS"

if [[ -z "${TRUSTED_CIDRS// /}" ]]; then
  echo "ERROR: no TRUSTED_CIDRS in ${FW_ENV}. Locking down." >&2
else
  BANNER="SSH and OpenCode open to ${TRUSTED_CIDRS}"
  TRUST_RULE="    ip saddr $(nft_set "$TRUSTED_CIDRS") tcp dport $(nft_set "22 ${OPENCODE_PORTS}") accept"
fi

write_ruleset() {  # <trust-rule>
  cat > "$NFT_CONF" << EOF
#!/usr/sbin/nft -f
# Rendered by firewall-setup.sh — do not edit by hand.
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

write_ruleset "$TRUST_RULE"

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
