#!/usr/bin/env bash
# check-prereqs.sh — verify host tools and group membership for local KVM dev.
# This script ONLY checks; it does not install anything.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { printf "${GREEN}  [OK]${NC}  %s\n" "$1"; }
warn() { printf "${YELLOW}  [WARN]${NC} %s\n" "$1"; }
fail() { printf "${RED}  [MISS]${NC} %s\n" "$1"; MISSING=1; }

MISSING=0

echo "=== Checking required tools ==="

REQUIRED_TOOLS=(
  qemu-img
  virsh
  virt-install
  podman
  curl
  jq
  ssh
  make
)

for tool in "${REQUIRED_TOOLS[@]}"; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool  ($(command -v "$tool"))"
  else
    fail "$tool  — not found"
  fi
done

echo ""
echo "=== Checking group membership ==="

REQUIRED_GROUPS=(libvirt kvm)

for grp in "${REQUIRED_GROUPS[@]}"; do
  if id -nG | tr ' ' '\n' | grep -qx "$grp"; then
    ok "group: $grp"
  else
    warn "group: $grp  — you are NOT a member"
    MISSING=1
  fi
done

echo ""

if [[ "$MISSING" -eq 0 ]]; then
  echo -e "${GREEN}All prerequisites satisfied.${NC}"
  exit 0
fi

echo -e "${RED}Some prerequisites are missing. Install with:${NC}"
cat <<'EOF'

  sudo apt update
  sudo apt install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    virt-manager \
    virtinst \
    genisoimage \
    jq \
    make \
    curl \
    git \
    podman

  sudo adduser "$USER" libvirt
  sudo adduser "$USER" kvm

Then log out and back in.
EOF
exit 1
