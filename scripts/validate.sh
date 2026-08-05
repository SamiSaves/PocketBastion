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
  # digitalocean is the only platform with hand-written units: local and rpi
  # declare their state disk under storage.filesystems and let Butane generate
  # the mount unit (see digitalocean.bu for why DO cannot).
  #
  # Butane-generated units are not checked here — they are checked in the
  # rendered Ignition by test-render.sh instead.
  #
  # Only unit-syntax errors count. Missing ExecStart binaries and missing
  # referenced units are expected, since those live on the server.
  # Every hand-written unit in one pass: no two share a name any more, so they
  # can all be loaded together.
  mapfile -t units < <(find "$UNIT_DIR" -type f \
    \( -name '*.service' -o -name '*.mount' -o -name '*.conf' \))
  out="$(systemd-analyze verify "${units[@]}" 2>&1 || true)"
  bad="$(printf '%s\n' "$out" | grep -E \
    'Unknown key name|Unknown section|Unknown lvalue|Failed to parse|assignment outside of section' || true)"
  if [[ -n "$bad" ]]; then
    echo "  unit syntax errors:"
    printf '%s\n' "$bad" | sed 's/^/    /'
    ERRORS=$((ERRORS + 1))
  else
    echo "  OK (${#units[@]} units)"
  fi
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
