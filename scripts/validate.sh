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
echo "=== systemd-analyze verify ==="
if check systemd-analyze; then
  UNIT_DIR="$ROOT/config/butane/files/systemd"
  # Verify base + one overlay at a time so cross-unit references (e.g.
  # var-mnt-state.mount) resolve. The two overlays each define their own
  # var-mnt-state.mount, so they cannot be loaded together.
  #
  # We only fail on unit-syntax errors (unknown directives/sections). Missing
  # ExecStart binaries and missing referenced units are expected here because
  # those live on the VM, not this laptop, so that noise is ignored.
  for env in local digitalocean; do
    mapfile -t units < <(find "$UNIT_DIR/base" "$UNIT_DIR/$env" -type f \
      \( -name '*.service' -o -name '*.mount' \))
    out="$(systemd-analyze verify "${units[@]}" 2>&1 || true)"
    bad="$(printf '%s\n' "$out" | grep -E \
      'Unknown key name|Unknown section|Unknown lvalue|Failed to parse|assignment outside of section' || true)"
    if [[ -n "$bad" ]]; then
      echo "  [$env] unit syntax errors:"
      printf '%s\n' "$bad" | sed 's/^/    /'
      ERRORS=$((ERRORS + 1))
    else
      echo "  [$env] OK"
    fi
  done
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
