#!/usr/bin/env bash
# github-test-access.sh — Verify the VM authenticates to GitHub with the deploy
# key by running `ssh -T git@github.com` on the VM.
#
# Usage:
#   make github-test-access
set -euo pipefail

# Managed over the WireGuard tunnel — 10.44.0.1 on both local and DO. Override
# SERVER_IP for the one-time local bootstrap: SERVER_IP="$(scripts/local/ip.sh)".
VM_IP="${SERVER_IP:-10.44.0.1}"

# GitHub exits 1 on an auth-only connection ("You've successfully
# authenticated, but GitHub does not provide shell access."), so match the
# banner instead of trusting the exit code.
OUT=$(ssh -o StrictHostKeyChecking=no "core@${VM_IP}" \
  'ssh -T git@github.com 2>&1' || true)

echo "$OUT"
if grep -q 'successfully authenticated' <<<"$OUT"; then
  echo "PASS: GitHub deploy key authenticates."
else
  echo "FAIL: GitHub auth did not succeed. Is the public key added to the repo?" >&2
  exit 1
fi
