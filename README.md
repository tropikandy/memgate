# Local Model Gateway

One OpenAI-compatible endpoint for local MTPLX models, gatewayed through
[llama-swap](https://github.com/mostlygeek/llama-swap) with memory-safe
on-demand loading. Full design: `docs/Local-Model-Gateway-Build-Spec.md`.

## Status

This repository was scaffolded from a cold start in a remote/cloud
execution environment with **no access to the target Mac mini**. Most of
the spec's work packages (WP-001, WP-002, WP-005 through WP-012) require
commands run directly on that machine against real MTPLX processes, a
real `~/.hermes/config.yaml`, `launchctl`, and a real reboot. Those are
not attempted here. What exists in this repo:

| Path | What it is | Work package | Runnable now? |
|---|---|---|---|
| `bin/memgate` ([README](bin/README.md)) | Start-gate wrapper: blocks exec until memory clears a floor | WP-003 | Yes, fully tested (`tests/test_memgate.sh`) |
| `swapbench/swapbench.py` | Measurement + validation harness | WP-004, WP-017 | Needs a live gateway to point at |
| `memwarden/memwarden` | Yield lock + degradation ladder core (signals disabled) | WP-014 | Yes, lock/ladder logic tested (`tests/test_memwarden.sh`); unload calls need a live gateway |
| `warmup/warmup` | Cold-load warmup sidecar | WP-013 | Needs a live gateway to point at |
| `config/llama-swap.yaml.template` | IF-5 config, every value marked `«VERIFY»` | — | Template only; fill from WP-001/WP-005 captures |
| `memwarden/memwarden.yaml.example` | IF-6 config shape for WP-015/WP-016 | — | Reference only, not yet consumed |
| `scripts/baseline-capture.sh` | WP-001 steps 1-2 capture script | WP-001 | **Run this on the Mac mini next**, before touching anything else |
| `scripts/rollback.sh` | R12/T-15 one-command rollback | WP-001 step 4 | Run on the Mac mini; requires `docs/baseline/` to exist first |

## What to run on the Mac mini next

1. `scripts/baseline-capture.sh` -- captures `/v1/models`, the MTPLX
   argv, LaunchAgent plists, port inventory, `iogpu.wired_limit_mb`, and
   the Hermes config hash into `docs/baseline/`. This closes WP-001 step 1.
   WP-001 step 4 is `scripts/rollback.sh`, already written and waiting on
   `docs/baseline/` existing.
2. By hand, per the script's printed instructions: stop all model
   processes, wait 60s, sample `vm_stat` three times, and write the
   median into `docs/baseline/memory-floor.json` (WP-001 step 2). Derive
   the N3 ceiling from that floor plus the largest single-model footprint
   plus a stated safety margin.
3. Dry-run `scripts/rollback.sh` (T-15) so it's rehearsed before anything
   is changed for real.
4. Install `bin/memgate` to `/usr/local/bin/memgate` (or point the
   `memgate` macro in `config/llama-swap.yaml.template` at wherever it
   lives in this checkout).
5. Continue with WP-002 (llama-swap on a scratch port, 4B only) per the
   spec -- independent of the 27B command capture (C2).

## Running the tests that don't need the Mac mini

```
bash tests/test_memgate.sh
bash tests/test_memwarden.sh
python3 swapbench/swapbench.py validate --config tests/validate.example.json
```

## Design constraints this code follows

- Bash or Python 3 stdlib only, no third-party dependencies.
- No hardcoded paths, ports, model IDs, or process names outside
  overridable defaults and documentation examples (R13). Verify with:
  `grep -nE '/Volumes|andreas|8000|mtplx' bin/memgate memwarden/memwarden swapbench/swapbench.py warmup/warmup`
- `memgate` hands off with `exec`, never fork/wait (IF-3, T-6) -- this is
  what prevents an orphaned, fully-loaded MTPLX process surviving a
  llama-swap SIGTERM.
- `memwarden`'s WP-014 scope ships with every inferred signal disabled;
  only the explicit lock (file, HTTP, CLI) drives the ladder. Inferred
  signals are WP-015, and should not be added here until Phase 1 has run
  for a normal working week on the real machine (see the spec's Section
  13 handoff prompt).
