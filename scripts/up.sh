#!/usr/bin/env bash
# Start the guest in a detached container and wait until ssh answers, then push
# scripts/guest/ to /root/cbqri. Run on the HOST (it calls ./dev itself).
# Any env knobs of scripts/run.sh (TRACE=, NET=, NVME_OPTS=, ...) pass through.
#   scripts/up.sh            start;  docker logs -f cbqri-guest  = console
#   scripts/down.sh          clean poweroff
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
name=${GUEST_NAME:-cbqri-guest}

if docker ps -q --filter "name=^${name}$" | grep -q .; then
    echo "$name already running" >&2
else
    docker rm -f "$name" >/dev/null 2>&1 || true
    env_args=()
    for v in SMP MEM SSH_PORT TRACE TRACE_FILE IOMMU_OPTS NVME_OPTS NET EXTRA_APPEND SNAPSHOT; do
        [[ -n ${!v:-} ]] && env_args+=("$v=${!v}")
    done
    DETACH=$name "$root/dev" env "${env_args[@]}" scripts/run.sh >/dev/null
fi

echo -n "waiting for ssh" >&2
for _ in $(seq 300); do
    if "$root/scripts/ssh.sh" true 2>/dev/null; then
        echo " up" >&2
        "$root/scripts/sync.sh"
        exit 0
    fi
    docker ps -q --filter "name=^${name}$" | grep -q . || {
        echo; docker logs --tail 30 "$name"; echo "guest exited" >&2; exit 1; }
    echo -n . >&2; sleep 2
done
echo " timeout" >&2; exit 1
