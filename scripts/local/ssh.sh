#!/usr/bin/env bash
# ssh.sh — SSH into the dev VM over the WireGuard tunnel (mirrors DO).
set -euo pipefail

SSH_USER="${SSH_USER:-core}"
# If the tunnel is down, use the serial console: make local-console.
. "$(dirname "$0")/../lib/server-host.sh"
SERVER_IP="$(server_host)"

exec ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "${SSH_USER}@${SERVER_IP}"
