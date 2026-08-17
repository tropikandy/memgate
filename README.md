# Local Model Gateway

One OpenAI-compatible endpoint for local LLMs, running on demand instead
of sitting resident in memory all the time. A request naming a model
gets it loaded, health-checked, and proxied to; the model unloads again
after it's been idle, and a start-gate refuses to load anything until
there's actually enough free memory for it — so switching between a
small fast model and a large one never risks the OS thrashing or a
memory-pressure crash from two big models loaded at once.

Built around [llama-swap](https://github.com/mostlygeek/llama-swap)
(adopted as-is, unmodified) as the gateway, with a handful of small,
dependency-free companion tools that llama-swap alone doesn't provide.

## What's in here

| Component | Role |
|---|---|
| **llama-swap** | The gateway itself. Owns the well-known port, starts/stops backend model processes, proxies requests, enforces one-model-at-a-time. Not part of this repo — installed separately. |
| [`memgate`](bin/README.md) | A tiny start-gate wrapper. Refuses to launch a model process until measured free memory actually clears a floor (and an optional yield lock, if held, blocks it too). Sits in front of llama-swap's launch command for each model. |
| `memwarden` | A small daemon that owns an explicit "yield" mechanism: any process — no client library needed — can create a lock file to tell the gateway to drain and unload everything right now and refuse new loads, then remove it to resume normal service. Also exposes the same over HTTP and a CLI. |
| `warmup` | A cold-load sidecar. Fires a throwaway completion against a model right after it starts, in the background, so the *first real* request doesn't pay Metal/CUDA kernel-compilation cost. |
| `swapbench` | A measurement and validation harness — times cold loads, swaps between models while sampling memory and process state, and can run a fixed pass/fail suite against a live install. |
| [`app/GatewayMenuBar`](app/GatewayMenuBar/README.md) | An optional native macOS menu bar app: live status at a glance, pause/resume model loading, restart the gateway. Talks to the gateway and memwarden over plain HTTP, nothing special. |

All of the above (except the menu bar app, which is Swift) are bash or
Python 3 stdlib only — no third-party dependencies anywhere.

## Why

Running two large local models resident at once on a single machine
with unified/shared memory is a real way to crash it, not a
hypothetical — that's the whole reason this exists. The gateway itself
(llama-swap) guarantees only one model process runs at a time, but the
OS doesn't necessarily reclaim the outgoing model's memory before the
next one starts loading, and nothing coordinates with *other* memory
pressure on the machine (another app, a browser with too many tabs,
whatever). `memgate` and `memwarden` are the two pieces that close that
gap: one refuses to load until there's room, the other gives every other
app on the machine a zero-effort way to say "not right now."

## Getting started

1. Install llama-swap (a release binary or `brew install
   mostlygeek/llama-swap/llama-swap` both work).
2. Write a config for your own models — see `config/llama-swap.yaml.template`
   for the shape (every value marked `«VERIFY»` needs filling in from
   your own setup: model paths, ports, the exact model ID your existing
   consumers already send, so nothing on the client side has to change).
3. Point `memgate` at each model's launch command (see the template),
   set a `--require-free-mb` floor sized to that model's real memory
   footprint plus a safety margin.
4. Optionally wire in `memwarden` (`memwarden/memwarden.yaml.example`
   documents the config shape) and the `warmup` sidecar.
5. Run `swapbench --validate` against the live gateway to get a
   pass/fail readout instead of just hoping it works.

`docs/Local-Model-Gateway-Build-Spec.md` is the full design doc —
requirements, interfaces, the memory-arbitration design, and the test
plan this was built and validated against. `docs/measurements.md` and
the other `docs/wp0*-results.md` files are the engineering log from
building and validating this against a real deployment: real bugs
found, real numbers measured, not just what was planned.

## Running the tests

```
bash tests/test_memgate.sh
bash tests/test_memwarden.sh
python3 swapbench/swapbench.py validate --config tests/validate.example.json
```

## Design constraints this code follows

- Bash or Python 3 stdlib only, no third-party dependencies (the menu
  bar app is the one exception — native Swift/SwiftUI, see its own
  README).
- No hardcoded paths, ports, model IDs, or process names in `memgate`,
  `memwarden`, or `swapbench` outside overridable defaults and
  documentation examples. Verify with:
  `grep -nE '/Volumes|/Users/[a-z]+|8000|mtplx' bin/memgate memwarden/memwarden swapbench/swapbench.py warmup/warmup`
  `bin/memgate` and `warmup/warmup` should come back empty (enforced by
  `tests/test_memgate.sh`'s T-8). `memwarden` and `swapbench.py` will
  each show one hit — `DEFAULT_GATEWAY_URL = "http://127.0.0.1:8000"`
  and `--proc-pattern` defaulting to `mtplx` respectively — both plain
  CLI-overridable defaults, not something a fork has to edit source to
  change.
- `memgate` hands off with `exec`, never fork/wait — this is what
  prevents an orphaned, fully-loaded model process surviving a
  supervisor's `SIGTERM` to the wrapper instead of the real workload.
- `memwarden` ships with every *inferred* pressure signal (memory
  pressure level, GPU utilization, priority-process detection) off by
  default. Only the explicit lock — file, HTTP, or CLI — drives it out
  of the box. Inferred signals are a deliberate, separate opt-in, meant
  to be tuned from real observed behavior on your machine rather than
  guessed at.

## License

MIT — see [LICENSE](LICENSE).
