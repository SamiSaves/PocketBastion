#!/usr/bin/env bash
# ssh.sh — SSH into the dev VM over the WireGuard tunnel (mirrors DO).
set -euo pipefail

SSH_USER="${SSH_USER:-core}"
# If the tunnel is down, use the serial console: make local-console.
SERVER_IP="${SERVER_HOST:-10.44.0.1}"

exec ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "${SSH_USER}@${SERVER_IP}"
