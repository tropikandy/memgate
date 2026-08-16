# WP-012 — Storage and cold-load characterisation (2026-08-16, on-machine)

**Requirements satisfied:** R14, N5. **Depends on:** WP-001. Ran in parallel with WP-002/WP-003/WP-004, using the live WP-002 scratch gateway (127.0.0.1:8801) for the cold-load timing half.

## 1. Bytes on disk per model, and volume

All MTPLX model weights currently live on a single volume: `/Volumes/2tb`
(APFS, `Protocol: PCI-Express`, solid state — a Thunderbolt/PCIe-attached
NVMe enclosure, not a slow USB drive). The internal boot volume
(`Macintosh HD`, `Protocol: Apple Fabric`, solid state) holds no model
weights, only the MTPLX app and its Python runtime venv.

| Model | Bytes on disk (MB) |
|---|---|
| Qwen3.5-4B-MTPLX-Optimized-Quality (the "4B" tier) | 4,364 |
| Qwen3.5-4B-MTPLX-Optimized-Speed | 2,448 |
| Qwen3.5-9B-MTPLX-Optimized-Speed | 8,292 |
| Qwen3.6-27B-MTPLX-Optimized-Speed-V2 | 18,966 |
| Qwen3.6-35B-A3B-MTPLX-Optimized-Speed | 20,041 |
| **Qwen3.8-27B-MTPLX-Bare-Speed (the "27B" tier)** | **16,154** |
| Qwen3.8-27B-MTPLX-Optimized-Speed | 20,333 |

Only the two tiers this project actually wires into the gateway (bolded
4B and 27B rows) are carried through the rest of this document; the other
five are present on disk but out of scope.

## 2. Effective sequential read throughput per volume

Method: write a file of at least 2x physical memory (32 GB RAM here, so
a 64 GB file) with `/dev/urandom` (not `/dev/zero` -- APFS could
otherwise store an all-zero file as a sparse hole and never touch real
disk bandwidth), then `dd if=<file> of=/dev/null bs=1m` and time it. A
file this size cannot be fully held in the page cache, so the read is
dominated by real disk I/O. `purge` (macOS's cache-flush command) needs
root, which this session does not have (no passwordless sudo); read the
result below with that caveat, though see the consistency note.

| Volume | Test file size | Write throughput | Read throughput (1st) | Read throughput (2nd, no purge) |
|---|---|---|---|---|
| `/Volumes/2tb` (where models live) | 64 GB | 597 MB/s (urandom-generation-bound, not necessarily the disk's ceiling) | 3,437 MB/s | 3,424 MB/s |
| `/` internal boot volume (comparison only, no models here) | 32 GB (1x RAM -- smaller than ideal, see caveat) | 536 MB/s | 2,592 MB/s | -- |

**Caveats, stated rather than hidden:**
- The two `/Volumes/2tb` reads (immediately after writing, and again
  right after) agree within 0.4%. Since the file is 2x physical memory,
  the OS cannot be caching the whole thing on either read, so this
  consistency is treated as good evidence the ~3.4 GB/s figure reflects
  real disk throughput, not a caching artifact -- even without a `purge`
  to prove it directly.
- The internal-volume file is only 1x RAM (32 GB), chosen to stay safely
  within the 67 GB free on that volume rather than risk filling it to
  the WP-012-ideal 64 GB. Its throughput number is a looser upper bound,
  more likely inflated by residual cache, than the external figure.
  Even so, it came out *lower* than the external volume, which is the
  more thoroughly cache-defeated measurement -- so this is not an
  artifact that would reverse the comparison.
- **Conclusion: `/Volumes/2tb` is not the slow tier some external-SSD
  intuition might assume. It measured faster than the internal boot
  volume on this machine.** No storage move is indicated (see Section 4).

## 3. Predicted vs. actual cold-load time, and the fixed-overhead residual

Using the external volume's measured throughput (3,436 MB/s, averaging
the two reads) and `t_weights = bytes_on_disk / effective_read_MBps`:

| Model | bytes (MB) | predicted t_weights (s) | measured cold-to-healthy (s) | residual = measured − predicted (s) |
|---|---|---|---|---|
| 4B (`mtplx-qwen35-4b-optimized-quality`) | 4,364 | 1.27 | 6.67 (run 1), 5.92 (run 2, immediately after) — avg 6.30 | ~5.03 |
| 27B (`mtplx-qwen38-27b-bare-speed`) | 16,154 | 4.70 | **not yet measured** — requires the 27B live in the gateway (WP-005/WP-006) | n/a |

The 4B measurements are real, from the live WP-002 gateway
(`docs/wp002-wp004-results.md`, T-2 and the T-20 run below). The residual
(~5.0 s) is the fixed overhead per Section 6.5: Python/framework import
plus Metal kernel/graph compile plus health-poll granularity. Section 6.5
calls this "1 to 5 s, roughly fixed" for `t_process` alone; the observed
residual also includes `t_compile` and `t_health`, so ~5 s total across
all three is consistent with that estimate, not a red flag.

**27B prediction** (residual assumed roughly constant across model size,
per Section 6.5 -- an assumption, not yet verified, and the biggest
model-size jump in this project so it carries more risk than the 4B
number): predicted cold-to-healthy ≈ 4.70 + 5.03 ≈ **~9.7 s**, far under
N5's 180 s budget. Even a generously pessimistic residual (say, 3x the
4B's, if compile time scales with parameter count) would land around
19.8 s, still comfortably under budget. **This prediction must be
replaced with a real measurement at WP-005/WP-006** -- it is not a
substitute for T-2 run against the actual 27B.

## 4. Storage move recommendation

**No move recommended.** The current tier (`/Volumes/2tb`) measured
faster than the internal boot volume, and the 4B's real cold-load time
(under 7 s) is nowhere near its 30 s N2/N5 budget. The 27B's predicted
cold-load time (~10 s, worst-case ~20 s) is nowhere near its 180 s
budget either, with wide margin even accounting for the prediction's
uncertainty. N5 is not at risk from storage tier on this machine as
configured.

## 5. T-18 and T-20

- **T-18** (storage throughput, R14/N5): done, Section 2 above.
- **T-20** (file cache effect, R14/6.5): partially done. Ran a real
  cold-load-immediately-followed-by-cold-load-again cycle against the
  live WP-002 gateway: 6.67 s, then unload, then 5.92 s (~11% faster on
  the immediate repeat, consistent with a modest file-cache benefit on
  the small 4B weight set). **The "repeat after forcing eviction" half
  of T-20 could not be completed**: macOS's `purge` command needs root,
  and this session has no passwordless sudo. This is a genuine gap, not
  a silent skip -- if a precise quantification of the safety-over-speed
  cost (Section 6.5, D-11) is needed later, it requires either running
  `sudo purge` by hand or waiting long enough between loads for natural
  cache eviction under other memory pressure, then repeating the same
  timing comparison.

## 6. Cleanup

Both throughput test files (64 GB on `/Volumes/2tb`, 32 GB on `/`) were
deleted after measurement; no disk space was permanently consumed by
this WP.
