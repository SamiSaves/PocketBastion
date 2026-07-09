#!/usr/bin/env bash
# repo-add.sh — grant the VM per-repo git access with a dedicated deploy key.
#
# Works with any SSH git host (github.com, gitlab.com, self-hosted). The key is
# generated ON the VM and never leaves the state disk; you register its PUBLIC
# half on the repo (this script pauses while you do), then it verifies by
# cloning. Re-running a fully configured repo errors; an interrupted one resumes.
#
# Usage:
#   make repo-add REPO=git@host:owner/name.git
set -euo pipefail

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo "Usage: $0 <git-ssh-url>" >&2
  exit 1
fi
if [[ "$URL" =~ ^https?:// ]]; then
  echo "ERROR: use the SSH clone URL (git@host:owner/name.git), not HTTPS." >&2
  exit 1
fi
if [[ ! "$URL" =~ ^(ssh://)?([^@]+@)?([^/:]+)[:/]+([^/]+)/([^/[:space:]]+)$ ]]; then
  echo "ERROR: '$URL' is not a git SSH URL (expected git@host:owner/name.git)." >&2
  exit 1
fi
HOST="${BASH_REMATCH[3]}"
OWNER="${BASH_REMATCH[4]}"
REPO="${BASH_REMATCH[5]%.git}"
# Validate at the boundary: HOST is interpolated into a remote command, OWNER/REPO
# into paths. Reject anything outside safe host/name characters.
if [[ ! "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || [[ ! "$OWNER" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: '$URL' has an unexpected host, owner, or repo name." >&2
  exit 1
fi
SLUG="$(printf '%s' "$HOST" | tr -c 'a-zA-Z0-9' '-')"
NAME="$SLUG-$OWNER-$REPO"
CANON="git@$HOST:$OWNER/$REPO.git"

VM_IP="${SERVER_IP:-10.44.0.1}"
SSH=(ssh -o StrictHostKeyChecking=no "core@${VM_IP}")

# Phase 1: generate the key + meta on the VM, print the public key.
set +e
PUB=$("${SSH[@]}" 'bash -s' -- "$HOST" "$OWNER" "$REPO" "$NAME" "$CANON" <<'REMOTE'
set -euo pipefail
host="$1"; owner="$2"; repo="$3"; name="$4"; url="$5"
SECRETS=/mnt/state/secrets/git
install -d -m 700 "$SECRETS"
meta="$SECRETS/$name.meta"
if [[ -f "$meta" ]]; then
  verified=false; . "$meta"
  [[ "$verified" == "true" ]] && exit 3
fi
[[ -f "$SECRETS/$name" ]] || \
  ssh-keygen -t ed25519 -N '' -C "opencode $host/$owner/$repo" -f "$SECRETS/$name" >/dev/null
chmod 600 "$SECRETS/$name"; chmod 644 "$SECRETS/$name.pub"
cat > "$meta" <<META
url=$url
host=$host
owner=$owner
repo=$repo
name=$name
verified=false
META
cat "$SECRETS/$name.pub"
REMOTE
)
CODE=$?
set -e
if [[ $CODE -eq 3 ]]; then
  echo "Repo '$HOST/$OWNER/$REPO' is already configured. Use 'make repo-remove NAME=$NAME' first." >&2
  exit 1
fi
[[ $CODE -eq 0 ]] || exit $CODE

echo
echo "Add this public key as a deploy key on the repo ($HOST → $OWNER/$REPO):"
echo
echo "$PUB"
echo
read -r -p "Press Enter once the deploy key is added... "

# Host key: pin known hosts outright; confirm anything else by fingerprint.
case "$HOST" in
  github.com)
    HOSTKEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
    ;;
  *)
    HOSTKEY=$("${SSH[@]}" "ssh-keyscan -t ed25519 -- $HOST 2>/dev/null" | grep -v '^#' | head -n1)
    if [[ -z "$HOSTKEY" ]]; then
      echo "ERROR: could not fetch an Ed25519 host key from $HOST." >&2
      exit 1
    fi
    FPR=$(printf '%s\n' "$HOSTKEY" | ssh-keygen -lf - | awk '{print $2}')
    echo
    echo "First contact with $HOST — verify this matches the host's published fingerprint:"
    echo "  $FPR"
    read -r -p "Pin this host key? [y/N] " ans
    [[ "$ans" == [yY] ]] || { echo "Aborted."; exit 1; }
    ;;
esac

# Phase 2: pin the host key, regenerate config, verify by cloning.
# HOSTKEY has spaces; ssh flattens remote args, so pass it base64-encoded.
HOSTKEY_B64=$(printf '%s' "$HOSTKEY" | base64 | tr -d '\n')
"${SSH[@]}" 'bash -s' -- "$OWNER" "$REPO" "$NAME" "$HOSTKEY_B64" <<'REMOTE'
set -euo pipefail
owner="$1"; repo="$2"; name="$3"; hostkey=$(printf '%s' "$4" | base64 -d)
SECRETS=/mnt/state/secrets/git
KH="$SECRETS/known_hosts"
touch "$KH"
grep -qxF "$hostkey" "$KH" || printf '%s\n' "$hostkey" >> "$KH"
sudo /usr/local/sbin/git-setup.sh
SSH_AUTH_SOCK=/run/opencode/ssh-agent.sock ssh-add "$SECRETS/$name" 2>/dev/null || true
if ! git ls-remote "git@$name:$owner/$repo.git" >/dev/null 2>&1; then
  echo "FAIL: could not authenticate. Is the deploy key added to the repo?" >&2
  exit 4
fi
dest="/mnt/state/repos/$repo"
[[ -e "$dest" ]] || git clone "git@$name:$owner/$repo.git" "$dest"
sed -i 's/^verified=.*/verified=true/' "$SECRETS/$name.meta"
echo "PASS: $owner/$repo cloned to $dest"
REMOTE
