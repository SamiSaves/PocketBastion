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
# Requires: podman, envsubst (gettext package)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="${REPO_ROOT}/secrets"
BUTANE_IMAGE="quay.io/coreos/butane:release"

# ── Resolve SSH public key ───────────────────────────────────────────────────

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

if [[ -z "${SSH_AUTHORIZED_KEY}" ]]; then
  echo "ERROR: SSH key resolved to empty string." >&2
  exit 1
fi

export SSH_AUTHORIZED_KEY

# ── Render one Butane config ─────────────────────────────────────────────────

render_one() {
  local src="$1"
  local dst="$2"
  echo "Rendering $(basename "$src") -> $dst"
  envsubst '${SSH_AUTHORIZED_KEY}' < "$src" \
    | podman run --rm -i "$BUTANE_IMAGE" --pretty --strict \
    > "$dst"
  echo "OK: $dst"
}

# ── Select target ────────────────────────────────────────────────────────────

TARGET="${1:-local}"

case "$TARGET" in
  local)
    render_one "${REPO_ROOT}/config/butane/local.bu" \
               "${REPO_ROOT}/config/ignition/local.ign"
    ;;
  do|digitalocean)
    render_one "${REPO_ROOT}/config/butane/digitalocean.bu" \
               "${REPO_ROOT}/config/ignition/digitalocean.ign"
    ;;
  all)
    render_one "${REPO_ROOT}/config/butane/local.bu" \
               "${REPO_ROOT}/config/ignition/local.ign"
    render_one "${REPO_ROOT}/config/butane/digitalocean.bu" \
               "${REPO_ROOT}/config/ignition/digitalocean.ign"
    ;;
  *)
    echo "Usage: $0 [local|do|all]" >&2
    exit 1
    ;;
esac
