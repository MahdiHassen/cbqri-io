#!/usr/bin/env bash
# Push scripts/guest/ to /root/cbqri in the guest, pull /root/cbqri/results/
# back into results/guest/.   scripts/sync.sh [push|pull]  (default: push)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
rsh="ssh -q -i $root/images/ssh/id_ed25519 -p ${SSH_PORT:-10022} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
host=root@127.0.0.1
case ${1:-push} in
    push) rsync -a --delete --exclude results -e "$rsh" "$root/scripts/guest/" $host:/root/cbqri/ ;;
    pull) mkdir -p "$root/results/guest"
          rsync -a -e "$rsh" $host:/root/cbqri/results/ "$root/results/guest/" ;;
    *) echo "usage: $0 [push|pull]" >&2; exit 1 ;;
esac
