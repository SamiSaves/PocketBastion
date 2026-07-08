#!/usr/bin/env bash
# render-ignition.sh — render Butane configs to Ignition JSON.
#
# Usage:
#   scripts/render-ignition.sh [local|do|all]   (default: local)
#
# All inputs come from ./deploy.env (copied from deploy.env.example):
#   - SSH_AUTHORIZED_KEY   your SSH PUBLIC key, baked into the core user
#   - WG_BOOTSTRAP_PUBKEY  your device's WireGuard PUBLIC key (bootstrap peer)
#   - WG_BOOTSTRAP_IP      that peer's VPN IP (e.g. 10.44.0.2)
# Values already present in the environment (e.g. set by test-render.sh) win and
# are not overwritten by deploy.env.
#
# Each environment config is a small overlay (local.bu / digitalocean.bu) that
# is deep-merged on top of the shared base.bu before being handed to Butane.
#
# Requires: podman, envsubst (gettext package)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_ENV="${REPO_ROOT}/deploy.env"
BUTANE_DIR="${REPO_ROOT}/config/butane"
BUTANE_IMAGE="quay.io/coreos/butane:release"
YQ_IMAGE="docker.io/mikefarah/yq"

# Source ./deploy.env once (only when something we need is missing). Pre-set env
# vars take precedence, so this is a no-op when the caller already provided them.
require_deploy_env() {
  if [[ ! -f "$DEPLOY_ENV" ]]; then
    echo "ERROR: ${DEPLOY_ENV} not found." >&2
    echo "       Copy deploy.env.example to deploy.env and fill it in:" >&2
    echo "         cp deploy.env.example deploy.env" >&2
    exit 1
  fi
  set -a; source "$DEPLOY_ENV"; set +a
}

# ── Resolve SSH public key from deploy.env (pre-set env wins, e.g. tests) ─────

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

# ── Resolve WireGuard bootstrap peer ─────────────────────────────────────────
# Baked into Ignition as peer #0 so the tunnel is up before SSH exists. Honors
# pre-set env vars (used by test-render); else reads ./deploy.env.
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

# render_one <overlay-filename> <dst>
# Deep-merges base.bu + overlay (arrays append via *+), substitutes the SSH key,
# then compiles to Ignition JSON with Butane --strict.
render_one() {
  local overlay="$1"
  local dst="$2"
  echo "Rendering base.bu + ${overlay} -> $dst"
  mkdir -p "$(dirname "$dst")"
  podman run --rm -v "${BUTANE_DIR}":/w:ro "$YQ_IMAGE" \
      eval-all 'select(fi==0) *+ select(fi==1)' /w/base.bu "/w/${overlay}" \
    | envsubst '${SSH_AUTHORIZED_KEY} ${WG_BOOTSTRAP_PUBKEY} ${WG_BOOTSTRAP_IP} ${GIT_USER_NAME} ${GIT_USER_EMAIL}' \
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
