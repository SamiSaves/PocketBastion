#!/usr/bin/env bash
# github-test-access.sh — Verify the VM authenticates to GitHub with the deploy
# key by running `ssh -T git@github.com` on the VM.
#
# Usage:
#   make github-test-access
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM_IP="$("${REPO_ROOT}/scripts/local/ip.sh")"

if [[ -z "$VM_IP" ]]; then
  echo "ERROR: Could not determine VM IP. Is the VM running?" >&2
  exit 1
fi

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
