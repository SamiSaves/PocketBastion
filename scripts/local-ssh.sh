#!/usr/bin/env bash
# local-ssh.sh — SSH into the local KVM dev VM.
set -euo pipefail

VM_NAME="game-dev-coreos-local"
SSH_USER="${SSH_USER:-core}"

IP=$(./scripts/local-ip.sh)

if [[ -z "$IP" ]]; then
  echo "ERROR: could not determine VM IP. Is the VM running?" >&2
  exit 1
fi

exec ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "${SSH_USER}@${IP}"
