# Local Model Gateway — Build Spec

**Status:** implemented and deployed (Phase 1 complete, see Section 9's session notes for what's done).
**Target machine:** a single machine running local models with unified/shared memory (validated on Apple Silicon macOS, 32 GB RAM) — no second box, no cluster.
**Derived from:** `Local-Model-Gateway-Research-Brief.md` (research and decisions, superseded by this document for anything that conflicts).

Conventions used here:

- `«VERIFY: x»` marks a value that must be read off the live machine before it is written into a config file. An implementing agent must never invent a value behind one of these markers.
- Stable IDs: requirements `R#`, interfaces `IF-#`, tests `T-#`, work packages `WP-###`, decisions `D-#`, open assumptions `A-#`.

---

## 1. Outcome

One OpenAI-compatible endpoint on this machine. No model resident at idle. Whichever MTPLX model a request names is started on demand, health-checked, proxied to, and torn down after an idle timeout. Never two models resident at once.

### 1.1 Success criteria

1. Boot to steady state with **zero** model processes running and PhysMem at the machine floor.
2. A request naming the 4B model gets a correct response, and PhysMem returns to floor within `ttl + unloadTimeout` of the last request.
3. A request naming the 27B model while the 4B is resident produces a correct response with peak PhysMem during the transition below the safety ceiling (N4).
4. Hermes works with **no edit to `~/.hermes/config.yaml`**.
5. DeepSeek bridge, `consult-deepseek`, and VaultScribe behave identically to before, with no config change.
6. A documented rollback returns the machine to its current state in under five minutes.

### 1.2 Non-goals

- Predictive or semantic model **pre-loading**, meaning guessing which model you will want next and warming it. Still rejected (D-6). Note the asymmetry: *inferring that the machine is busy and yielding memory* is a different and much safer thing, and is in scope (D-8).
- A custom dashboard or web UI. llama-swap's own log and event endpoints are the monitoring surface for v1.
- Bringing DeepSeek, `consult-deepseek`, or VaultScribe/WhisperKit under the gateway. They are not competing for the same resident-model memory.
- Replacing MTPLX, or reintroducing mlx-dspark (D-2).
- A general multi-machine deployment tool. Genericity applies to code shape (R13), not to shipping a product.

---

## 2. Component map

| Component | Role after this change |
|---|---|
| **MTPLX** | The inference engine. Both tiers run through it. Its processes are started and stopped **by llama-swap only**. |
| **llama-swap** (mostlygeek/llama-swap, Go, adopted as-is) | The gateway. Owns port 8000, owns MTPLX process lifecycle, enforces one-model-at-a-time. |
| **memgate** (new, small, generic) | A start-gate wrapper. Refuses to exec the inference command until measured free memory clears a floor, and until no yield lock is held. Stays deliberately dumb: one decision, no daemon, no state. |
| **memwarden** (new, small, generic) | The arbiter daemon. Owns the yield lock, watches system memory pressure and GPU utilisation, watches a configurable priority-process list, and drives the degradation ladder (Section 6.4). This is the piece that makes the gateway a good citizen among non-LLM apps. |
| **warmup sidecar** (new, tiny) | Launched in the background by memgate just before exec. Polls the model's health path, then fires one throwaway minimal completion so the first *real* request does not pay Metal kernel compilation and graph setup. |
| **swapbench** (new, small, generic) | A measurement harness. Answers A-2, A-3, A-8 with numbers instead of assumptions, and doubles as a rerunnable install validation suite (`--validate`). |
| **Model storage** | Weights currently live on an external SSD. Storage tier is the dominant term in cold-load time, so it is a first-class tunable here, not an incidental detail (Section 6.5). |
| **Hermes** | Consumer. Unchanged. |
| **Conductor** | Consumer plus a local coding harness. Its own app-level mutual exclusion becomes redundant (see WP-010). |
| **DeepSeek bridge / `consult-deepseek` / VaultScribe** | Out of scope. Must be provably untouched. |
| **mac-memory-guard** | Optional whole-machine safety net. Not model-aware, complements rather than substitutes. |

