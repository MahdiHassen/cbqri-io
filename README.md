# cbqri-io

Per-page QoS labels for device DMA: CBQRI RCID/MCID carried in the **RISC-V
IOMMU leaf PTE** instead of (or layered over) the device-context `DC.ta`.

QEMU has no memory system, so this project doesn't measure bandwidth. It
measures the three things that don't depend on timing and carry over to real
hardware:

1. **Attributable fraction.** Of all DMA bytes, what share would carry the
   right label under each labeling policy?
2. **Operation cost.** PTE writes and IOTLB invalidations per I/O.
3. **Ownership plumbing.** cgroup → label across writeback, migration, fork,
   page sharing, and buffer recycling.

## Quick start

Everything builds and runs in a container (`./dev` wraps `docker run`), so
the host needs only docker. The guest is Debian 13 riscv64 on
`qemu-system-riscv64 -M virt` under TCG.

```sh
./dev make src patch           # clone QEMU v11.1.1 + Linux v7.2.6, apply patches/*
./dev make qemu kernel         # ~5 min on 16+ cores
./dev make rootfs              # images/guest.qcow2; first boot runs apt (~3 min)

scripts/up.sh                  # boot detached, wait for ssh, push scripts/guest/
scripts/ssh.sh cbqri/check-iommu.sh          # MUST pass: NVMe in a translated DMA domain
scripts/ssh.sh cbqri/stage0.sh direct 20     # O_DIRECT: two tenants, two cgroups
scripts/ssh.sh cbqri/stage0.sh buffered 20   # buffered + flusher writeback
scripts/sync.sh pull
./dev scripts/analyze_stage0.py results/guest/stage0-*
scripts/down.sh
```

`docker logs -f cbqri-guest` shows the serial console. The console root
password is empty.

**The kernel patches are required.** Without `patches/linux/`, every device
silently runs in an identity domain (finding 1 below). `make kernel` fails the
kconfig check on an unpatched tree instead of building a kernel that looks fine
and translates nothing.

## Layout

| path | what |
|---|---|
| `dev` | run a command in the build container (`./dev` alone gives a shell) |
| `Makefile` | `src`, `patch`, `qemu`, `kernel`, `rootfs` |
| `configs/guest.config` | kernel fragment: RISC-V IOMMU, **strict translated DMA by default**, BTF/BPF, cgroup v2 io+memory+writeback, NVMe with SR-IOV, e1000e |
| `patches/{qemu,linux}/` | our changes as `git format-patch` series; `make patch` resets `src/*` branch `cbqri` to the pinned tag and applies them |
| `scripts/run.sh` | the QEMU command line (env knobs documented at the top) |
| `scripts/mkimage.sh` | Debian nocloud image → `images/guest.qcow2` (edited offline with debugfs, then provisioned on first boot) |
| `scripts/up.sh`, `down.sh`, `ssh.sh`, `sync.sh` | guest lifecycle |
| `scripts/guest/stage0.{sh,bt}` | Stage 0 experiment + bpftrace tracer (runs in the guest) |
| `scripts/guest/check-iommu.sh` | fails if any device under test is in an identity/passthrough domain |
| `scripts/analyze_stage0.py` | scores Stage 0 runs |
| `scripts/qemu_trace_summary.py` | per-device/PASID/label translation counts from a QEMU `simple` trace |

## Guest topology

```
-M virt,aia=aplic-imsic                       (IMSIC: the IOMMU and devices use MSIs)
  00:01.0 riscv-iommu-pci                     all PCI devices below sit behind it
  nvme  serial=cbqri0, 4 GiB images/nvme0.img device under test
  virtio-net-pci iommu_platform=on            ssh; translated (RX-path experiments)
  virtio-blk-pci  (rootfs)                    iommu_platform=off: data NOT translated,
                                              so root-disk DMA stays out of traces (its
                                              MSI writes still are: 4 IMSIC pages)
```

Useful `run.sh` knobs (they also pass through `up.sh`):

- `TRACE=riscv_iommu_dma` writes a QEMU `simple` trace to `results/`.
- `NVME_OPTS=',sriov_max_vfs=…'` enables SR-IOV for the per-VF baseline.
- `NET=e1000e`
- `IOMMU_OPTS=',hpm-counters=…'`
- `EXTRA_APPEND='iommu.strict=0'` compares against lazy flushing.

**Virtio gotcha:** a QEMU virtio device bypasses the IOMMU entirely unless it
has `iommu_platform=on`. The guest then never maps anything for it, and QEMU
never translates for it.

## Stage 0: attributability, with no labeling changes

`stage0.sh` splits the NVMe namespace into two partitions and puts tenant A
(cgroup `cbqri-a`) on p1 and tenant B (cgroup `cbqri-b`) on p2. A request's
sector then gives **ground truth** for who caused it, independent of anything
the kernel believes, including writeback that kworkers issue on a tenant's
behalf.

