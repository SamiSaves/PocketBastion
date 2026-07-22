#!/usr/bin/env bash
# render-ignition.sh — render Butane configs to Ignition JSON.
#
# Usage:
#   scripts/render-ignition.sh [local|do|all]   (default: local)
#
# Inputs come from ./deploy.env; pre-set env vars win (used by test-render.sh):
#   - SSH_AUTHORIZED_KEY   your SSH PUBLIC key, baked into the core user
#   - WG_BOOTSTRAP_PUBKEY  your device's WireGuard PUBLIC key (bootstrap peer)
#   - WG_BOOTSTRAP_IP      that peer's VPN IP (e.g. 10.44.0.2)
#
# Requires: podman, envsubst (gettext package)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_ENV="${REPO_ROOT}/deploy.env"
BUTANE_DIR="${REPO_ROOT}/config/butane"
BUTANE_IMAGE="quay.io/coreos/butane:release"
YQ_IMAGE="docker.io/mikefarah/yq"

# Source ./deploy.env only when a needed var is missing.
require_deploy_env() {
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
}

# ── SSH public key ─────────────────────────────────────────────────────────

if [[ -z "${SSH_AUTHORIZED_KEY:-}" ]]; then
  require_deploy_env
fi
if [[ -z "${SSH_AUTHORIZED_KEY:-}" || "${SSH_AUTHORIZED_KEY}" == *REPLACE_ME* ]]; then
  echo "ERROR: SSH_AUTHORIZED_KEY is not set in ${DEPLOY_ENV}." >&2
  echo "       Add your SSH PUBLIC key line, e.g.:" >&2
  echo '         SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... you@host"' >&2
  exit 1
fi

export SSH_AUTHORIZED_KEY

# ── Git commit identity (optional; empty is fine until you set it) ────────────
export GIT_USER_NAME="${GIT_USER_NAME:-}"
export GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"

# ── Extra OpenCode dev-server ports (optional; 4096/3000-3010/5173-5183 always) ─
OPENCODE_EXTRA_PUBLISH=""
for _port in ${OPENCODE_EXTRA_PORTS:-}; do
  if [[ ! "$_port" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
    echo "ERROR: OPENCODE_EXTRA_PORTS entry '$_port' must be a port or range (e.g. 8000 or 9000-9010)." >&2
    exit 1
  fi
  OPENCODE_EXTRA_PUBLISH+=$'\n          PublishPort=10.44.0.1:'"${_port}:${_port}"
done
export OPENCODE_EXTRA_PUBLISH

# ── Memory guardrails (all optional; empty = off, for larger hosts) ───────────
_valid_size() { [[ "$1" =~ ^[0-9]+[bkmgtBKMGT]?$ ]]; }

OPENCODE_MEMORY_ARGS=""
if [[ -n "${OPENCODE_MEMORY_MAX:-}" ]]; then
  _valid_size "$OPENCODE_MEMORY_MAX" || { echo "ERROR: OPENCODE_MEMORY_MAX '$OPENCODE_MEMORY_MAX' must be a size like 1400m or 2g." >&2; exit 1; }
  _mem_args="--memory=${OPENCODE_MEMORY_MAX}"
  if [[ -n "${OPENCODE_MEMORY_SWAP:-}" ]]; then
    _valid_size "$OPENCODE_MEMORY_SWAP" || { echo "ERROR: OPENCODE_MEMORY_SWAP '$OPENCODE_MEMORY_SWAP' must be a size like 1900m or 2g." >&2; exit 1; }
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
  _valid_size "$SWAPFILE_SIZE" || { echo "ERROR: SWAPFILE_SIZE '$SWAPFILE_SIZE' must be a size like 2g or 512m." >&2; exit 1; }
fi
export SWAPFILE_SIZE="${SWAPFILE_SIZE:-}"

# ── WireGuard bootstrap peer ────────────────────────────────────────────────
# Baked into Ignition as peer #0 so the tunnel is up before SSH exists.
resolve_bootstrap_peer() {
  if [[ -z "${WG_BOOTSTRAP_PUBKEY:-}" || -z "${WG_BOOTSTRAP_IP:-}" ]]; then
    require_deploy_env
  fi
  : "${WG_BOOTSTRAP_PUBKEY:?set WG_BOOTSTRAP_PUBKEY in deploy.env}"
  : "${WG_BOOTSTRAP_IP:?set WG_BOOTSTRAP_IP in deploy.env}"
  if [[ ! "$WG_BOOTSTRAP_PUBKEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "ERROR: WG_BOOTSTRAP_PUBKEY is not a valid WireGuard key (44-char base64)." >&2
    exit 1
  fi
  if [[ ! "$WG_BOOTSTRAP_IP" =~ ^10\.44\.0\.[0-9]{1,3}$ ]]; then
    echo "ERROR: WG_BOOTSTRAP_IP must be a 10.44.0.x address." >&2
    exit 1
  fi
  export WG_BOOTSTRAP_PUBKEY WG_BOOTSTRAP_IP
}

# ── Render one Butane config ─────────────────────────────────────────────────

# Deep-merge base.bu + overlay (arrays append via *+), substitute vars, compile
# to Ignition with Butane --strict.
render_one() {
  local overlay="$1"
  local dst="$2"
  echo "Rendering base.bu + ${overlay} -> $dst"
  mkdir -p "$(dirname "$dst")"
  # shellcheck disable=SC2016  # envsubst needs the literal ${VAR} names
  podman run --rm -v "${BUTANE_DIR}":/w:ro "$YQ_IMAGE" \
      eval-all 'select(fi==0) *+ select(fi==1)' /w/base.bu "/w/${overlay}" \
    | envsubst '${SSH_AUTHORIZED_KEY} ${WG_BOOTSTRAP_PUBKEY} ${WG_BOOTSTRAP_IP} ${GIT_USER_NAME} ${GIT_USER_EMAIL} ${OPENCODE_EXTRA_PUBLISH} ${OPENCODE_MEMORY_ARGS} ${ZRAM_CONFIG} ${SWAPFILE_SIZE}' \
    | podman run --rm -i -v "${BUTANE_DIR}":/w:ro "$BUTANE_IMAGE" \
        --pretty --strict --files-dir /w \
    > "$dst"
  echo "OK: $dst"
}

# ── Select target ────────────────────────────────────────────────────────────

TARGET="${1:-local}"

case "$TARGET" in
  local)
    resolve_bootstrap_peer
    render_one local.bu "${REPO_ROOT}/config/ignition/local.ign"
    ;;
  do|digitalocean)
    resolve_bootstrap_peer
    render_one digitalocean.bu "${REPO_ROOT}/config/ignition/digitalocean.ign"
    ;;
  all)
    resolve_bootstrap_peer
    render_one local.bu "${REPO_ROOT}/config/ignition/local.ign"
    render_one digitalocean.bu "${REPO_ROOT}/config/ignition/digitalocean.ign"
    ;;
  *)
    echo "Usage: $0 [local|do|all]" >&2
    exit 1
    ;;
esac
