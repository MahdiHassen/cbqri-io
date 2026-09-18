#!/usr/bin/env bash
# Boot the experiment guest. Run inside the container: ./dev scripts/run.sh
#
# Topology (all on -M virt with AIA/IMSIC so the IOMMU and devices get MSIs):
#   00:01.0  riscv-iommu-pci          translates everything below
#   nvme     cbqri0, 4G scratch       the device under test (fio target)
#   virtio-net (iommu_platform=on)    guest network / ssh; IOMMU-translated
#   virtio-blk rootfs (iommu_platform=off) deliberately NOT translated, so the
#                                     root disk's DMA never pollutes traces
#
# Environment knobs:
#   SMP=4 MEM=4G SSH_PORT=10022
#   TRACE=<qemu trace pattern>   e.g. TRACE='riscv_iommu_dma'  (simple backend)
#   TRACE_FILE=results/trace.bin
#   IOMMU_OPTS=',hpm-counters=31'  extra riscv-iommu-pci properties
#   NVME_OPTS=',sriov_max_vfs=2,...'  extra nvme properties
#   NET=virtio|e1000e            NIC model for the RX experiments
#   EXTRA_APPEND='iommu.strict=0'  extra kernel command line
#   SNAPSHOT=1                   discard guest disk writes on exit
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

SMP=${SMP:-4}
MEM=${MEM:-4G}
SSH_PORT=${SSH_PORT:-10022}
NET=${NET:-virtio}
qemu="$root/build/qemu/qemu-system-riscv64"
kernel="$root/build/linux/arch/riscv/boot/Image"
disk="${DISK:-$root/images/guest.qcow2}"
nvme_img="$root/images/nvme0.img"

[[ -x $qemu ]]   || { echo "no $qemu; run: ./dev make qemu" >&2; exit 1; }
[[ -f $kernel ]] || { echo "no $kernel; run: ./dev make kernel" >&2; exit 1; }
[[ -f $disk ]]   || { echo "no $disk; run: ./dev make rootfs" >&2; exit 1; }
[[ -f $nvme_img ]] || truncate -s 4G "$nvme_img"

case $NET in
    virtio) nic="virtio-net-pci,netdev=net0,disable-legacy=on,iommu_platform=on" ;;
    e1000e) nic="e1000e,netdev=net0" ;;
    *) echo "NET must be virtio or e1000e" >&2; exit 1 ;;
esac

trace=()
if [[ -n ${TRACE:-} ]]; then
    tf=${TRACE_FILE:-$root/results/trace-$(date +%Y%m%d-%H%M%S).bin}
    mkdir -p "$(dirname "$tf")"
    trace=(-trace "enable=$TRACE,file=$tf")
    echo "tracing '$TRACE' -> $tf" >&2
fi

snap=()
[[ -n ${SNAPSHOT:-} ]] && snap=(-snapshot)

exec "$qemu" \
    -M virt,aia=aplic-imsic -cpu rv64 -smp "$SMP" -m "$MEM" \
    -nographic \
    -kernel "$kernel" \
    -append "root=/dev/vda1 rw console=ttyS0 earlycon systemd.firstboot=off ${EXTRA_APPEND:-}" \
    -device "riscv-iommu-pci,addr=1.0${IOMMU_OPTS:-}" \
    -drive "file=$disk,if=none,id=root,format=qcow2" \
    -device virtio-blk-pci,drive=root \
    -drive "file=$nvme_img,if=none,id=nvm0,format=raw" \
    -device "nvme,serial=cbqri0,drive=nvm0${NVME_OPTS:-}" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -device "$nic" \
    "${trace[@]}" "${snap[@]}" \
    "$@"
