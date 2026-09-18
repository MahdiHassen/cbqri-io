#!/usr/bin/env bash
# ssh into the running guest (or run a command there). Works on the host or in
# the container. Also exports helpers for scp/rsync via $CBQRI_SSH.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
exec ssh -q -i "$root/images/ssh/id_ed25519" -p "${SSH_PORT:-10022}" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o LogLevel=ERROR \
    root@127.0.0.1 "$@"
