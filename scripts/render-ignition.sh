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

OPENCODE_UI_PORT=4096

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

# The shape of each CIDR is deliberately NOT checked here: nft rejects anything
# malformed and firewall-setup.sh then applies its lockdown ruleset. Only the
# values nft would accept happily are worth catching at render time.
resolve_trusted_cidrs() {
  local cidr
  # shellcheck disable=SC2086  # deliberate split, also normalises whitespace
  set -- ${TRUSTED_CIDRS:-}

  (($#)) || die "TRUSTED_CIDRS is not set in ${DEPLOY_ENV}.
       It is the only thing restricting who can reach SSH and the OpenCode UI.
       Example — your home LAN only:
         TRUSTED_CIDRS=\"192.168.1.0/24\""

  for cidr in "$@"; do
    # 0/0 is the shorthand form; nft accepts it just as happily as 0.0.0.0/0.
    [[ "$cidr" != 0.0.0.0/0 && "$cidr" != 0/0 ]] \
      || die "TRUSTED_CIDRS contains '${cidr}', which trusts every host that can
       route to this box. This box has no VPN of its own and the UI is plain
       HTTP; name the networks you actually trust."
  done

  TRUSTED_CIDRS="$*"
  export TRUSTED_CIDRS
}

# The UI on 4096 is always published; OPENCODE_EXTRA_PORTS adds to it.
# The LAN address is DHCP-assigned and unknown at render time, so bind
# everywhere and let nftables restrict the source.
resolve_publish() {
  local port
  # shellcheck disable=SC2086  # deliberate split, also normalises whitespace
  set -- "$OPENCODE_UI_PORT" ${OPENCODE_EXTRA_PORTS:-}

  OPENCODE_PUBLISH=""
  for port in "$@"; do
    OPENCODE_PUBLISH+=$'\n          PublishPort='"0.0.0.0:${port}:${port}"
  done

  OPENCODE_PORTS="$*"
  export OPENCODE_PUBLISH OPENCODE_PORTS
}

# ── Memory guardrails (all optional; empty = off, for larger hosts) ───────────
# Sizes are passed through as written: podman, systemd and zram-generator each
# reject a malformed one with a better message than this script could give.
OPENCODE_MEMORY_ARGS=""
# podman rejects --memory-swap without -m, so the swap cap is nested under the
# max. Without this, setting only the swap would render no cap at all, silently.
[[ -z "${OPENCODE_MEMORY_SWAP:-}" || -n "${OPENCODE_MEMORY_MAX:-}" ]] \
  || die "OPENCODE_MEMORY_SWAP is set without OPENCODE_MEMORY_MAX in ${DEPLOY_ENV}.
       podman needs the memory cap to apply a swap cap, so the container would
       end up with neither. Set both, or leave both empty."
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

resolve_trusted_cidrs
resolve_publish

# An explicit whitelist, not a blanket envsubst: a blanket run would also eat
# any literal $-text this config grows later (crypt hashes, shell fragments,
# systemd specifiers) and do it silently.
# shellcheck disable=SC2016  # literal ${VAR} names for envsubst, not expansions
SUBST_VARS='${SSH_AUTHORIZED_KEY} ${GIT_USER_NAME} ${GIT_USER_EMAIL}
            ${OPENCODE_PUBLISH} ${OPENCODE_PORTS} ${OPENCODE_MEMORY_ARGS}
            ${TRUSTED_CIDRS} ${ZRAM_CONFIG}'

DST="${OUT_DIR}/pocketbastion.ign"
echo "Rendering -> $DST"
mkdir -p "$OUT_DIR"
envsubst "$SUBST_VARS" < "${BUTANE_DIR}/pocketbastion.bu" \
  | podman run --rm -i -v "${BUTANE_DIR}":/w:ro "$BUTANE_IMAGE" \
      --pretty --strict --files-dir /w \
  > "$DST"
echo "OK: $DST"