---

## 3. Corrections to the research brief

**C1. MTPLX is no longer launchd-managed.** llama-swap **starts MTPLX itself** using `cmd`, and allocates internal ports automatically via `${PORT}` and the global `startPort`. The existing MTPLX LaunchAgents must be **unloaded and disabled**, not re-pointed. Their plists are kept as the source of the real launch command and as rollback material.

**C2. The 27B launch command does not block the whole rollout.** It blocks only WP-005 onward. WP-001 through WP-004 (baseline capture, gateway standing up on a scratch port with the 4B only, memgate, swapbench) are all independently completable today.

**C3. Model ID compatibility is the real zero-edit risk.** Hermes sends a literal `model` string. llama-swap routes on that string against its config keys and `aliases`. If the gateway's IDs differ by even one character from what MTPLX-4B currently advertises, "zero consumer edits" fails at the first request. Capturing the current `/v1/models` output is therefore a gating step (WP-001), and matching it is a hard requirement (R5).

**C4. Endpoint names in the brief look stale.** Current llama-swap exposes management under `/api/...` (`/api/models/unload`, `/api/models/unload/:id`, `/api/events` for SSE, `/api/metrics`). Treat all management paths as `«VERIFY: against the installed binary's own docs and /api routes»` rather than hardcoding either set.

**C5. The default stop grace period is short.** llama-swap's default POSIX stop is SIGTERM followed by forceful termination after roughly 5 seconds. MTPLX runs with `--ssd-session-cache on`, so a SIGKILL mid-flush risks a corrupt session cache. Set `unloadTimeout` explicitly per model (Section 7).

**C6. Swap stall is an unlisted operational risk.** MTPLX runs `--scheduler-mode serial --max-active-requests 1`. Conductor's fast tier is a worker *pool*, so requests already queue at the backend. Add a swap on top and a 27B escalation arriving mid-queue waits for the 4B queue to drain, then for a 27B cold load. Worst case is minutes. Consumers need generous client timeouts, and this must be measured (T-9), not hoped about.

---

## 4. Requirements

### Functional

