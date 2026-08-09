#!/bin/bash
# pb-priv — the entire root API available to the admin UI.
#
# pb-priv.socket listens with Accept=yes, so systemd starts one of these per
# connection, hands it the socket on stdin/stdout, and it exits. Nothing runs
# the rest of the time.
#
# The web process never builds a command string: it writes a verb, and this
# script decides what that verb means. If the web process is fully compromised,
# the attacker's whole capability is the case statement below. Adding a verb
# here is a security review.
#
# ponytail: the socket's group is core, and the OpenCode container shares uid
# 1000, so it can reach this too. Bounded by the allowlist — both verbs amount
# to "restart something already running". Give pbweb its own uid (and a shared
# group on /mnt/state) if a verb ever does more than that.
set -euo pipefail

read -r verb arg || exit 1

case "$verb" in
  restart)
    case "$arg" in
      git-setup.service)
        systemctl restart git-setup.service
        ;;
      opencode)
        # Not `systemctl --user --machine=core@.host`: that needs
        # systemd-container, which FCOS does not ship. runuser is util-linux.
        runuser -u core -- \
          env XDG_RUNTIME_DIR=/run/user/1000 \
          systemctl --user restart opencode.service
        ;;
      *)
        echo "ERR unknown unit"
        exit 1
        ;;
    esac
    echo OK
    ;;
  *)
    echo "ERR unknown verb"
    exit 1
    ;;
esac
