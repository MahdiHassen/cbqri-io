#!/usr/bin/env python3
"""Summarize a QEMU simple-backend trace of RISC-V IOMMU translations.

    TRACE=riscv_iommu_dma scripts/up.sh ...; scripts/down.sh
    ./dev scripts/qemu_trace_summary.py results/trace-*.bin

Counts translations per (device, PASID, direction) from the stock
`riscv_iommu_dma` event: that is the device-granularity baseline (what a
DC.ta-sourced RCID/MCID would see) with no QEMU changes. Once the Stage 1/2
patches add a label to the event, the same script groups by it too.

Note: translate() carries no access length. Each call covers at most one page
(the IOMMU returns a 4 KiB addr_mask), so `translations` is ~ DMA pages
touched, not bytes.
"""
import collections
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src", "qemu", "scripts"))
import simpletrace  # noqa: E402

EVENTS = os.path.join(ROOT, "build", "qemu", "trace", "trace-events-all")


class Summary(simpletrace.Analyzer2):
    def __init__(self):
        self.dma = collections.Counter()
        self.pages = collections.defaultdict(set)
        self.other = collections.Counter()

    def riscv_iommu_dma(self, id, b, d, f, pasid, dir, iova, phys,
                        label=None, **kwargs):
        if isinstance(dir, bytes):  # simple backend returns strings as bytes
            dir = dir.decode()
        key = (f"{b:02x}:{d:02x}.{f}", pasid, dir, label)
        self.dma[key] += 1
        self.pages[key].add(iova >> 12)

    def catchall(self, *args, event, **kwargs):
        self.other[event.name] += 1


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for path in sys.argv[1:]:
        s = Summary()
        with open(EVENTS) as ev, open(path, "rb") as log:
            simpletrace.process(ev, log, s)
        total = sum(s.dma.values()) or 1
        print(f"\n=== {path}: {sum(s.dma.values())} translations")
        print(f"{'device':<10} {'pasid':>5} {'dir':>3} {'label':>6} "
              f"{'translations':>13} {'share':>7} {'uniq pages':>11}")
        for (dev, pasid, d, label), n in sorted(s.dma.items(), key=lambda kv: -kv[1]):
            lab = "-" if label is None else str(label)
            print(f"{dev:<10} {pasid:>5} {d:>3} {lab:>6} {n:>13} "
                  f"{100 * n / total:6.1f}% {len(s.pages[(dev, pasid, d, label)]):>11}")
        if s.other:
            print("other events: " + ", ".join(f"{k}={v}" for k, v in s.other.most_common()))


if __name__ == "__main__":
    main()
