#!/usr/bin/env bash
# Values shared by the host-side scripts. Source it; it only assigns.

# The server's address inside the WireGuard tunnel. In wireguard mode this is
# where every service binds and where the management scripts connect.
#
# The authoritative copy is the `Address =` line in
# config/butane/files/usr/local/sbin/wg-setup.sh, which is shipped to the box
# verbatim (contents.local never passes through envsubst) and so cannot read
# this file. scripts/test-render.sh asserts the two still agree.
# shellcheck disable=SC2034  # read by the scripts that source this file
WG_SERVER_IP=10.44.0.1