`stage0.bt` brackets each request between `nvme_setup_cmd()` and the
`block_rq_issue` tracepoint, which contain all of that request's
`iommu_map_nosync()` calls. It hooks there rather than `nvme_queue_rq()`,
because batched submissions go through `->queue_rqs`. For each request it
records the label each candidate policy would assign:

| column | policy |
|---|---|
| `cur` | `current`'s cgroup at map time (a `prctl`/current-cgroup design) |
| `blkcg` | `bio->bi_blkg`, which blk-cgroup already charges; for writeback this is `wbc_account_cgroup_owner()`'s inode-majority heuristic |
| `page_first`, `page_last` | memcg of the first/last page of the buffer (a "tag the buffer" design) |

It also counts per-domain `iommu_map_nosync` / `iommu_unmap[_fast]` /
`riscv_iommu_iotlb_sync` / `riscv_iommu_iotlb_flush_all` calls, which gives
ops per I/O.

### First results (2026-09-18, 20 s per tenant, strict mode, 64 KiB fio)

Share of DMA bytes that would carry the correct tenant label:

| mode | `cur` | `blkcg` | page memcg (first/last) | kworker share of bytes | IOTLB inval / req | maps / req |
|---|---|---|---|---|---|---|
| direct (O_DIRECT randrw) | 100% | 100% | 100% / 100% | 0% | 1.00 | 3.79 |
| buffered (flusher writeback) | **37.2%** | 100% | 100% / 100% | 62.8% | 1.00 | 1.32 |
| fsync (end_fsync) | **36.6%** | 100% | 100% / 100% | 63.4% | 1.00 | 1.40 |

No policy ever assigned the *other* tenant's label. The unlabeled bytes come
from kworker-issued writeback under `cur`; any remaining ~0.5% in some runs is
`ext4lazyinit`, which is housekeeping, not tenant I/O.

Takeaways, with caveats:

- Tagging by `current` fails on buffered I/O, as predicted. Tagging by the
  buffer (page memcg) or by blkcg holds up.
- These runs had one writer per inode, so the inode-majority heuristic behind
  `blkcg` couldn't fail. **Shared-inode and shared-page cases** (two cgroups
  writing one file, page cache shared by fork, buffer recycling) are where
  `blkcg` and page memcg should diverge. That's the next experiment.
- Maps per request depend on how physically contiguous the buffers happen to
  be: 1.07 vs 3.79 for the same O_DIRECT job on two different boots. Pin that
  down (THP on/off, `--mem=` / hugepages) before quoting ops/IO. Invalidations
  per request were exactly 1.00 in strict mode.

## Stage 1: device-granularity baseline

QEMU's stock `riscv_iommu_dma` trace event already fires on **every**
translation, IOATC hits included, with `(bus:dev.fn, pasid, dir, iova, phys)`.
`TRACE=riscv_iommu_dma` plus `qemu_trace_summary.py` gives per-device counts
with no patch. What's still missing is `DC.ta` RCID/MCID; see below.

## Stage 2: per-page bits (not started)

Where the code goes, as of the pinned versions:

- **QEMU** `hw/riscv/riscv-iommu.c`:
  - `riscv_iommu_spa_fetch()` decodes the leaf PTE. Extract the label here.
  - `riscv_iommu_translate()` has the IOATC. On a cache hit it never re-reads
    the PTE, so the label must also go into `RISCVIOMMUEntry` or hits lose it.
  - `riscv_iommu_memory_region_translate()` emits `trace_riscv_iommu_dma`.
    Add the label there (event definition in `hw/riscv/trace-events`).
- **Linux**: see findings 7–10 below. The PTE is built in
  `drivers/iommu/generic_pt/fmt/riscv.h`, not in the driver.

## Findings (pinned versions: QEMU v11.1.1, Linux v7.2.6)

These correct or sharpen the original plan. 1–3 came from getting the guest
to translate at all.

1. **RISC-V Linux never translates DMA-API traffic, even upstream.**
   `config IOMMU_DMA` is `def_bool ARM64 || X86 || S390` (unchanged in
   7.3-rc3). Without it, `iommu_get_default_domain_type()` forces IDENTITY,
   so the kernel prints `Default domain type: Translated` while every group
   is `identity`. That's exactly the "silently falls back to passthrough"
   failure the plan warned about. Fixed by `patches/linux/0001`, and
   `check-iommu.sh` catches it at runtime.
2. **MSIs break once domains translate.** The driver doesn't program MSI page
   tables (`msiptp`), and the IMSIC driver doesn't call
   `iommu_dma_prepare_msi()`, so device MSI writes fault. `patches/linux/0002`
   reports each hart's IMSIC S-file as an `IOMMU_RESV_DIRECT` region, and the
   core then maps it 1:1 in every DMA domain. This is prototype-quality: it
   blocks non-default (VFIO) domains and assumes guest index 0.
