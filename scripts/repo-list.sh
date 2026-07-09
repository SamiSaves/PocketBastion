#!/usr/bin/env bash
# repo-list.sh — list the repos the VM has git access to.
#
# Usage:
#   make repo-list
set -euo pipefail

VM_IP="${SERVER_IP:-10.44.0.1}"

ssh -o StrictHostKeyChecking=no "core@${VM_IP}" 'bash -s' <<'REMOTE'
set -euo pipefail
SECRETS=/mnt/state/secrets/git
shopt -s nullglob
metas=("$SECRETS"/*.meta)
if [[ ${#metas[@]} -eq 0 ]]; then
  echo "No repositories configured."
  exit 0
fi
printf '%-40s %-9s %s\n' NAME VERIFIED URL
for m in "${metas[@]}"; do
  url= verified=
  # shellcheck disable=SC1090
  . "$m"
  printf '%-40s %-9s %s\n' "$(basename "$m" .meta)" "$verified" "$url"
done
REMOTE
