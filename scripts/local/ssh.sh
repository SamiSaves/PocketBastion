#!/usr/bin/env bash
# ssh.sh — SSH into the mock VM on the libvirt network.
#
# The address is DHCP-assigned, so it is looked up per call — deliberately NOT
# from SERVER_HOST, which points at the real box. If SSH does not answer, use
# the serial console instead: make local-console.
#
# Host keys are thrown away here, unlike the repo-* scripts: the mock is
# reflashed constantly and shares libvirt's DHCP range with every other VM.
set -euo pipefail

SSH_USER="${SSH_USER:-core}"
SERVER_IP="$("$(dirname "$0")/ip.sh")"

exec ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "${SSH_USER}@${SERVER_IP}"
