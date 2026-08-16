# WP-005 results (2026-08-16, on-machine)

**Requirements satisfied:** R6. **Depends on:** nothing, done opportunistically once a live 27B run was available.

## What was done

1. Started the 27B (`mtplx-qwen38-27b-bare-speed`) standalone, mirroring
   the operator's original bare-test command exactly except for `--host`/
   `--port` (moved to a scratch port, 18027, so it could not collide with
   or disrupt the production 4B on 8000). Full capture:
   `docs/baseline/27b-argv.txt` (gitignored, local-only, like the rest of
   `docs/baseline/`).
2. Captured `/v1/models` on the 27B port: `mtplx-qwen38-27b-bare-speed`.
3. Recorded the resident footprint (see "Important finding" below and
   `docs/baseline/n3-ceiling-derivation.md`, which was revised with this
   real measurement).
4. Filled the 27B `«VERIFY»` markers in `config/llama-swap.yaml`, changing
   only `--host`/`--port`. Verified the resulting config parses and both
   model IDs are correctly advertised via `/v1/models` (no model loaded,
   `mtplx-exclusive` group added per R4).
5. Resolved the bare-vs-MTP ambiguity: **`--generation-mode mtp` and
   `--depth 3` are both present.** "Bare" in "Bare-Speed" does not mean
   MTP speculative decoding is disabled — it's active. "Bare" most likely
   distinguishes this weight variant from the also-present
   "Optimized-Speed" 27B variant, not an MTP/non-MTP split.

## Important finding: a real memory-pressure event during this WP

At the time this WP ran, the production 4B (port 8000) and the WP-002
scratch 4B (port 9200, still resident under its own ttl) were both
already up. Adding the standalone 27B on top pushed the machine to:

- PhysMem: ~31 G used out of 32 G total, 389 MB → 119 MB unused
- `kern.memorystatus_vm_pressure_level`: 1 (normal) → **2 (warn)**
- System-wide free memory: 17%

This was **not a deliberate stress test** — it's what happens when a
27B load lands on a machine that already has two 4B-class processes
resident, which is exactly the scenario N3/N4/memgate exist to prevent
once the real gateway enforces one-model-at-a-time (R4). The standalone
27B process was stopped (clean SIGTERM, 2s, no orphan) as soon as the
footprint was captured, and pressure returned to normal (1) immediately.
No damage done, but it's a real, on-this-machine confirmation of the risk
the spec's Section 5 describes (the 2026-08-04 panic), not a hypothetical.

**Measured 27B incremental footprint: ~17 GB** (PhysMem delta, two 4B
processes resident throughout, so not a clean single-model number — see
`docs/baseline/n3-ceiling-derivation.md` for the full writeup and the
revised N3 = 27,348 MB, down from the WP-001 guess-based 30,943 MB).

**Also notable:** the 27B process's own `ps` RSS read only ~5.9 GB,
far below the ~17 GB real system-wide delta. MTPLX's GPU/Metal-wired
memory on this unified-memory architecture isn't counted in process RSS.
`vm_stat`/`top` PhysMem — which memgate, memwarden, and swapbench all
already use — is the correct measurement; `ps RSS` alone would have
badly undercounted the real footprint.

## What's still open (deferred to WP-006 on purpose)

- A clean, single-model-only footprint measurement (production LaunchAgent
  stopped first, per WP-006's own steps).
- An actual completion routed through the gateway to the 27B entry
  (R6's full acceptance: "cold, with no prior warm-up," through the
  gateway, not standalone). Held back here specifically to avoid another
  three-models-resident memory event before WP-006 has memgate wired in.
- Sustained-load footprint (T-11 proper, both tiers) and the real
  4B↔27B swap timings (T-5, T-9, T-10) — all WP-006.
