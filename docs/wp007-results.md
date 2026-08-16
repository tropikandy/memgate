# WP-007 results — Cutover (2026-08-16, on-machine)

**Requirements satisfied:** R1, R5, R7, N1. **Depends on:** WP-006. **Gate:** WP-006's acceptance criteria green (all except N4, which was partially validated by decision — see `docs/measurements.md` — and this cutover proceeded anyway per explicit direction).

## What changed on the machine

1. Rehearsed `rollback.sh` once more immediately before cutover (T-15) — clean PASS.
2. `launchctl bootout` **and** `launchctl disable` on `com.local.mtplx-server` (the production MTPLX-4B LaunchAgent). `disable`, not just `bootout`, so it does not respawn on a future reboot even with `RunAtLoad`/`KeepAlive` both true in its plist (per C1: "unloaded and disabled, not re-pointed"). The plist file itself is untouched on disk — rollback material, per WP-001/`rollback.sh`.
3. `config/llama-swap.yaml` updated from scratch-port framing to production: now documented as listening on `127.0.0.1:8000`, both tiers, memgate wired in, `mtplx-exclusive` group.
4. llama-swap started on `127.0.0.1:8000` (manually for now — WP-008 wraps this in its own LaunchAgent so it survives login/reboot).

## Test results

| Test | Result |
|---|---|
| T-1 (config parses, right IDs) | PASS — `/v1/models` on :8000 lists both real IDs |
| T-13 (Hermes unmodified) | PASS — `~/.hermes/config.yaml` SHA-256 identical before and after cutover (`b5c80d74...`, matches the WP-001 baseline exactly), and a real chat completion through :8000 using Hermes's exact model ID (`mtplx-qwen35-4b-optimized-quality`) returned 200 with real content |
| T-16 (no dual supervision) | PASS — `launchctl list \| grep -i mtplx` empty while the gateway runs; the resident MTPLX process's PPID is llama-swap's own PID, confirming llama-swap started it, not an orphan |
| T-17 (warm latency vs. direct) | **FAIL against N1.** Median TTFT via gateway: 149.9ms. Direct to the internal backend port (bypassing llama-swap's proxy): 67.1ms. Delta ≈ 83ms, exceeding N1's 50ms budget. See below. |

## T-17 finding: gateway proxy overhead exceeds N1's budget

20 warm `max_tokens: 1` requests each way (`swapbench latency`), same
already-loaded 4B model, back to back:

- Via gateway (`:8000`, through llama-swap's proxy): median 149.9ms
- Direct to backend (`:9200`, bypassing llama-swap entirely): median 67.1ms
- **Delta: ~83ms**, vs. N1's "within 50ms of direct" budget.

**Not investigated further in this session** — root cause could be
llama-swap's own Go HTTP reverse-proxy overhead, its per-request activity
logging (`/api/metrics/activity`), or something else in its request path.
This is a real, measured gap against a stated non-functional target, not
glossed over: N1 is a soft UX target (not a safety gate like N3/N4), so
it does not block this cutover, but it's worth investigating separately
if warm-path latency matters for real usage. Re-measurable any time with:

```
python3 swapbench/swapbench.py --gateway http://127.0.0.1:8000 latency --model mtplx-qwen35-4b-optimized-quality --count 20
python3 swapbench/swapbench.py --gateway http://127.0.0.1:<internal-port> latency --model mtplx-qwen35-4b-optimized-quality --count 20
```

## Rollback

Rehearsed once more, immediately before this cutover (see above) — PASS.
`rollback.sh` restores `com.local.mtplx-server` (re-enables +
bootstraps), stops llama-swap, and verifies `/v1/models` on :8000
matches the WP-001 baseline. Not re-run after cutover (would defeat the
point), but its correctness was just re-confirmed against the exact
state cutover started from.

## Note per WP-007 step 5

Spec step 5 says "leave the machine running for one normal working day
before proceeding to WP-008." This session proceeded directly to WP-008
per explicit direction (get Phase 1 done now) rather than waiting a full
day. Flagged here as a deliberate deviation, not an oversight — normal
day-to-day usage after this point is exactly what would have filled that
waiting period anyway.
