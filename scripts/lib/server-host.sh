#!/usr/bin/env bash
# Resolves the host the management scripts should talk to. Source it, then call
# `server_host`. Precedence: the SERVER_HOST environment variable, then
# deploy.env, then the WireGuard address.

server_host() {
  local deploy_env="${BASH_SOURCE[0]%/*}/../../deploy.env"
  if [[ -z "${SERVER_HOST:-}" && -f "$deploy_env" ]]; then
    # Subshell so deploy.env cannot leak its other variables into the caller.
    # shellcheck source=/dev/null
    SERVER_HOST="$(. "$deploy_env" >/dev/null 2>&1; printf '%s' "${SERVER_HOST:-}")"
  fi
  # Must match wg-setup.sh's `Address = 10.44.0.1/24`. Only correct in wireguard
  # mode; lan mode has no fixed address, so it must set SERVER_HOST.
  printf '%s\n' "${SERVER_HOST:-10.44.0.1}"
}
