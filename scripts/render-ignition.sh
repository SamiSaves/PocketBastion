#!/usr/bin/env bash
# Renders Butane configs to Ignition JSON, one platform at a time:
#
#   base.bu *+ <platform>.bu *+ [features/<feature>.bu ...]
#
# deep-merged with yq, substituted from ./deploy.env, piped to Butane --strict.
#
# Usage:   scripts/render-ignition.sh [local|do|rpi]   (default: local)
# Requires: podman, envsubst (gettext)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Override for a second deployment: DEPLOY_ENV=deploy.rpi.env make ignition-rpi
DEPLOY_ENV="${DEPLOY_ENV:-${REPO_ROOT}/deploy.env}"
BUTANE_DIR="${REPO_ROOT}/config/butane"
BUTANE_IMAGE="quay.io/coreos/butane:release"
YQ_IMAGE="docker.io/mikefarah/yq"
OUT_DIR="${IGNITION_OUT_DIR:-${REPO_ROOT}/config/ignition}"

OPENCODE_UI_PORT=4096
# shellcheck source=lib/constants.sh
. "${REPO_ROOT}/scripts/lib/constants.sh"   # WG_SERVER_IP

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ ! -f "$DEPLOY_ENV" ]]; then
  echo "ERROR: ${DEPLOY_ENV} not found." >&2
  echo "       Copy deploy.env.example to deploy.env and fill it in:" >&2
  echo "         cp deploy.env.example deploy.env" >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "$DEPLOY_ENV"
set +a

if [[ -z "${SSH_AUTHORIZED_KEY:-}" || "${SSH_AUTHORIZED_KEY}" == *REPLACE_ME* ]]; then
  echo "ERROR: SSH_AUTHORIZED_KEY is not set in ${DEPLOY_ENV}." >&2
  echo "       Add your SSH PUBLIC key line, e.g.:" >&2
  echo '         SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... you@host"' >&2
  exit 1
fi
export SSH_AUTHORIZED_KEY
export GIT_USER_NAME="${GIT_USER_NAME:-}"
export GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"

# Baked into Ignition as peer #0 so the tunnel is up before SSH exists.
resolve_bootstrap_peer() {
  : "${WG_BOOTSTRAP_PUBKEY:?set WG_BOOTSTRAP_PUBKEY in deploy.env}"
  : "${WG_BOOTSTRAP_IP:?set WG_BOOTSTRAP_IP in deploy.env}"
  if [[ ! "$WG_BOOTSTRAP_PUBKEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    die "WG_BOOTSTRAP_PUBKEY is not a valid WireGuard key (44-char base64)."
  fi
  if [[ ! "$WG_BOOTSTRAP_IP" =~ ^10\.44\.0\.[0-9]{1,3}$ ]]; then
    die "WG_BOOTSTRAP_IP must be a 10.44.0.x address."
  fi
  export WG_BOOTSTRAP_PUBKEY WG_BOOTSTRAP_IP
}

resolve_trusted_cidrs() {
  local normalised="" cidr
  for cidr in ${TRUSTED_CIDRS:-}; do
    # IPv4 only, deliberately: every service binds 0.0.0.0, so a v6 rule could
    # never match anything but SSH. Accepting one would imply a reachability
    # that does not exist, and is the only way TRUSTED_CIDRS could name a
    # globally routable prefix.
    if [[ "$cidr" == *:* ]]; then
      die "TRUSTED_CIDRS entry '${cidr}' is an IPv6 range, which is not supported.
       Services bind 0.0.0.0, so they are only reachable over IPv4.
       Use the IPv4 range of the same network, e.g. 192.168.1.0/24."
    fi
    if [[ "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
      normalised+="${normalised:+ }${cidr}"
    else
      die "TRUSTED_CIDRS entry '${cidr}' is not an IPv4 CIDR (e.g. 192.168.1.0/24)."
    fi
  done

  if [[ -z "$normalised" ]]; then
    die "NETWORK_MODE=lan requires TRUSTED_CIDRS in ${DEPLOY_ENV}.
       It is the only thing restricting who can reach SSH and the OpenCode UI.
       Example — your home LAN only:
         TRUSTED_CIDRS=\"192.168.1.0/24\""
  fi

  for cidr in $normalised; do
    case "$cidr" in
      0.0.0.0/0)
        die "TRUSTED_CIDRS contains '${cidr}', which trusts every host on the internet.
       If you genuinely want that, you want NETWORK_MODE=wireguard instead."
        ;;
    esac
  done

  TRUSTED_CIDRS="$normalised"
  export TRUSTED_CIDRS
}

# The UI on 4096 is always published; OPENCODE_EXTRA_PORTS adds to it.
resolve_publish() {
  local bind_addr="$1" port
  local ports="$OPENCODE_UI_PORT"

  for port in ${OPENCODE_EXTRA_PORTS:-}; do
    [[ "$port" =~ ^[0-9]+(-[0-9]+)?$ ]] \
      || die "OPENCODE_EXTRA_PORTS entry '$port' must be a port or range (e.g. 8000 or 9000-9010)."
    ports+=" $port"
  done

  OPENCODE_PUBLISH=""
  for port in $ports; do
    OPENCODE_PUBLISH+=$'\n          PublishPort='"${bind_addr}:${port}:${port}"
  done

  OPENCODE_PORTS="$ports"
  export OPENCODE_PUBLISH OPENCODE_PORTS
}

# ── Memory guardrails (all optional; empty = off, for larger hosts) ───────────
_valid_size() { [[ "$1" =~ ^[0-9]+[bkmgtBKMGT]?$ ]]; }

OPENCODE_MEMORY_ARGS=""
if [[ -n "${OPENCODE_MEMORY_MAX:-}" ]]; then
  _valid_size "$OPENCODE_MEMORY_MAX" || die "OPENCODE_MEMORY_MAX '$OPENCODE_MEMORY_MAX' must be a size like 1400m or 2g."
  _mem_args="--memory=${OPENCODE_MEMORY_MAX}"
  if [[ -n "${OPENCODE_MEMORY_SWAP:-}" ]]; then
    _valid_size "$OPENCODE_MEMORY_SWAP" || die "OPENCODE_MEMORY_SWAP '$OPENCODE_MEMORY_SWAP' must be a size like 1900m or 2g."
    _mem_args+=" --memory-swap=${OPENCODE_MEMORY_SWAP}"
  fi
  OPENCODE_MEMORY_ARGS=$'\n          PodmanArgs='"${_mem_args}"
fi
export OPENCODE_MEMORY_ARGS

ZRAM_CONFIG=""
if [[ -n "${ZRAM_SIZE:-}" ]]; then
  ZRAM_CONFIG='[zram0]'
  ZRAM_CONFIG+=$'\n          zram-size = '"${ZRAM_SIZE}"
  ZRAM_CONFIG+=$'\n          compression-algorithm = zstd'
fi
export ZRAM_CONFIG

if [[ -n "${SWAPFILE_SIZE:-}" ]]; then
  _valid_size "$SWAPFILE_SIZE" || die "SWAPFILE_SIZE '$SWAPFILE_SIZE' must be a size like 2g or 512m."
fi
export SWAPFILE_SIZE="${SWAPFILE_SIZE:-}"

# The mode is the same for every platform in one render, so resolve it once.
NETWORK_MODE="${NETWORK_MODE:-wireguard}"
WG_LAYER=""
case "$NETWORK_MODE" in
  wireguard)
    resolve_bootstrap_peer
    resolve_publish "$WG_SERVER_IP"
    TRUSTED_CIDRS=""
    WG_LAYER="/w/features/wireguard.bu"
    ;;
  lan)
    resolve_trusted_cidrs
    # The LAN address is DHCP-assigned and unknown at render time, so bind
    # everywhere and let nftables restrict the source.
    resolve_publish "0.0.0.0"
    ;;
  *) die "NETWORK_MODE='${NETWORK_MODE}' is not valid. Use 'wireguard' or 'lan'." ;;
