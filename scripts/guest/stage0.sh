#!/bin/bash
# Stage 0 run, inside the guest:   /root/cbqri/stage0.sh <mode> [runtime_s]
#
# Two tenants, two cgroups, two partitions of the NVMe namespace. Tenant A only
# ever touches nvme0n1p1 and tenant B only nvme0n1p2, so the sector of any
# request *is* the ground truth for who caused it, independent of anything the
# kernel believes. stage0.bt records what each candidate labeling policy would
# have said; scripts/analyze_stage0.py (host) scores them.
#
# modes:
#   direct     O_DIRECT randrw on the raw partitions (labels should be ~perfect)
#   buffered   buffered writes to ext4, no fsync; writeback happens later from
#              flusher kworkers after a global `sync` issued from the root cgroup
#   fsync      buffered writes to ext4 with fsync at the end (writer's context)
set -euo pipefail
mode=${1:?usage: stage0.sh direct|buffered|fsync [runtime_s]}
runtime=${2:-20}
dev=/dev/nvme0n1
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/results/stage0-$mode-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"

# --- one-time: partition the namespace ---------------------------------------
if [[ ! -b ${dev}p2 ]]; then
    printf 'label: gpt\n,%s\n,\n' "$(( $(blockdev --getsz $dev) / 2 - 4096 ))" | sfdisk -q $dev
    udevadm settle
fi

# --- cgroups -----------------------------------------------------------------
cg=/sys/fs/cgroup
echo "+io +memory" > $cg/cgroup.subtree_control
for t in a b; do mkdir -p $cg/cbqri-$t; done

# --- per-mode filesystem prep (outside tracing) --------------------------------
if [[ $mode != direct ]]; then
    for t in a b; do
        p=${dev}p$([[ $t == a ]] && echo 1 || echo 2)
        umount /mnt/$t 2>/dev/null || true
        mkfs.ext4 -q -F $p
        mkdir -p /mnt/$t && mount $p /mnt/$t
    done
fi
sync; echo 3 > /proc/sys/vm/drop_caches

python3 - "$out/meta.json" "$mode" "$runtime" <<'EOF'
import json, os, sys
dev = "nvme0n1"
def rd(p): return int(open(p).read())
meta = {
    "mode": sys.argv[2], "runtime": int(sys.argv[3]),
    "kernel": os.uname().release,
    # cgroup v2 id == inode number of the cgroup directory
    "cgroups": {t: os.stat(f"/sys/fs/cgroup/cbqri-{t}").st_ino for t in "ab"},
    "root_cgroup": os.stat("/sys/fs/cgroup").st_ino,
    "partitions": {t: [rd(f"/sys/block/{dev}/{dev}p{i}/start"),
                       rd(f"/sys/block/{dev}/{dev}p{i}/start") + rd(f"/sys/block/{dev}/{dev}p{i}/size")]
                   for t, i in (("a", 1), ("b", 2))},
}
json.dump(meta, open(sys.argv[1], "w"), indent=1)
EOF

# --- tracer ------------------------------------------------------------------
bpftrace "$here/stage0.bt" > "$out/trace.txt" 2> "$out/bpftrace.err" &
bt=$!
# Wait until probes are attached (bpftrace prints "Attaching N probes...").
# Under TCG, compiling the probes takes a while; give up early if bpftrace died.
for _ in $(seq 300); do
    grep -q Attach "$out/trace.txt" && break
    kill -0 $bt 2>/dev/null || break
    sleep 1
done
grep -q Attach "$out/trace.txt" || { cat "$out/bpftrace.err" >&2; kill $bt 2>/dev/null; exit 1; }

# --- tenants -----------------------------------------------------------------
fio_common=(--ioengine=libaio --iodepth=16 --bs=64k --time_based --runtime="$runtime"
            --group_reporting --output-format=json)
run_tenant() {  # run_tenant <a|b>
    local t=$1 p=${dev}p$([[ $1 == a ]] && echo 1 || echo 2)
    echo $BASHPID > $cg/cbqri-$t/cgroup.procs
    case $mode in
        direct)   exec fio --name=$t --filename=$p --direct=1 --rw=randrw --size=1G \
                        "${fio_common[@]}" ;;
        buffered) exec fio --name=$t --directory=/mnt/$t --direct=0 --rw=write --size=512M \
                        "${fio_common[@]}" ;;
        fsync)    exec fio --name=$t --directory=/mnt/$t --direct=0 --rw=write --size=512M \
                        --end_fsync=1 "${fio_common[@]}" ;;
    esac
}
run_tenant a > "$out/fio-a.json" &
run_tenant b > "$out/fio-b.json" &
wait %2 %3 2>/dev/null || wait

# Buffered: whatever is still dirty gets written back by flusher kworkers.
sync
sleep 2

kill -INT $bt; wait $bt || true
[[ $mode != direct ]] && umount /mnt/a /mnt/b
echo "$out"