3. **The BPF JIT is off by default on riscv defconfig**
   (`BPF_JIT_ALWAYS_ON` unset, so `bpf_jit_enable=0`). Any non-trivial
   bpftrace program then fails with "requires BPF JIT compiler but it is not
   available". `configs/guest.config` turns it on.
4. **QEMU doesn't model QoS IDs at all.** There's no `capabilities.QOSID`, no
   `iommu_qosid` register, and `DC.ta` decodes only PSCID. There's no CBQRI
   controller model in the tree either. Stage 1 needs a small QEMU patch to
   parse RCID/MCID from `DC.ta`, and the CBQRI spec repo is the place to look
   for an out-of-tree model.
5. **Bits 60:54 fault in QEMU's IOMMU walker.** `riscv_iommu_spa_fetch()`
   rejects any PTE with `PTE_RESERVED(false)` (bits 60:54) set. "Use reserved
   60:54 for DMA-API domains" therefore needs a walker patch; it isn't free.
   RSW 9:8 is accepted and ignored.
6. **Svrsw60t59b: a third option, plus a QEMU bug.** QEMU advertises
   `CAP.Svrsw60t59b` (PTE bits 60:59 reserved for software) whenever `g-stage`
   is on, but the walker still calls `PTE_RESERVED(false)`. Setting 60:59
   therefore faults despite the capability. Fix the walker, and you get 2 more
   software bits (16 labels with RSW) that also survive shared page tables on
   CPUs with Svrsw60t59b.
7. **The Linux driver no longer has its own page-table code.** Since the
   generic_pt conversion, `drivers/iommu/riscv/` selects `GENERIC_PT`, and PTEs
   are built in `drivers/iommu/generic_pt/fmt/riscv.h`:
   - `riscvpt_iommu_set_prot()` turns `IOMMU_*` prot into PTE bits. This is
     the place to OR in a label carried in spare `prot` bits.
   - `riscvpt_install_leaf_entry()` writes the PTE.
   - `riscvpt_attr_from_entry()` masks RSW out, so a large-page split or
     re-install would **silently drop the label**. That's a plumbing bug to fix
     and a test case to write.
8. **NVMe doesn't go through `iommu_dma_map_page()`.** In 7.2, `nvme_map_data()`
   uses `blk_rq_dma_map_iter_start()`, which goes through `dma_iova_link()`,
   then `__dma_iova_link()`, then `iommu_map_nosync()`. The `dma:*`
   tracepoints don't fire on that path. `iommu:map` and `iommu_map_nosync`
   see everything, and `dma_info_to_prot()` / `__dma_iova_link()` is where a
   label would enter.
9. **Page → memcg is two hops in 7.2.** `folio->memcg_data` points to an
   `obj_cgroup`, not the memcg, so folios can be reparented: a page's owner
   can change under you when a cgroup dies. That matters for "tag the
   buffer".
10. **Split requests carry cloned bios.** They share the parent's
    `bi_io_vec` with `bi_vcnt == 0`. Anything that finds a request's pages
    (tracer or kernel label plumbing) must walk `bi_iter`, never `bi_vcnt`.
11. **`translate()` has no length.** QEMU's IOMMU `translate` callback gets
    an address, not an access size, and returns a ≤4 KiB `addr_mask`. The
    trace therefore counts translations (≈ pages touched), not bytes. Exact
    `bytes[label]` needs an intercepting `target_as` (the same trick the model
    uses for MSI with `trap_as`) or hooks in the device model.
12. **The HPM model is complete, but Linux has no driver for it.** QEMU
    implements 31 counters with DID/PID/DMASK filtering
    (`riscv-iommu-hpm.c`). Linux 7.2 has only register definitions, so read
    the counters from the BAR in the guest, or with `xp` in the QEMU monitor.
13. **NVMe SR-IOV is available** (`sriov_max_vfs`, `sriov_vq_flexible`,
    `sriov_vi_flexible`, `sriov_max_vi_per_vf`, `sriov_max_vq_per_vf`).
14. **Virtio bypasses the IOMMU without `iommu_platform=on`,** on both the
    QEMU and the guest-driver side.
15. **Debian nocloud images ship with root locked** (`!unprovisioned`), no
    sshd, and no network config, and `systemd-firstboot` blocks on the
    console. `mkimage.sh` edits the image offline with debugfs instead of
    fighting the console.

## Which PTE bits

| bits | labels | survives shared (SVA) tables | QEMU today |
|---|---|---|---|
| RSW 9:8 | 4 | yes (ignored by CPU MMU) | accepted, ignored |
| 60:59 (Svrsw60t59b) | 4 (16 with RSW) | yes, on CPUs with Svrsw60t59b | **faults** (walker bug, finding 6) |
| reserved 60:54 | 128 | no (faults CPU walks) | **faults** |

Start with RSW 9:8.
