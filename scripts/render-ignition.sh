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
# The server's address inside the tunnel. Must match the `Address =` line in
# config/butane/files/usr/local/sbin/wg-setup.sh, which is shipped verbatim.
WG_SERVER_IP=10.44.0.1

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$DEPLOY_ENV" ]] || die "${DEPLOY_ENV} not found.
       Copy deploy.env.example to deploy.env and fill it in:
         cp deploy.env.example deploy.env"
set -a
# shellcheck source=/dev/null
source "$DEPLOY_ENV"
set +a

if [[ -z "${SSH_AUTHORIZED_KEY:-}" || "${SSH_AUTHORIZED_KEY}" == *REPLACE_ME* ]]; then
  die "SSH_AUTHORIZED_KEY is not set in ${DEPLOY_ENV}.
       Add your SSH PUBLIC key line, e.g.:
         SSH_AUTHORIZED_KEY=\"ssh-ed25519 AAAA... you@host\""
fi
export SSH_AUTHORIZED_KEY
export GIT_USER_NAME="${GIT_USER_NAME:-}"
export GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"

# Baked into Ignition as peer #0 so the tunnel is up before SSH exists.
resolve_bootstrap_peer() {
  : "${WG_BOOTSTRAP_PUBKEY:?set WG_BOOTSTRAP_PUBKEY in deploy.env}"
  : "${WG_BOOTSTRAP_IP:?set WG_BOOTSTRAP_IP in deploy.env}"
  export WG_BOOTSTRAP_PUBKEY WG_BOOTSTRAP_IP
}

# The shape of each CIDR is deliberately NOT checked here: nft rejects anything
# malformed and firewall-setup.sh then applies its lockdown ruleset. Only the
# two values nft would accept happily are worth catching at render time.
resolve_trusted_cidrs() {
  local cidr
  # shellcheck disable=SC2086  # deliberate split, also normalises whitespace
  set -- ${TRUSTED_CIDRS:-}

  (($#)) || die "NETWORK_MODE=lan requires TRUSTED_CIDRS in ${DEPLOY_ENV}.
       It is the only thing restricting who can reach SSH and the OpenCode UI.
       Example — your home LAN only:
         TRUSTED_CIDRS=\"192.168.1.0/24\""

  for cidr in "$@"; do
    [[ "$cidr" != 0.0.0.0/0 ]] \
      || die "TRUSTED_CIDRS contains '${cidr}', which trusts every host on the internet.
       If you genuinely want that, you want NETWORK_MODE=wireguard instead."
  done

  TRUSTED_CIDRS="$*"
  export TRUSTED_CIDRS
}

# The UI on 4096 is always published; OPENCODE_EXTRA_PORTS adds to it.
resolve_publish() {
  local bind_addr="$1" port
  # shellcheck disable=SC2086  # deliberate split, also normalises whitespace
  set -- "$OPENCODE_UI_PORT" ${OPENCODE_EXTRA_PORTS:-}

  OPENCODE_PUBLISH=""
  for port in "$@"; do
    OPENCODE_PUBLISH+=$'\n          PublishPort='"${bind_addr}:${port}:${port}"
  done

  OPENCODE_PORTS="$*"
  export OPENCODE_PUBLISH OPENCODE_PORTS
}

# ── Memory guardrails (all optional; empty = off, for larger hosts) ───────────
# Sizes are passed through as written: podman, systemd and zram-generator each
# reject a malformed one with a better message than this script could give.
OPENCODE_MEMORY_ARGS=""
if [[ -n "${OPENCODE_MEMORY_MAX:-}" ]]; then
  _mem_args="--memory=${OPENCODE_MEMORY_MAX}"
  if [[ -n "${OPENCODE_MEMORY_SWAP:-}" ]]; then
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