| ID | Requirement | Acceptance criteria |
|---|---|---|
| **R1** | All local-LLM consumers reach exactly one OpenAI-compatible base URL. | `curl $GATEWAY/v1/models` lists both MTPLX models. No consumer config references an MTPLX port directly. |
| **R2** | No model process is resident at idle or at boot. | After login and 5 minutes of no traffic, `pgrep -f mtplx` returns nothing, and PhysMem is within 500 MB of the recorded floor. |
| **R3** | A model unloads automatically after a configurable idle period. | After the last request plus `ttl`, the MTPLX process exits and PhysMem returns to floor. Measured, not assumed. |
| **R4** | Two MTPLX model processes are never resident simultaneously. | Across 20 alternating 4B/27B requests, a sampler at 1 Hz never observes two `mtplx` PIDs at once. |
| **R5** | Existing 4B consumers require zero config edits. | Gateway listens on the port MTPLX-4B uses today, and serves the exact model IDs captured in WP-001 (as config key or alias). Hermes runs unmodified. |
| **R6** | The 27B model is reachable by name through the same endpoint. | A chat completion naming the 27B ID returns a valid response, cold, with no prior warm-up. |
| **R7** | llama-swap is the sole owner of MTPLX process lifecycle. | No MTPLX LaunchAgent is loaded. `launchctl list \| grep -i mtplx` is empty. Killing llama-swap leaves no orphan `mtplx` processes. |
| **R8** | Out-of-scope systems are untouched. | DeepSeek bridge, `consult-deepseek`, and VaultScribe pass their smoke checks with zero config diffs. |
| **R9** | The gateway starts on login. | After reboot and login, `curl $GATEWAY/v1/models` succeeds without manual intervention. |
| **R10** | A model process does not begin loading while free memory is below a configurable floor. | memgate blocks the exec and logs the reason when free memory is under the floor; passes through immediately when above. Unit-tested with a stubbed memory reader. |
| **R11** | Loaded state, swap timings, and memory are observable without custom UI. | `swapbench` emits a machine-readable record per swap, and llama-swap's own log and event endpoints are documented in the runbook. |
| **R12** | A one-command rollback exists. | `rollback.sh` re-enables the MTPLX LaunchAgents, stops llama-swap, and restores the original port binding. Rehearsed once before cutover. |
| **R13** | Custom code is generic. | memgate, memwarden and swapbench take all paths, ports, model IDs, process names, and thresholds as arguments, env vars, or a config file. Grep for `/Volumes/`, a hardcoded home directory path, `8000`, `mtplx` in their source returns nothing outside example blocks and overridable defaults. |
| **R14** | Cold-load time is characterised against storage tier, not just measured once. | Weight page-in throughput is measured for each storage location in use. Time-to-healthy is reported as a function of bytes-on-disk and measured MB/s. |
| **R15** | The first real request after a cold load does not pay warmup cost. | With the warmup sidecar enabled, TTFT of the first real request after a cold load is within 20% of a warm request's TTFT. Measured both ways. |
| **R16** | Idle-unload aggressiveness is tiered, not a single constant. | Each model has a normal `ttl` and a reduced `ttl` applied under pressure. Under a yield condition the effective TTL drops without a gateway restart. |
| **R17** | Any application can request that the gateway release memory, without speaking HTTP. | Creating the lock file causes all models to drain and unload within the configured grace period, and blocks new loads. Removing it restores normal service. |
| **R18** | The gateway yields on inferred pressure, not only on request. | memwarden raises the ladder when any of: macOS memory pressure level leaves normal, a configured priority process appears or exceeds its RSS threshold, or GPU utilisation from another client exceeds a threshold for a sustained window. Each signal is independently enableable and independently testable. |
| **R19** | Yielding is graceful, never abrupt, unless the system is critical. | At ladder levels 1 to 3 no in-flight request is killed: models drain first, then unload. Only level 4 (critical pressure) may terminate mid-response, and doing so is logged loudly with the triggering measurement. |
| **R20** | Yield and load events are logged in a form suitable for later pattern analysis. | An append-only JSONL event log records every load, unload, yield, release, and the triggering signal values. No automated behaviour is derived from it in v1 (D-8). |
| **R21** | Installation can be validated on demand, with a pass/fail verdict. | `swapbench --validate` runs a fixed suite against the live gateway and exits 0 or 1, printing which criteria failed and by how much. |

### Non-functional

| ID | Requirement | Acceptance criteria |
|---|---|---|
| **N1** | Warm-path latency is not meaningfully worse than direct. | Median TTFT via gateway is within 50 ms of direct-to-MTPLX, over 20 warm requests. |
| **N2** | Cold-start budget. | 4B cold to healthy under 30 s. 27B cold to healthy under 180 s. `healthCheckTimeout` set above both with margin. |
| **N3** | Swap peak memory ceiling. | Peak PhysMem observed at 1 Hz across any 4B↔27B swap stays below the ceiling defined in WP-001. |
| **N4** | No unattended memory-pressure panic. | 60-minute alternating-load soak completes with no panic and no swap-death, and peak PhysMem never breaches N3. |
| **N5** | Cold-load budget, stated per storage tier. | 4B under 30 s and 27B under 180 s from the tier they actually live on. |
| **N6** | Yield responsiveness. | From lock file creation or a sustained pressure signal to all models unloaded: under 20 s when idle, under `unloadTimeout` plus the in-flight request's remaining time when busy. |
| **N7** | Coexistence, measured not assumed. | With a realistic competing workload running, a 4B request either succeeds or is cleanly refused with a clear reason. Never contributes to a panic, never leaves an orphan process. |

---

## 5. Constraints

