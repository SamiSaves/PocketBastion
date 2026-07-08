#!/usr/bin/env bash
# repo-remove.sh — revoke the VM's git access to a repo.
#
# You revoke the deploy key on GitHub (this script pauses while you do), it then
# confirms access is actually dead before dropping the key and ssh alias. The
# working tree under /mnt/state/repos is kept unless PURGE=1 (which can destroy
# uncommitted work).
#
# Usage:
#   make repo-remove NAME=owner-name [PURGE=1]
set -euo pipefail

NAME="${1:-}"
PURGE=false
[[ "${2:-}" == "--purge" ]] && PURGE=true

if [[ -z "$NAME" ]]; then
  echo "Usage: $0 <name> [--purge]   (name as shown by 'make repo-list')" >&2
  exit 1
fi

VM_IP="${SERVER_IP:-10.44.0.1}"
SSH=(ssh -o StrictHostKeyChecking=no "core@${VM_IP}")

META=$("${SSH[@]}" "cat /mnt/state/secrets/github/${NAME}.meta" 2>/dev/null) || {
  echo "No such repo '$NAME'. Run 'make repo-list'." >&2
  exit 1
}
OWNER=$(sed -n 's/^owner=//p' <<<"$META")
REPO=$(sed -n 's/^repo=//p' <<<"$META")

echo "Revoke the deploy key:"
echo "  GitHub → $OWNER/$REPO → Settings → Deploy keys → delete the opencode key"
echo
read -r -p "Press Enter once the deploy key is revoked... "

"${SSH[@]}" 'bash -s' -- "$OWNER" "$REPO" "$PURGE" <<'REMOTE'
set -euo pipefail
owner="$1"; repo="$2"; purge="$3"
name="$owner-$repo"
ghalias="github-$owner-$repo"
SECRETS=/mnt/state/secrets/github
if git ls-remote "git@$ghalias:$owner/$repo.git" >/dev/null 2>&1; then
  echo "ABORT: access still works — the deploy key was not revoked." >&2
  exit 5
fi
SSH_AUTH_SOCK=/run/opencode/ssh-agent.sock ssh-add -d "$SECRETS/$name.pub" 2>/dev/null || true
rm -f "$SECRETS/$name" "$SECRETS/$name.pub" "$SECRETS/$name.meta"
sudo /usr/local/sbin/git-setup.sh
if [[ "$purge" == "true" ]]; then
  rm -rf "/mnt/state/repos/$repo"
  echo "Removed $owner/$repo and deleted its working tree."
else
  echo "Removed $owner/$repo. Working tree kept at /mnt/state/repos/$repo."
fi
REMOTE
