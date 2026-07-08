#!/usr/bin/env bash
# repo-add.sh — grant the VM per-repo git access with a dedicated deploy key.
#
# The key is generated ON the VM and never leaves the state disk. You register
# its PUBLIC half as a deploy key on the repo (this script pauses while you do),
# then it verifies access by cloning. Re-running on a fully configured repo is an
# error; re-running after an interrupted attempt resumes.
#
# Usage:
#   make repo-add REPO=git@github.com:owner/name.git [WRITE=1]
set -euo pipefail

URL="${1:-}"
WRITE=false
[[ "${2:-}" == "--write" ]] && WRITE=true

if [[ -z "$URL" ]]; then
  echo "Usage: $0 <github-url> [--write]" >&2
  exit 1
fi

if [[ ! "$URL" =~ github\.com[:/]+([^/]+)/([^/[:space:]]+) ]]; then
  echo "ERROR: '$URL' is not a github.com repository URL." >&2
  exit 1
fi
OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]%.git}"
NAME="$OWNER-$REPO"
CANON="git@github.com:$OWNER/$REPO.git"

VM_IP="${SERVER_IP:-10.44.0.1}"
SSH=(ssh -o StrictHostKeyChecking=no "core@${VM_IP}")

set +e
PUB=$("${SSH[@]}" 'bash -s' -- "$OWNER" "$REPO" "$CANON" "$WRITE" <<'REMOTE'
set -euo pipefail
owner="$1"; repo="$2"; url="$3"; write="$4"
name="$owner-$repo"
SECRETS=/mnt/state/secrets/github
install -d -m 700 "$SECRETS"
meta="$SECRETS/$name.meta"
if [[ -f "$meta" ]]; then
  verified=false; . "$meta"
  [[ "$verified" == "true" ]] && exit 3
fi
if [[ ! -f "$SECRETS/$name" ]]; then
  ssh-keygen -t ed25519 -N '' -C "opencode $owner/$repo" -f "$SECRETS/$name" >/dev/null
fi
chmod 600 "$SECRETS/$name"; chmod 644 "$SECRETS/$name.pub"
cat > "$meta" <<META
url=$url
owner=$owner
repo=$repo
write=$write
verified=false
META
cat "$SECRETS/$name.pub"
REMOTE
)
CODE=$?
set -e
if [[ $CODE -eq 3 ]]; then
  echo "Repo '$OWNER/$REPO' is already configured. Use 'make repo-remove NAME=$NAME' first." >&2
  exit 1
fi
[[ $CODE -eq 0 ]] || exit $CODE

echo
echo "Add this as a deploy key on the repo:"
echo "  GitHub → $OWNER/$REPO → Settings → Deploy keys → Add deploy key"
[[ "$WRITE" == "true" ]] && echo "  Tick 'Allow write access'." || echo "  Leave 'Allow write access' unticked (read-only)."
echo
echo "$PUB"
echo
read -r -p "Press Enter once the deploy key is added... "

"${SSH[@]}" 'bash -s' -- "$OWNER" "$REPO" <<'REMOTE'
set -euo pipefail
owner="$1"; repo="$2"
name="$owner-$repo"
ghalias="github-$owner-$repo"
SECRETS=/mnt/state/secrets/github
sudo /usr/local/sbin/git-setup.sh
SSH_AUTH_SOCK=/run/opencode/ssh-agent.sock ssh-add "$SECRETS/$name" 2>/dev/null || true
if ! git ls-remote "git@$ghalias:$owner/$repo.git" >/dev/null 2>&1; then
  echo "FAIL: could not authenticate. Is the deploy key added to the repo?" >&2
  exit 4
fi
dest="/mnt/state/repos/$repo"
[[ -e "$dest" ]] || git clone "git@$ghalias:$owner/$repo.git" "$dest"
sed -i 's/^verified=.*/verified=true/' "$SECRETS/$name.meta"
echo "PASS: $owner/$repo cloned to $dest"
REMOTE