- macOS on Apple Silicon, ARM64. 32 GB unified memory, no discrete VRAM.
- `iogpu.wired_limit_mb=27648` persisted via LaunchDaemon; did **not** prevent the 2026-08-04 panic. Partial mitigation only.
- llama-swap is adopted unmodified. No forking, no patches.
- MTPLX launch flags are production-tuned and copied verbatim from the live plist.
- New code is bash or Python 3 with no third-party dependencies.
- Written output style: no em dashes.

---

## 6. Architecture

### 6.1 Port and process topology

llama-swap listens on `127.0.0.1:8000` (well-known, unchanged for consumers). It starts/stops/proxies memgate-wrapped MTPLX processes on internal ports allocated from `startPort` (9200+). At most one of the two MTPLX processes (4B, 27B) is resident at any instant. DeepSeek bridge, `consult-deepseek`, and VaultScribe/WhisperKit remain untouched, separate address space and lifecycle.

### 6.2 Swap sequence and where each guarantee comes from

| Step | Mechanism | Guarantee | Confidence |
|---|---|---|---|
| Request arrives naming model B while A is resident | llama-swap router | Routing is by the `model` field | Confirmed |
| In-flight requests to A drain | llama-swap tracks active requests | A is not evicted mid-response | Confirmed from source |
| A is stopped | SIGTERM, then force after `unloadTimeout` | Stop is sequenced strictly before start | Confirmed from source |
| **OS reclaims A's pages** | kernel, on process exit | **Not confirmed to complete before step below** | **A-2, open** |
| memgate polls free memory | new code | B does not begin loading under the floor | This spec |
| B is started and health-checked | `cmd` plus `checkEndpoint` | B serves only when ready | Confirmed |
| All swap decisions serialized | single internal run-loop | No interleaved swaps | Confirmed from source |

memgate exists precisely because of the A-2 row.

### 6.3 Design sanity check

Scope fit is good: the bulk of this is one config file plus two ~100-line scripts. Adopting llama-swap rather than building a swapper is the right call. The only new coupling is consumer to gateway URL, strictly looser than today. Top risk is C3 (model ID mismatch) silently breaking Hermes at cutover, mitigated by capturing IDs first and rehearsing rollback. Second risk is C6 (swap stall) surfacing as consumer timeouts, mitigated by T-9.

### 6.4 Memory arbitration: the degradation ladder

**Signals** (each independently enableable, each with its own threshold and dwell time): system memory pressure level (`sysctl kern.memorystatus_vm_pressure_level`, `memory_pressure -Q`), available memory (`vm_stat`), compressor/swap activity (`vm_stat` swapins/swapouts rate), GPU utilisation by others (`ioreg -r -d 1 -w 0 -c IOAccelerator`), priority process present (configurable name/bundle-id list with RSS threshold), explicit yield lock (lock file or HTTP call, IF-6, highest precedence).

**Ladder** (each level reversible when the signal clears for a configured cooldown):

| Level | Name | Effect on new loads | Effect on resident models | Typical trigger |
|---|---|---|---|---|
| 0 | Normal | Allowed, subject to memgate floor | Normal `ttl` | Nothing firing |
| 1 | Conserve | Allowed, floor raised | Reduced `ttl` (R16) | Pressure leaves normal, or GPU busy elsewhere |
| 2 | No new admissions | Blocked, clear refusal | Existing model kept, reduced `ttl` | Available memory below level-2 threshold |
| 3 | Drain and unload | Blocked | Finish in-flight, then unload everything | Yield lock held, priority process present, sustained warn pressure |
| 4 | Hard release | Blocked | Terminate now, even mid-response, logged loudly | Critical pressure, or swapout rate above threshold |

Levels 1-3 are graceful by construction (R19). Level 4 exists because a dropped response beats a kernel panic, and must be rare enough that every occurrence is worth reading in the log.

**Precedence:** explicit lock beats inferred signal in both directions.

**Deliberately not in v1:** no learned or predictive behaviour. Thresholds are fixed numbers in a config file. The event log (R20) exists so a future adaptive policy can be designed against real data, evaluated offline before ever being given control.

