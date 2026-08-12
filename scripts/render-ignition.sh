#!/usr/bin/env bash
# Renders config/butane/pocketbastion.bu to Ignition JSON: substituted from
# ./deploy.env, piped to Butane --strict.
#
# Usage:   scripts/render-ignition.sh
# Requires: podman, envsubst (gettext)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Override for a second box: DEPLOY_ENV=deploy.vm.env make ignition
DEPLOY_ENV="${DEPLOY_ENV:-${REPO_ROOT}/deploy.env}"
BUTANE_DIR="${REPO_ROOT}/config/butane"
BUTANE_IMAGE="quay.io/coreos/butane:release"
OUT_DIR="${IGNITION_OUT_DIR:-${REPO_ROOT}/config/ignition}"

ORCA_UI_PORT=6768

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

# The shape of each CIDR is deliberately NOT checked here: nft rejects anything
# malformed and firewall-setup.sh then applies its lockdown ruleset. Only the
# values nft would accept happily are worth catching at render time.
resolve_trusted_cidrs() {
  local cidr
  # shellcheck disable=SC2086  # deliberate split, also normalises whitespace
  set -- ${TRUSTED_CIDRS:-}

  (($#)) || die "TRUSTED_CIDRS is not set in ${DEPLOY_ENV}.
       It is the only thing restricting who can reach SSH and the Orca UI.
       Example — your home LAN only:
         TRUSTED_CIDRS=\"192.168.1.0/24\""

  for cidr in "$@"; do
    # 0/0 is the shorthand form; nft accepts it just as happily as 0.0.0.0/0.
    [[ "$cidr" != 0.0.0.0/0 && "$cidr" != 0/0 ]] \
      || die "TRUSTED_CIDRS contains '${cidr}', which trusts every host that can
       route to this box. This box has no VPN of its own, so the network it
       sits on is the whole boundary; name the networks you actually trust."
  done

  TRUSTED_CIDRS="$*"
  export TRUSTED_CIDRS
}

# The UI on 6768 is always published; ORCA_EXTRA_PORTS adds to it.
# The LAN address is DHCP-assigned and unknown at render time, so bind
# everywhere and let nftables restrict the source.
resolve_publish() {
  local port
  # shellcheck disable=SC2086  # deliberate split, also normalises whitespace
  set -- "$ORCA_UI_PORT" ${ORCA_EXTRA_PORTS:-}

  ORCA_PUBLISH=""
  for port in "$@"; do
    ORCA_PUBLISH+=$'\n          PublishPort='"0.0.0.0:${port}:${port}"
  done

  ORCA_PORTS="$*"
  export ORCA_PUBLISH ORCA_PORTS
}

# ── Admin UI (docs/admin-ui.md) ───────────────────────────────────────────────
# Understands the "5173-5180" range form ORCA_EXTRA_PORTS accepts, so a
# collision *inside* a range is caught too, not just an exact match.
port_in_set() {  # <port> <port-or-range>...
  local p="$1" item lo hi
  shift
  for item in "$@"; do
    if [[ "$item" == *-* ]]; then
      lo="${item%%-*}"
      hi="${item##*-}"
      if ((p >= lo && p <= hi)); then return 0; fi
    elif [[ "$p" == "$item" ]]; then
      return 0
    fi
  done
  return 1
}

# Runs after resolve_publish: the collision check needs the final port list.
resolve_admin() {
  local re='^scrypt:[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+$'

  [[ -n "${ADMIN_PASSWORD_HASH:-}" && "$ADMIN_PASSWORD_HASH" != *REPLACE_ME* ]] \
    || die "ADMIN_PASSWORD_HASH is not set in ${DEPLOY_ENV}.
       It is the initial admin UI password. Generate one:
         make admin-hash"
  [[ "$ADMIN_PASSWORD_HASH" =~ $re ]] \
    || die "ADMIN_PASSWORD_HASH is not a hash from 'make admin-hash'.
       Expected scrypt:<salt>:<hash>."

  [[ "${ADMIN_PORT:-}" =~ ^[0-9]+$ ]] \
    || die "ADMIN_PORT is not set to a number in ${DEPLOY_ENV}, e.g.:
         ADMIN_PORT=8080"
  ((ADMIN_PORT > 1024 && ADMIN_PORT < 65536)) \
    || die "ADMIN_PORT=${ADMIN_PORT} is out of range. Use 1025-65535 — below 1024
       the admin UI would need CAP_NET_BIND_SERVICE to bind at all."

  # Without this the box boots fine and the admin UI silently loses the port to
  # a dev server, which presents as "my dev server is the admin page".
  # shellcheck disable=SC2086  # deliberate split of the port list
  if port_in_set "$ADMIN_PORT" 22 $ORCA_PORTS; then
    die "ADMIN_PORT=${ADMIN_PORT} collides with SSH or a published Orca port
       (22 ${ORCA_PORTS}). Pick another."
  fi

  export ADMIN_PORT ADMIN_PASSWORD_HASH
}

# ── Memory guardrails (all optional; empty = off, for larger hosts) ───────────
# Sizes are passed through as written: podman, systemd and zram-generator each
# reject a malformed one with a better message than this script could give.
ORCA_MEMORY_ARGS=""
# podman rejects --memory-swap without -m, so the swap cap is nested under the
# max. Without this, setting only the swap would render no cap at all, silently.
[[ -z "${ORCA_MEMORY_SWAP:-}" || -n "${ORCA_MEMORY_MAX:-}" ]] \
  || die "ORCA_MEMORY_SWAP is set without ORCA_MEMORY_MAX in ${DEPLOY_ENV}.
       podman needs the memory cap to apply a swap cap, so the container would
       end up with neither. Set both, or leave both empty."
if [[ -n "${ORCA_MEMORY_MAX:-}" ]]; then
  _mem_args="--memory=${ORCA_MEMORY_MAX}"
  if [[ -n "${ORCA_MEMORY_SWAP:-}" ]]; then
    _mem_args+=" --memory-swap=${ORCA_MEMORY_SWAP}"
  fi
  ORCA_MEMORY_ARGS=$'\n          PodmanArgs='"${_mem_args}"
fi
export ORCA_MEMORY_ARGS

ZRAM_CONFIG=""
if [[ -n "${ZRAM_SIZE:-}" ]]; then
  ZRAM_CONFIG='[zram0]'
  ZRAM_CONFIG+=$'\n          zram-size = '"${ZRAM_SIZE}"
  ZRAM_CONFIG+=$'\n          compression-algorithm = zstd'
fi
export ZRAM_CONFIG

resolve_trusted_cidrs
resolve_publish
resolve_admin

# An explicit whitelist, not a blanket envsubst: a blanket run would also eat
# any literal $-text this config grows later (crypt hashes, shell fragments,
# systemd specifiers) and do it silently.
# shellcheck disable=SC2016  # literal ${VAR} names for envsubst, not expansions
SUBST_VARS='${SSH_AUTHORIZED_KEY}
            ${ORCA_PUBLISH} ${ORCA_PORTS} ${ORCA_MEMORY_ARGS}
            ${TRUSTED_CIDRS} ${ZRAM_CONFIG}
            ${ADMIN_PORT} ${ADMIN_PASSWORD_HASH}'

# Butane resolves `contents.local` against one --files-dir, and the built admin
# UI is a gitignored artifact rather than part of the source tree. Stage a copy
# of both instead of writing build output into config/butane/.
UI_DIST="${REPO_ROOT}/ui/dist"
[[ -f "${UI_DIST}/index.html" && -f "${UI_DIST}/login.html" ]] \
  || die "the admin UI is not built (${UI_DIST}). Build it first:
         make ui"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "${BUTANE_DIR}/." "$STAGE/"
mkdir -p "${STAGE}/files/ui"
cp "${UI_DIST}"/*.html "${STAGE}/files/ui/"

DST="${OUT_DIR}/pocketbastion.ign"
echo "Rendering -> $DST"
mkdir -p "$OUT_DIR"
envsubst "$SUBST_VARS" < "${BUTANE_DIR}/pocketbastion.bu" \
  | podman run --rm -i -v "${STAGE}":/w:ro "$BUTANE_IMAGE" \
      --pretty --strict --files-dir /w \
  > "$DST"
echo "OK: $DST ($(wc -c < "$DST") bytes)"
