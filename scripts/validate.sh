#!/usr/bin/env bash
# validate.sh — run all available static checks on configs and scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

check() {
  if command -v "$1" &>/dev/null; then
    return 0
  else
    echo "SKIP: $1 not installed"
    return 1
  fi
}

echo "=== shellcheck ==="
if check shellcheck; then
  while IFS= read -r -d '' script; do
    echo "  checking $script"
    shellcheck -e SC1091 "$script" || ERRORS=$((ERRORS + 1))
  done < <(find "$ROOT/scripts" "$ROOT/config/butane/files" -name "*.sh" -print0)
fi

echo ""
echo "=== butane merge + render + per-env assertions ==="
if check podman; then
  if bash "$ROOT/scripts/test-render.sh"; then
    echo "    OK"
  else
    echo "    FAIL"; ERRORS=$((ERRORS + 1))
  fi
fi

echo ""
if [[ "$ERRORS" -eq 0 ]]; then
  echo "All checks passed."
else
  echo "ERRORS: $ERRORS check(s) failed." >&2
  exit 1
fi
