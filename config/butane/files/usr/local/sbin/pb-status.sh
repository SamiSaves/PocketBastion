#!/bin/bash
# pb-status.sh — write /run/pocketbastion/agent-status.json, the status file
# (docs/admin-ui.md). Runs as root each minute and at boot (pb-status.timer).
#
# Everything the admin UI wants to *read* about Orca's world comes from this
# file instead of a pb-priv verb or a mount into Orca's /data: derived facts
# only, never a token, so it is world-readable and pbweb needs no access to
# anything secret. Requires jq (in the FCOS base image).
set -euo pipefail

OUT=/run/pocketbastion/agent-status.json
DATA=/mnt/state/orca            # the Orca container's /data
REPOS=/mnt/state/repos

# ponytail: path assumed from XDG_DATA_HOME=/data; verify on the mock VM once
# a device has paired, together with the ready-line shape below.
DEVICES="$DATA/orca-devices.json"

github=$(grep -m1 -oP '^\s*user:\s*\K\S+' "$DATA/config/gh/hosts.yml" 2>/dev/null || true)
git_email=$(grep -m1 -oP '^\s*email\s*=\s*\K.+' "$DATA/.gitconfig" 2>/dev/null || true)

exists() { [[ -f "$1" ]] && echo true || echo false; }

# The latest ready-line from Orca's journal: pairing offer, web client URL, or
# the failure reason. `serve --json` makes it a JSON object; guard anyway so a
# stray text line cannot corrupt the whole file.
ready=$(journalctl -q -o cat -r _SYSTEMD_USER_UNIT=orca.service 2>/dev/null \
  | grep -m1 -F orca_server_ready || true)
jq -e . <<<"$ready" >/dev/null 2>&1 || ready=null

devices=$(jq -c . "$DEVICES" 2>/dev/null || echo null)

# Name + size per checkout, informational. du here rather than a repos mount in
# pbweb: walking node_modules on the microSD belongs in a once-a-minute timer,
# not in a page load.
repos=$(cd "$REPOS" 2>/dev/null && du -sk -- */ 2>/dev/null \
  | jq -Rn '[inputs / "\t" | {name: (.[1] | rtrimstr("/")), kb: (.[0] | tonumber)}]' \
  || echo '[]')

mkdir -p "$(dirname "$OUT")"
jq -n \
  --arg github "$github" \
  --arg gitEmail "$git_email" \
  --argjson claude "$(exists "$DATA/.claude/.credentials.json")" \
  --argjson codex "$(exists "$DATA/.codex/auth.json")" \
  --argjson ready "$ready" \
  --argjson devices "$devices" \
  --argjson repos "$repos" \
  '{github: (if $github == "" then null else $github end),
    gitEmail: (if $gitEmail == "" then null else $gitEmail end),
    claude: $claude, codex: $codex,
    ready: $ready, devices: $devices, repos: $repos}' \
  > "$OUT.tmp"
chmod 644 "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