esac
export NETWORK_MODE TRUSTED_CIDRS

# An explicit whitelist, so shell-looking text in the configs (e.g. "$SIZE" in
# swapfile-setup.sh) survives untouched.
# shellcheck disable=SC2016  # literal ${VAR} names for envsubst, not expansions
SUBST_VARS='${SSH_AUTHORIZED_KEY} ${WG_BOOTSTRAP_PUBKEY} ${WG_BOOTSTRAP_IP}
            ${GIT_USER_NAME} ${GIT_USER_EMAIL}
            ${OPENCODE_PUBLISH} ${OPENCODE_PORTS} ${OPENCODE_MEMORY_ARGS}
            ${NETWORK_MODE} ${TRUSTED_CIDRS}
            ${ZRAM_CONFIG} ${SWAPFILE_SIZE}'

render() {
  local platform="$1" dst="$2"
  if [[ "$platform" == "digitalocean" && "$NETWORK_MODE" == "lan" ]]; then
    die "NETWORK_MODE=lan is refused for DigitalOcean: the droplet is on the
       public internet. Use a separate deploy.env for the LAN box:
         DEPLOY_ENV=deploy.rpi.env make ignition-rpi"
  fi

  echo "Rendering ${platform} [mode=${NETWORK_MODE}] -> $dst"
  mkdir -p "$(dirname "$dst")"
  podman run --rm -v "${BUTANE_DIR}":/w:ro "$YQ_IMAGE" \
      eval-all '. as $i ireduce ({}; . *+ $i)' \
      "/w/base.bu" "/w/${platform}.bu" ${WG_LAYER:+"$WG_LAYER"} \
    | envsubst "$SUBST_VARS" \
    | podman run --rm -i -v "${BUTANE_DIR}":/w:ro "$BUTANE_IMAGE" \
        --pretty --strict --files-dir /w \
    > "$dst"
  echo "OK: $dst"
}

case "${1:-local}" in
  local) render local "${OUT_DIR}/local.ign" ;;
  do|digitalocean) render digitalocean "${OUT_DIR}/digitalocean.ign" ;;
  rpi) render rpi "${OUT_DIR}/rpi.ign" ;;
  *)
    echo "Usage: $0 [local|do|rpi]" >&2
    exit 1
    ;;
esac
