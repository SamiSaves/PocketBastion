#!/usr/bin/env bash
# github-install-deploy-key.sh — Set up a repo-scoped GitHub deploy key on the VM.
#
# The private key is generated ON the VM and never leaves the state disk. The
# key material and GitHub's pinned host key live under /mnt/state (persistent);
# core's ~/.ssh/config points git at them.
#
# Persistent layout on the VM:
#   /mnt/state/secrets/github/deploy_key       (private, 0600)
#   /mnt/state/secrets/github/deploy_key.pub   (public,  0644)
#   /mnt/state/secrets/github/known_hosts      (pinned GitHub host key)
#
# ~/.ssh/config lives on the ephemeral OS disk — re-run this after a VM rebuild
# (it reuses the persisted key, so no re-registration on GitHub is needed).
#
# Usage:
#   make github-install-deploy-key
#
# Then add the printed public key to the repo:
#   GitHub → repo → Settings → Deploy keys → Add deploy key (allow write access)
set -euo pipefail

# Managed over the WireGuard tunnel — 10.44.0.1 on both local and DO. Override
# SERVER_IP for the one-time local bootstrap: SERVER_IP="$(scripts/local/ip.sh)".
VM_IP="${SERVER_IP:-10.44.0.1}"

ssh -o StrictHostKeyChecking=no "core@${VM_IP}" 'bash -s' <<'REMOTE'
set -euo pipefail
DIR=/mnt/state/secrets/github
KEY="$DIR/deploy_key"

mkdir -p "$DIR"
chmod 700 "$DIR"

if [[ ! -f "$KEY" ]]; then
  ssh-keygen -t ed25519 -N '' -C "opencode-dev-server deploy key" -f "$KEY"
  echo "Generated new deploy key."
else
  echo "Deploy key already exists — reusing."
fi
chmod 600 "$KEY"
chmod 644 "$KEY.pub"

# GitHub's published Ed25519 host key. Pinned rather than ssh-keyscan'd to
# avoid trust-on-first-use MITM. Source: GitHub docs "SSH key fingerprints".
printf '%s\n' \
  'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' \
  > "$DIR/known_hosts"
chmod 644 "$DIR/known_hosts"

# Point core's SSH at the deploy key for github.com. Marker-delimited so
# re-runs replace the block cleanly (idempotent).
mkdir -p ~/.ssh
chmod 700 ~/.ssh
CFG=~/.ssh/config
touch "$CFG"
chmod 600 "$CFG"
sed -i '/# >>> opencode github deploy key >>>/,/# <<< opencode github deploy key <<</d' "$CFG"
cat >> "$CFG" <<EOF
# >>> opencode github deploy key >>>
Host github.com
  HostName github.com
  User git
  IdentityFile $KEY
  IdentitiesOnly yes
  UserKnownHostsFile $DIR/known_hosts
# <<< opencode github deploy key <<<
EOF

echo
echo "Public deploy key — add to GitHub (repo → Settings → Deploy keys, allow write):"
cat "$KEY.pub"
REMOTE
