#!/usr/bin/env bash
# Renders Butane configs to Ignition JSON, one platform at a time:
#
#   base.bu *+ <platform>.bu
#
# deep-merged with yq, substituted from ./deploy.env, piped to Butane --strict.
#
# Usage:   scripts/render-ignition.sh [local|do|all]   (default: local)
# Requires: podman, envsubst (gettext)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Override for a second deployment: DEPLOY_ENV=deploy.other.env make ignition-do
DEPLOY_ENV="${DEPLOY_ENV:-${REPO_ROOT}/deploy.env}"
BUTANE_DIR="${REPO_ROOT}/config/butane"
BUTANE_IMAGE="quay.io/coreos/butane:release"
YQ_IMAGE="docker.io/mikefarah/yq"
OUT_DIR="${IGNITION_OUT_DIR:-${REPO_ROOT}/config/ignition}"

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

# ── Extra OpenCode dev-server ports (optional; the UI on 4096 is always published) ─
OPENCODE_EXTRA_PUBLISH=""
for _port in ${OPENCODE_EXTRA_PORTS:-}; do
  [[ "$_port" =~ ^[0-9]+(-[0-9]+)?$ ]] \
    || die "OPENCODE_EXTRA_PORTS entry '$_port' must be a port or range (e.g. 8000 or 9000-9010)."
  OPENCODE_EXTRA_PUBLISH+=$'\n          PublishPort=10.44.0.1:'"${_port}:${_port}"
done
export OPENCODE_EXTRA_PUBLISH

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

resolve_bootstrap_peer

# An explicit whitelist, so shell-looking text in the configs (e.g. "$SIZE" in
# swapfile-setup.sh) survives untouched.
# shellcheck disable=SC2016  # literal ${VAR} names for envsubst, not expansions
SUBST_VARS='${SSH_AUTHORIZED_KEY} ${WG_BOOTSTRAP_PUBKEY} ${WG_BOOTSTRAP_IP}
            ${GIT_USER_NAME} ${GIT_USER_EMAIL}
            ${OPENCODE_EXTRA_PUBLISH} ${OPENCODE_MEMORY_ARGS}
            ${ZRAM_CONFIG} ${SWAPFILE_SIZE}'

render() {
  local platform="$1" dst="$2"
  echo "Rendering ${platform} -> $dst"
  mkdir -p "$(dirname "$dst")"
  podman run --rm -v "${BUTANE_DIR}":/w:ro "$YQ_IMAGE" \
      eval-all '. as $i ireduce ({}; . *+ $i)' \
      "/w/base.bu" "/w/${platform}.bu" \
    | envsubst "$SUBST_VARS" \
    | podman run --rm -i -v "${BUTANE_DIR}":/w:ro "$BUTANE_IMAGE" \
        --pretty --strict --files-dir /w \
    > "$dst"
  echo "OK: $dst"
}

case "${1:-local}" in
  local) render local "${OUT_DIR}/local.ign" ;;
  do|digitalocean) render digitalocean "${OUT_DIR}/digitalocean.ign" ;;
  all)
    render local "${OUT_DIR}/local.ign"
    render digitalocean "${OUT_DIR}/digitalocean.ign"
    ;;
  *)
    echo "Usage: $0 [local|do|all]" >&2
    exit 1
    ;;
esac
