# WP-013 results — Warmup sidecar (2026-08-16, on-machine)

**Requirements satisfied:** R15. **Depends on:** WP-007.

## Real bug found and fixed while wiring this up

The original plan was `MEMGATE_PREEXEC_CMD="..." ${memgate_4b} ...` as an
inline shell env-var prefix in the YAML `cmd` field. This broke
production cold-loads outright (500s: `fork/exec MEMGATE_PREEXEC_CMD=...:
no such file or directory`) — **llama-swap's `cmd` field does not go
through a shell.** It does its own whitespace/quote-aware word-splitting
and `fork/exec`s argv[0] directly, so `VAR=value` shell-assignment syntax
is meaningless there; llama-swap just tried to exec the literal string
`MEMGATE_PREEXEC_CMD=...` as a path.

**Fix:** added a real `--preexec-cmd CMD` flag to `bin/memgate` itself
(alongside the existing `MEMGATE_PREEXEC_CMD` env var, kept for callers
that do go through a shell, e.g. tests). llama-swap's config now passes
`--preexec-cmd "<quoted warmup command>"` as a proper argument, which its
quote-aware splitting handles correctly (same mechanism already proven
in WP-002 for the interpreter path containing a space).

This surfaced during debugging of an unrelated, much larger incident
(the LaunchAgent cold-load hang, see `docs/wp008-results.md`) — both are
independently real, independently fixed.

## What was done

- `bin/memgate`: `--preexec-cmd` flag added, `MEMGATE_PREEXEC_CMD` kept
  as a fallback. `tests/test_memgate.sh` still passes (T-6/T-7/T-8).
- `config/llama-swap.yaml`: both tiers now launch the warmup sidecar in
  the background before exec, health-polling then firing one minimal
  completion against the model's own internal port.
- Confirmed live: the warmup process (`warmup/warmup`) actually spawns
  as a child of memgate during a real cold load (`ps` showed it mid-load,
  targeting the correct port), not just configured-but-inert.
- T-6 still holds with the sidecar wired in: memgate still hands off via
  `exec`, the warmup process is backgrounded and detached, not part of
  the exec chain.

## T-19 (warmup effectiveness): honest result, not the expected one

Compared MTPLX's own server-reported `ttft_s` (time-to-first-token,
precise, not a network-latency proxy) across three conditions for the
4B tier:

| Condition | ttft_s |
|---|---|
| Cold load, warmup sidecar ON | 0.1574 |
| Warm (model already resident) | 0.1523 |
| Cold load, warmup sidecar OFF (scratch port, no `--preexec-cmd`) | 0.1504 |

**All three are within ~5% of each other.** R15's acceptance criterion
(cold TTFT within 20% of warm TTFT) is met — but it's met *regardless*
of whether the warmup sidecar runs at all. For the 4B tier on this
hardware, Metal kernel compilation isn't a measurable contributor to
TTFT in the first place, so there's no real "cold penalty" for the
sidecar to eliminate here.

**Not a wasted feature, and not disabled** — the sidecar is real,
correctly wired, and does exactly what IF-7 specifies (background health
poll + one throwaway completion, never blocking exec, degrades to a
slightly slower first request on failure rather than an outage). It's
just that this particular measurement shows its benefit is negligible
for the 4B tier specifically. The 27B tier — larger, more kernel
machinery (MTP speculative decoding, adaptive policy) — is the more
likely candidate to show a real compile-time cold penalty, but wasn't
separately measured in this session (time budget). Worth re-measuring
against the 27B if warmup's value is ever in question.
