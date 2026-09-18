#!/usr/bin/env bash
# Cleanly power off the guest started by scripts/up.sh. The poweroff matters
# when tracing: QEMU's simple trace backend flushes its buffer on exit.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
name=${GUEST_NAME:-cbqri-guest}
"$root/scripts/ssh.sh" poweroff 2>/dev/null
for _ in $(seq 60); do
    docker ps -q --filter "name=^${name}$" | grep -q . || { docker rm "$name" >/dev/null 2>&1; exit 0; }
    sleep 1
done
echo "no clean exit, killing" >&2
docker rm -f "$name" >/dev/null
