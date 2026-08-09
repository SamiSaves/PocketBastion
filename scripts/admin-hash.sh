#!/usr/bin/env bash
# admin-hash.sh — print an ADMIN_PASSWORD_HASH line to paste into deploy.env.
#
# scrypt, because node has it built in: the admin UI verifies with the same node
# that serves the page, so nothing extra is installed on either side.
#
# The password is read from a prompt, never from argv — argv is world-readable
# in /proc, and a command line lands in shell history.
#
# Usage:  make admin-hash
set -euo pipefail

command -v node >/dev/null \
  || { echo "ERROR: node is required (you already need it for the UI build)." >&2; exit 1; }

read -rsp "Admin password: " pw; echo
read -rsp "Again: "          pw2; echo

[[ "$pw" == "$pw2" ]] || { echo "ERROR: passwords do not match." >&2; exit 1; }
(( ${#pw} >= 12 )) || { echo "ERROR: use at least 12 characters." >&2; exit 1; }

# ':' as the field separator, not '$': the hash passes through envsubst and a
# shell-quoted deploy.env on its way into the Ignition config.
# shellcheck disable=SC2016  # single quotes on purpose: this is JS, not shell
printf '%s' "$pw" | node -e '
  const c = require("crypto");
  let pw = "";
  process.stdin.on("data", d => (pw += d)).on("end", () => {
    const salt = c.randomBytes(16);
    const hash = c.scryptSync(pw, salt, 32);
    console.log(`ADMIN_PASSWORD_HASH=scrypt:${salt.toString("base64")}:${hash.toString("base64")}`);
  });
'
