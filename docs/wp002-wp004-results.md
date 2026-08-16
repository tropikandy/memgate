# WP-002 and WP-004 results (2026-08-16, on-machine)

## WP-002 — llama-swap on a scratch port, 4B only

- llama-swap `v250 (60226b6)`, installed from the GitHub release binary
  (`mostlygeek/llama-swap`, darwin_arm64) to `~/.local/bin/llama-swap`.
  Homebrew has a tap (`mostlygeek/llama-swap`) but building from source
  failed on this machine's Xcode version; the release binary is ad-hoc
  signed and runs fine, no quarantine issue.
- `config/llama-swap.yaml`: 4B only, `memgate` macro empty (per WP-002
  scope-out), listening on `127.0.0.1:8801` via `-listen`. Port 8000 and
  the production MTPLX-4B LaunchAgent were left running untouched
  throughout, as the WP specifies.
- **Gotcha found and fixed:** llama-swap's `cmd` field splits on
  whitespace. The MTPLX interpreter path
  (`.../Application Support/MTPLX/runtime-venv/bin/python`) contains a
  space, so the bare macro reference `${mtplx_python}` failed to exec
  (`fork/exec ... no such file or directory`, splitting at "Application").
  Fixed by quoting the macro at its use site: `"${mtplx_python}"`. See the
  comment in `config/llama-swap.yaml`.
- IF-2 (management routes) verified against the real binary and corrected
  in the spec (Section 7, IF-2) — several routes differ from the original
  draft: `/api/metrics/activity` (not a bare `/api/metrics`), plus
  `/api/performance`, `/api/version`, `/logs/stream`, `/ui`, none of which
  were in the original assumed set.

### Test results

| Test | Result |
|---|---|
| T-1 (config parses, right ID) | PASS — `GET :8801/v1/models` returns `mtplx-qwen35-4b-optimized-quality`, exact match to `docs/baseline/models.json` |
| T-2 (cold load, 4B) | PASS — HTTP 200, cold-to-response in ~7s, well under N2's 30s budget |
| T-3 (idle unload) | PASS — verified with a temporary ttl=10s/unloadTimeout=5s override (not the real 900s/30s, to avoid a 15-minute wait): model exited cleanly after ttl+unloadTimeout, `/v1/models` reported `status.value: "unloaded"`, no orphan process (confirmed by PID inspection, not just the API's word for it) |

## WP-004 — swapbench, sanity run against the live WP-002 gateway

Ran `swapbench single --model mtplx-qwen35-4b-optimized-quality --duration 30`
against `http://127.0.0.1:8801`. Output (valid IF-4-shaped JSONL):

```json
{"ts": "2026-08-16T15:26:19Z", "model": "mtplx-qwen35-4b-optimized-quality", "peak_physmem_mb": 24499, "min_available_mb": 8865, "overlap_observed": true}
```

**`overlap_observed: true` here is correct, not a bug, and not a real R4
violation.** At the time of the sample there were genuinely two `mtplx`
processes matching the broad `mtplx.server.openai` proc-pattern: PID 64781
(the production 4B on port 8000, pre-existing, untouched, exactly as
WP-002 leaves it) and PID 68199 (the WP-002 scratch instance's own child
on port 9200+). Confirmed directly via `ps`, not just swapbench's own
report. Because both processes were the same model, `peak_physmem_mb`
(24499 MB) is inflated by roughly double a single instance's real
footprint and **is not a usable number for the N3 ceiling** — it is
discarded, not used to update `docs/baseline/n3-ceiling-derivation.md`.

**Operational implication for WP-006:** this is exactly why WP-006's own
steps already require stopping the production MTPLX-4B LaunchAgent before
running T-11/T-5/T-10/T-12 — "the first point where full memory safety is
required" per the spec. Confirmed here as a real, reproducible effect
rather than a theoretical concern. No code change needed in swapbench
itself: broad process-pattern matching is the correct behavior for
catching a genuine R4 overlap, and the false-positive-in-this-context is
purely a function of the production instance still being alive, which is
intentional and temporary during Phase 1.

Otherwise the run confirms swapbench's mechanics work end to end against
a real gateway: correct JSONL shape, correct PID discovery, correct
`vm_stat`-derived PhysMem sampling.
