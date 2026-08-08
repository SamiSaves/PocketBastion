#!/usr/bin/env bash
# ssh.sh — SSH into the mock VM over the WireGuard tunnel.
#
# In lan mode there is no tunnel; use the libvirt address instead:
#   SERVER_HOST="$(scripts/local/ip.sh)" make local-ssh
set -euo pipefail

SSH_USER="${SSH_USER:-core}"
# If the tunnel is down, use the serial console: make local-console.
SERVER_IP="${SERVER_HOST:-10.44.0.1}"

exec ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "${SSH_USER}@${SERVER_IP}"
