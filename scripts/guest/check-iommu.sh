#!/bin/bash
# Verify the guest is really translating DMA through the RISC-V IOMMU.
# In BARE/passthrough there is no PTE, so no label: every later measurement
# would silently measure nothing. Exits non-zero if the NVMe (or the NIC)
# isn't in a translated DMA domain.
set -uo pipefail
fail=0

echo "== riscv-iommu probe"
dmesg | grep -iE 'riscv-iommu|iommu:' | head -20

echo "== IOMMU groups (type must be DMA or DMA-FQ, not identity)"
for g in /sys/kernel/iommu_groups/*; do
    type=$(cat "$g/type")
    for d in "$g"/devices/*; do
        bdf=$(basename "$d")
        drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || echo -)
        printf '  group %-3s %-8s %s %s\n' "$(basename "$g")" "$type" "$bdf" "$drv"
        case $drv in
            nvme|virtio-pci|e1000e)
                [[ $type == DMA || $type == DMA-FQ ]] || { echo "  ^^^ NOT TRANSLATED"; fail=1; } ;;
        esac
    done
done
ls /sys/kernel/iommu_groups/* >/dev/null 2>&1 || { echo "  no IOMMU groups at all"; fail=1; }

echo "== strict/lazy"
grep -o 'iommu[.=][^ ]*' /proc/cmdline || echo "  (kernel default; build has IOMMU_DEFAULT_DMA_STRICT)"

echo "== NVMe"
nvme list 2>/dev/null || ls /dev/nvme*

exit $fail