### 6.5 Cold-load path and storage

```
  t_gate        memgate poll until floor cleared        0 s, or seconds under contention
+ t_process     interpreter and framework import        1 to 5 s, roughly fixed
+ t_weights     bytes_on_disk / effective_read_MBps     DOMINANT for the 27B
+ t_compile     Metal kernel and graph setup, lazy      seconds, paid on first generation
+ t_health      poll interval granularity               bounded by the poll interval
```

Four levers, cheapest first: (1) TTL tuning — not paying the cold load at all; (2) warmup sidecar (R15) — move `t_compile` before the health signal; (3) storage tier (R14, N5) — `t_weights` scales linearly with read throughput, order-of-magnitude effect on the 27B, decision is data-driven; (4) file cache interaction — a genuine tension between cold-load speed and memory safety, resolved in favour of safety and measured (T-20). Explicit page-cache prewarming is deliberately not done.

---

## 7. Interfaces

### IF-1: Gateway HTTP surface (consumer-facing)

Base URL: `http://127.0.0.1:8000` (post-cutover), `http://127.0.0.1:8801` (during WP-002 through WP-006).

| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/chat/completions` | Primary. Routes on the `model` field. |
| POST | `/v1/completions` | Passthrough if MTPLX supports it. |
| GET | `/v1/models` | Must return the IDs captured in WP-001. Contract surface for R5. |

### IF-2: Gateway management surface (operator-facing)

**Verified against the installed binary, `llama-swap v250 (60226b6)`, WP-002, 2026-08-16.** Probed with an empty `models: {}` config on a scratch port; `/upstream/{id}` and `/api/models/unload/{id}` return 404 in that probe only because no real model id was registered, not because the route is wrong.

| Method | Path | Purpose | Confirmed |
|---|---|---|---|
| POST | `/api/models/unload` | Unload everything now. | 200 |
| POST | `/api/models/unload/{id}` | Unload one model. | route exists (405 on wrong method, 404 on unknown id) |
| GET | `/api/events` | SSE stream of state changes, logs, in-flight counts. | 200 |
| GET | `/api/metrics/activity` | Paginated request/activity log, **not** a bare `/api/metrics` as originally assumed. | 200, JSON `{data, page, limit, total, total_pages}` |
| GET | `/api/performance` | Additional performance metrics, not in the original spec draft. | 200 |
| GET | `/api/version` | Build info: `{build_date, commit, version}`. Not in the original spec draft. | 200 |
| GET | `/upstream/{id}` | Force-load a model without sending a completion. | route exists, full test deferred to WP-005/WP-006 with a real id |
| GET | `/logs` | Recent log tail. | 200 |
| GET | `/logs/stream` | SSE-tail of logs, separate from the bare `/logs` snapshot. | 200 |
| GET | `/ui` | Built-in web UI (redirect), not in the original spec draft. | 307 |

`/api/metrics` (bare) does **not** exist on this version — 404. Anything reading "token and request metrics" should use `/api/metrics/activity`.

### IF-3: memgate CLI

```
memgate [options] -- <command> [args...]

  --require-free-mb N   Minimum available memory before exec. Required.
  --timeout N           Seconds to wait before giving up. Default 180.
  --poll N              Poll interval in seconds. Default 2.
  --metric NAME         "available" (free+inactive+speculative+purgeable) or "free". Default "available".
  --log PATH            Append log destination. Default stderr.
  --dry-run             Report the decision and exit without exec.

Env overrides: MEMGATE_REQUIRE_FREE_MB, MEMGATE_TIMEOUT, MEMGATE_POLL, MEMGATE_METRIC.

