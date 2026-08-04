#!/usr/bin/env bash
# ExecStartPre on opencode.container, wired in only when NETWORK_MODE=lan (see
# the 20-lan-guard.conf dropin). In lan mode the UI is plaintext HTTP on the
# trusted networks, so this password is the only credential in front of an agent
# with a shell. It is a real secret on the state disk, so it cannot be validated
# at render time.
#
# Greps rather than sources: this file is user-editable and holds API keys.
set -uo pipefail

ENV_FILE="${1:-/mnt/state/secrets/opencode.env}"
MIN_LENGTH=12

fail() {
  echo "ERROR: refusing to start OpenCode. $1" >&2
  echo "NETWORK_MODE=lan serves the UI over plain HTTP, so ${ENV_FILE} must set" >&2
  echo "OPENCODE_SERVER_PASSWORD to ${MIN_LENGTH}+ characters. See docs/raspberry-pi.md." >&2
  exit 1
}

[[ -r "$ENV_FILE" ]] || fail "${ENV_FILE} is missing or unreadable."

value="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?OPENCODE_SERVER_PASSWORD=//p' \
           "$ENV_FILE" | tail -n1)"
value="${value%$'\r'}"
value="${value#\"}"; value="${value%\"}"
value="${value#\'}"; value="${value%\'}"

[[ -n "$value" ]] || fail "OPENCODE_SERVER_PASSWORD is unset or empty in ${ENV_FILE}."
(( ${#value} >= MIN_LENGTH )) \
  || fail "OPENCODE_SERVER_PASSWORD is only ${#value} characters; use at least ${MIN_LENGTH}."

echo "OpenCode server password is set (${#value} characters)."
