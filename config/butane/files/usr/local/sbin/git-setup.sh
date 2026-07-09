#!/bin/bash
# git-setup.sh — regenerate git/ssh config from the deploy keys on the state
# disk. Source of truth is /mnt/state/secrets/git/*.meta (+ matching keys and the
# accumulated known_hosts); everything below is a derived artifact, so this is
# safe to re-run and is what reconstructs config after a VM rebuild. Runs as root
# at boot (git-setup.service) and as core (via sudo) from repo-add/repo-remove.
set -euo pipefail

SECRETS=/mnt/state/secrets/git
DATA=/mnt/state/opencode
CORE_HOME=/var/home/core

install -d -m 700 "$SECRETS"
install -d -m 700 "$DATA/.ssh"
install -d -m 700 "$CORE_HOME/.ssh"

# Host keys are pinned per host by repo-add; this file is the source of truth.
touch "$SECRETS/known_hosts"
cp -f "$SECRETS/known_hosts" "$DATA/.ssh/known_hosts"
chmod 644 "$SECRETS/known_hosts" "$DATA/.ssh/known_hosts"

host_cfg="$CORE_HOME/.ssh/config"
cont_cfg="$DATA/.ssh/config"
: > "$host_cfg"
: > "$cont_cfg"

shopt -s nullglob
for meta in "$SECRETS"/*.meta; do
  host= owner= repo= name= url= verified=
  # shellcheck disable=SC1090
  . "$meta"
  cp -f "$SECRETS/$name.pub" "$DATA/.ssh/$name.pub"

  # Host (core) uses the private key directly — this is the trusted bootstrap user.
  {
    printf 'Host %s\n  HostName %s\n  User git\n' "$name" "$host"
    printf '  IdentityFile %s\n  IdentitiesOnly yes\n' "$SECRETS/$name"
    printf '  UserKnownHostsFile %s\n\n' "$SECRETS/known_hosts"
  } >> "$host_cfg"

  # Container (agent) never sees the private key: public IdentityFile selects it,
  # IdentityAgent reaches the socket. A compromised agent can use but not steal it.
  {
    printf 'Host %s\n  HostName %s\n  User git\n' "$name" "$host"
    printf '  IdentityFile /data/.ssh/%s.pub\n  IdentitiesOnly yes\n' "$name"
    printf '  IdentityAgent /run/opencode/ssh-agent.sock\n'
    printf '  UserKnownHostsFile /data/.ssh/known_hosts\n\n'
  } >> "$cont_cfg"
done

chmod 600 "$host_cfg" "$cont_cfg"
install -m 600 /etc/opencode/gitconfig "$DATA/.gitconfig"

chown -R 1000:1000 "$SECRETS" "$DATA/.ssh" "$DATA/.gitconfig" "$CORE_HOME/.ssh"