Exit codes: child's exit code on success (via exec), 75 on timeout, 64 on bad usage.
```

**Critical implementation constraint:** memgate MUST hand off with `exec "$@"` so the MTPLX process replaces the wrapper and inherits its PID. If memgate forks and waits instead, llama-swap's SIGTERM kills the wrapper and orphans a fully-loaded MTPLX process — exactly the two-models-resident condition this project exists to prevent. Mandatory test T-6.

### IF-4: swapbench output record

One JSON object per line, stdout:

```json
{
  "ts": "2026-08-16T10:00:00Z",
  "from_model": "qwen3.5-4b-mtplx",
  "to_model": "qwen3.8-27b-mtplx",
  "t_request_sent_ms": 0,
  "t_source_pid_gone_ms": 1840,
  "t_memory_floor_reached_ms": 2310,
  "t_target_pid_seen_ms": 1900,
  "t_target_healthy_ms": 41200,
  "peak_physmem_mb": 27310,
  "min_available_mb": 4980,
  "overlap_observed": false,
  "notes": ""
}
```

`overlap_observed` is the R4 alarm. `t_memory_floor_reached_ms` versus `t_target_pid_seen_ms` answers A-2.

### IF-5: llama-swap config contract

See `config/llama-swap.yaml.template` in this repo for the canonical template with all `«VERIFY»` markers, to be filled from WP-001 and WP-005 output.

### IF-6: memwarden control surface

Lock file (path configurable, default `/tmp/model-gateway.yield`): create the file to request yield (ladder level 3); contents optional JSON `{"reason", "requested_by", "expires"}`; remove to release; a stale lock (past `expires`) auto-releases and is logged. Any process may create the file; nothing checks ownership, that is the point.

HTTP (memwarden binds a small local port, default `127.0.0.1:8010`): `POST /yield`, `POST /release`, `GET /state`, `GET /events` (SSE).

CLI: `memwarden yield --reason "..." --ttl 3600`, `memwarden release`, `memwarden state` — thin wrapper over the same lock file.

Config file `memwarden.yaml`: see `memwarden/memwarden.yaml.example` in this repo.

### IF-7: warmup sidecar

```
warmup --health-url URL --completion-url URL --model ID [--timeout N] [--max-tokens 1]
```

Launched by memgate in the background immediately before `exec`. Polls the health URL, sends one minimal completion, exits. Failures are logged and never block serving. Must be safely re-entrant.

### IF-8: swapbench validation mode

```
swapbench --validate --config validate.yaml
```

Runs a fixed suite, prints a table of criterion/measured/threshold/verdict, exits 0 or 1. Thresholds live in `validate.yaml`, seeded from WP-006/WP-012 measurements.

---

## 8. Test plan

See Section 8 of the original research spec for the full T-1 through T-28 table (mirrored in `tests/` where automatable without the live target machine: T-6, T-7, T-8 for memgate; harness scaffolding for T-5/T-9/T-10/T-11/T-12/T-17 via swapbench, run against a live gateway).

---

## 9. Work packages, traceability, decisions, assumptions, rollback

Full text (work packages WP-001 through WP-018, dependency graph, traceability matrix, decisions D-1 through D-11, open assumptions A-1 through A-11, rollback procedure, agent handoff prompt) is authoritative in the original spec message and should be treated as unchanged from what's summarized in Sections 1-8 above. Implementers: keep this file as the living reference and update `«VERIFY»` markers, IF-2, and the assumptions table in place as each WP resolves an unknown — do not fork a second copy of the spec.

**Implementation status:** Phase 1 (WP-001 through WP-009) plus WP-012 through WP-014 are complete and validated against a real deployment. Two of the spec's original open assumptions were resolved along the way: **A-5** (host/port CLI flags) confirmed true — the model server accepts `--host`/`--port` directly, no config-file wrapper needed. **A-7** (management routes under `/api/...`) confirmed true, with corrections — see the IF-2 table above; several routes differ from the original draft. One config gotcha worth knowing if you're adapting this: llama-swap's `cmd` field splits on whitespace rather than going through a shell, so any path containing a space needs to be quoted at every macro use site (see the comment in `config/llama-swap.yaml`). The detailed per-work-package engineering log — real bugs found, real numbers measured — lives in `docs/wp0*-results.md` and `docs/measurements.md`.
