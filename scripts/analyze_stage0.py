#!/usr/bin/env python3
"""Score Stage 0 runs: attributable fraction per labeling policy + IOMMU ops/IO.

    scripts/analyze_stage0.py results/guest/stage0-direct-*/ [...]

Input: meta.json + trace.txt from scripts/guest/stage0.sh.
Ground truth for a request = the tenant whose partition contains its sector.
For each policy, a request's bytes are:
    correct     label == truth tenant
    wrong       label == the *other* tenant
    unlabeled   label is root / a kworker's cgroup / missing (0)
"""
import collections
import json
import re
import sys
from pathlib import Path

POLICIES = [  # (column, description)
    ("cur", "current task's cgroup at map time"),
    ("blkcg", "bio blkcg (blk-cgroup charge)"),
    ("page_first", "memcg of first page"),
    ("page_last", "memcg of last page"),
]
R_FIELDS = ["ts", "sector", "bytes", "rwbs", "cur", "blkcg", "page_first",
            "page_last", "nmap", "map_bytes", "domain", "comm"]
MAP_RE = re.compile(r"^@(\w+)\[(-?\d+)\]: (\d+)$")


def load(run):
    meta = json.loads((run / "meta.json").read_text())
    reqs, totals = [], collections.defaultdict(dict)
    for line in (run / "trace.txt").read_text().splitlines():
        if line.startswith("R "):
            f = line.split(maxsplit=len(R_FIELDS))[1:]
            r = dict(zip(R_FIELDS, f))
            for k in R_FIELDS:
                if k not in ("rwbs", "comm", "domain"):
                    r[k] = int(r[k])
            r["domain"] = int(r["domain"], 16)
            reqs.append(r)
        elif m := MAP_RE.match(line):
            # bpftrace prints uint64 map keys as signed; normalize to match R lines.
            totals[m.group(1)][int(m.group(2)) & (2**64 - 1)] = int(m.group(3))
    return meta, reqs, totals


def tenant_of_sector(meta, sector):
    for t, (lo, hi) in meta["partitions"].items():
        if lo <= sector < hi:
            return t
    return None


def analyze(run):
    meta, reqs, totals = load(run)
    cg2tenant = {v: k for k, v in meta["cgroups"].items()}
    data = [r for r in reqs if r["bytes"] > 0]
    total = sum(r["bytes"] for r in data)

    print(f"\n=== {run.name}  (mode={meta['mode']}, kernel {meta['kernel']})")
    if not data:
        print("no data requests traced")
        return
    outside = sum(r["bytes"] for r in data if tenant_of_sector(meta, r["sector"]) is None)
    print(f"{len(data)} data requests, {total / 2**20:.1f} MiB"
          + (f", {outside / 2**20:.1f} MiB outside both partitions (excluded)" if outside else ""))

    print(f"\n{'policy':<12} {'correct':>8} {'wrong':>8} {'unlabeled':>10}   description")
    for col, desc in POLICIES:
        c = collections.Counter()
        for r in data:
            truth = tenant_of_sector(meta, r["sector"])
            if truth is None:
                continue
            label = cg2tenant.get(r[col])
            c["correct" if label == truth else "unlabeled" if label is None else "wrong"] += r["bytes"]
        denom = total - outside
        print(f"{col:<12} {100 * c['correct'] / denom:7.1f}% {100 * c['wrong'] / denom:7.1f}%"
              f" {100 * c['unlabeled'] / denom:9.1f}%   {desc}")

    # Who issued the I/O: tenant tasks vs. kworkers (writeback) vs. other.
    by_issuer = collections.Counter()
    for r in data:
        issuer = "kworker" if r["comm"].startswith("kworker") else r["comm"].split("/")[0]
        by_issuer[issuer] += r["bytes"]
    print("\nissuer share of bytes: " + ", ".join(
        f"{k} {100 * v / total:.1f}%" for k, v in by_issuer.most_common(6)))

    # IOMMU operation cost. Domains seen in NVMe request windows = NVMe domain.
    doms = {r["domain"] for r in data if r["nmap"]}
    n = len(data)
    print(f"\nIOMMU ops per data request (NVMe domain{'s' if len(doms) > 1 else ''} "
          f"{', '.join(hex(d) for d in doms) or '?'}):")
    for key, label in (("maps", "iommu_map_nosync calls"),
                       ("unmaps", "iommu_unmap[_fast] calls"),
                       ("syncs", "IOTLB sync (invalidation) ops"),
                       ("flush_all", "full IOTLB flushes")):
        v = sum(totals[key].get(d, 0) for d in doms)
        print(f"  {label:<32} {v / n:6.2f}   ({v} total)")
    mb = sum(totals["map_bytes"].get(d, 0) for d in doms)
    if mb:
        print(f"  {'bytes per map call':<32} {mb / max(1, sum(totals['maps'].get(d, 0) for d in doms)):6.0f}")


def main():
    runs = [Path(a) for a in sys.argv[1:]]
    if not runs:
        sys.exit(__doc__)
    for run in runs:
        analyze(run)


if __name__ == "__main__":
    main()
