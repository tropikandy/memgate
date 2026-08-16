# WP-006 results (2026-08-16, on-machine)

**Requirements satisfied:** R4, N2, N3, N4. **Depends on:** WP-002, WP-003, WP-004, WP-005 (all done).

Production MTPLX-4B LaunchAgent (`com.local.mtplx-server`) stopped for
the duration (`launchctl bootout`), confirmed no orphan, restored at the
end. `config/llama-swap.yaml` updated: memgate wired in with per-tier
floors (see commit `e4d9e1b`), listening on the scratch port (8801),
production port 8000 untouched throughout except while stopped.

## A real miscalibration found before any test ran

The plan was to set memgate's floor to "the WP-001 idle floor's available
memory" (24,876 MB). In practice this blocked *every* load, including
the 4B, because real available memory on this actively-used machine
(this Claude Code session included) sits around 17,000-23,000 MB during
normal work, not the pristine WP-001 idle-floor state. Fixed by splitting
into per-tier floors sized to each model's actual measured incremental
need plus a margin (10,240 MB for 4B, 20,480 MB for 27B) — see the commit
message on `e4d9e1b` and `docs/baseline/n3-ceiling-derivation.md` for the
full reasoning. This is a real, generalizable finding: **"return to the
pristine idle floor" is the wrong bar for memgate's floor** on a machine
that's actually in use; "enough headroom for this specific model's real
footprint" is the right one.

## T-11 — sustained single-model footprint (clean, both tiers)

| Model | peak_physmem_mb | min_available_mb | overlap_observed |
|---|---|---|---|
| 4B | 15,701 | 16,796 | false |
| 27B | 26,642 | 5,612 | false |

27B's peak sets the (revised) N3 ceiling: 27,348 MB (706 MB margin at
measurement time). Full derivation: `docs/baseline/n3-ceiling-derivation.md`.

## T-5 / T-10 — 20 alternating swaps

All 20: `overlap_observed: false`. `peak_physmem_mb` range 25,487-26,240
(avg 25,907) across every swap — consistently close to the clean
single-model 27B peak, never approaching a "both models stacked" figure
(~42 GB), which is itself strong evidence memory reclamation keeps pace
with the new load rather than piling on top of it.

`t_target_healthy_ms`: 4B 8,745-8,837ms (tight, consistent); 27B
13,471-19,543ms (more variance, still far under N2's 180s budget).

**A-2 verdict:** memory reclamation completes fast enough that swap
peaks never show a stacked-footprint spike — this is the strongest
available evidence, and it points toward "reclamation is not the
bottleneck," i.e. memgate is a safety net for the general case (A-2's
open question) rather than something load-bearing in every observed
swap here. **Caveat, stated plainly:** the finer-grained
`t_source_pid_gone_ms` vs `t_target_pid_seen_ms` ordering (meant to
answer A-2 more precisely) is **not fully reliable** with the current
proc-pattern, which cannot distinguish which model a matching PID
belongs to. 2 of 20 records show the derived "target seen" timestamp
before "source gone" in the 27B→4B direction (4B starts fast; 27B's
teardown takes a bit longer, and the pattern can't tell them apart
within the same ~1Hz sample window). This is very likely a measurement
artifact, not a real R4 violation — `overlap_observed` (a more reliable,
per-sample len(pids)>1 check, model-identity-independent) stayed false
in all 20 records, including those 2. A model-aware fix (attributing
PIDs to models via port, not just process name) would resolve this
precisely; not done here, flagged as a real limitation for a future WP.

`t_memory_floor_reached_ms` stayed `null` throughout (now implemented,
see commit `e4d9e1b`, gated behind `--floor-mb`): expected, not a bug —
during back-to-back swapping, memory never actually returns to the true
idle floor (7,892 MB) because a model is resident again within seconds.
The field will populate meaningfully in a scenario with real idle gaps
between loads (e.g. normal usage with a real `ttl`), not a rapid-swap
stress test.

## T-9 — swap stall under queue (C6)

No dedicated swapbench mode for this; built manually. Warmed the 4B,
fired 5 concurrent 4B completions (each ~200 tokens, building a real
queue given `--max-active-requests 1 --scheduler-mode serial`), and
immediately (not waiting) fired one 27B escalation request.

- The 5 queued 4B requests completed serially, ~5.7-5.8s apart each
  (5.8s, 11.9s, 17.7s, 23.9s, 29.5s from start) — confirms serial,
  single-request processing exactly as `--max-active-requests 1`
  implies.
- The 27B escalation request: **48.7s wall time**, versus 13.5-19.5s for
  a standalone cold 27B load (T-5). **The extra ~30-35s is real queueing
  delay**, not cold-load time — this is C6, confirmed with a number, not
  hoped about.

**Recommended consumer client timeout** (per C6's original ask): the
27B's own worst-case cold load here was ~19.5s; add a queue-drain
allowance sized to whatever burst depth a consumer might realistically
produce. This single test used a 5-deep burst and saw ~30s of pure queue
delay — a consumer client timeout under roughly 60-90s risks spurious
failures under any real queueing, and should be set well above the
27B's N2 budget (180s) plus a queue-depth allowance, not just above the
180s cold-load figure alone.

## T-12 — 60-minute soak

Launched, results appended once complete (see the follow-up commit).
