#!/usr/bin/env bash
# render-ignition.sh — render Butane configs to Ignition JSON.
#
# Usage:
#   scripts/render-ignition.sh [local|do|all]   (default: local)
#
# SSH key source (first found wins):
#   1. secrets/ssh_authorized_keys   — one public key per line; first line used
#   2. ~/.ssh/id_ed25519.pub
#
# Each environment config is a small overlay (local.bu / digitalocean.bu) that
# is deep-merged on top of the shared base.bu before being handed to Butane.
#
# Requires: podman, envsubst (gettext package)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="${REPO_ROOT}/secrets"
BUTANE_DIR="${REPO_ROOT}/config/butane"
BUTANE_IMAGE="quay.io/coreos/butane:release"
YQ_IMAGE="docker.io/mikefarah/yq"

# ── Resolve SSH public key (honor a pre-set SSH_AUTHORIZED_KEY, e.g. tests) ───

if [[ -z "${SSH_AUTHORIZED_KEY:-}" ]]; then
  if [[ -f "${SECRETS}/ssh_authorized_keys" ]]; then
    SSH_AUTHORIZED_KEY="$(grep -v '^\s*#' "${SECRETS}/ssh_authorized_keys" | grep -v '^\s*$' | head -n1)"
    echo "Using SSH key from: secrets/ssh_authorized_keys"
  elif [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
    SSH_AUTHORIZED_KEY="$(cat "${HOME}/.ssh/id_ed25519.pub")"
    echo "Using SSH key from: ~/.ssh/id_ed25519.pub"
  else
    echo "ERROR: No SSH public key found." >&2
    echo "Create secrets/ssh_authorized_keys with your public key, or ensure ~/.ssh/id_ed25519.pub exists." >&2
    exit 1
  fi
fi

if [[ -z "${SSH_AUTHORIZED_KEY}" ]]; then
  echo "ERROR: SSH key resolved to empty string." >&2
  exit 1
fi

export SSH_AUTHORIZED_KEY

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
    | envsubst '${SSH_AUTHORIZED_KEY}' \
    | podman run --rm -i -v "${BUTANE_DIR}":/w:ro "$BUTANE_IMAGE" \
        --pretty --strict --files-dir /w \
    > "$dst"
  echo "OK: $dst"
}

# ── Select target ────────────────────────────────────────────────────────────

TARGET="${1:-local}"

case "$TARGET" in
  local)
    render_one local.bu "${REPO_ROOT}/config/ignition/local.ign"
    ;;
  do|digitalocean)
    render_one digitalocean.bu "${REPO_ROOT}/config/ignition/digitalocean.ign"
    ;;
  all)
    render_one local.bu "${REPO_ROOT}/config/ignition/local.ign"
    render_one digitalocean.bu "${REPO_ROOT}/config/ignition/digitalocean.ign"
    ;;
  *)
    echo "Usage: $0 [local|do|all]" >&2
    exit 1
    ;;
esac
