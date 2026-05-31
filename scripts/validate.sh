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
    shellcheck "$script" || ERRORS=$((ERRORS + 1))
  done < <(find "$ROOT/scripts" -name "*.sh" -print0)
fi

echo ""
echo "=== butane --strict (dry-run, requires podman) ==="
if check podman; then
  for bu in "$ROOT/config/butane"/*.bu; do
    echo "  checking $(basename "$bu")"
    podman run --rm -i quay.io/coreos/butane:release \
      --pretty --strict < "$bu" > /dev/null \
      && echo "    OK" \
      || { echo "    FAIL: $bu"; ERRORS=$((ERRORS + 1)); }
  done
fi

echo ""
if [[ "$ERRORS" -eq 0 ]]; then
  echo "All checks passed."
else
  echo "ERRORS: $ERRORS check(s) failed." >&2
  exit 1
fi
