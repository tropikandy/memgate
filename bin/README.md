# memgate

A tiny, dependency-free start-gate: it refuses to launch a command until
measured free memory clears a floor (and, if configured, until an
explicit yield lock is released), then hands off to that command via
`exec` — never fork+wait. One decision, made once per invocation. No
daemon, no state of its own.

```
memgate --require-free-mb 6144 -- /path/to/memory-hungry-process --args
```

## Why this exists

Process supervisors that start and stop child processes on demand
(systemd units, launchd agents, [llama-swap](https://github.com/mostlygeek/llama-swap),
a shell script that loops) generally assume the OS has fully reclaimed a
just-exited process's memory by the time they start the next one. That
assumption isn't always true — page reclamation, compressed-memory
teardown, and GPU/unified-memory frameworks (Metal, CUDA) can all lag
behind process exit by a meaningful amount. On a memory-constrained
machine, starting a new memory-heavy process into that gap is how you
get thrashing, swap-death, or a kernel panic instead of a clean handoff.

memgate is the fix for that specific gap: put it in front of the
command your supervisor already runs, and it will not let the new
process start until there's actually enough free memory for it —
regardless of whether the supervisor itself waited long enough.

## Use case

Built for on-demand local LLM inference servers (the motivating case:
swapping between different model sizes behind a single gateway port,
where loading a 20+ GB model while a previous one hasn't fully released
its memory can be the difference between a slow response and a panic).
The same shape applies to anything launched by a supervisor where
"don't start until memory is actually free" matters more than "start
immediately": batch jobs, dev servers restarted on file change,
memory-heavy build steps.

## How it compares to existing tools

Nothing here is a novel idea — the value is in the specific combination
for this use case, not the individual pieces. For context, an honest
comparison to what's already out there:

| Tool | What it does | How memgate differs |
|---|---|---|
| **GNU `parallel --memfree SIZE`** | Delays starting the next queued job until free memory clears a threshold. | The closest direct analog — same core idea. memgate generalizes it into a standalone wrapper usable with *any* launcher (a supervisor, a shell script, a systemd/launchd unit), not tied to GNU parallel's own job queue, and adds the yield-lock check as a second, independent gate. |
| **Kubernetes scheduler (`resources.requests.memory`)** | Won't schedule a pod onto a node without enough allocatable memory. | Same idea, wildly different scope — a full cluster scheduler vs. a ~160-line single-machine CLI primitive. If you already have a scheduler making this decision, you don't need memgate. |
| **cgroups (`MemoryMax=`) / systemd `ConditionMemoryAvailable=`** | Constrains or kills a process that exceeds a memory limit (reactive); or refuses to *start* a systemd unit if a memory condition isn't met (a declarative unit-file condition, Linux-only). | `ConditionMemoryAvailable=` is the closer of the two, but it's a systemd-specific unit condition, not a portable wrapper you can drop into an arbitrary command line, and it doesn't do the exec-handoff (see below). `MemoryMax=` is reactive (limits/kills after the fact), not a pre-flight gate at all. |
| **Ad hoc "wait for GPU memory" scripts** (common in ML pipelines: poll `nvidia-smi`, then launch training) | Exactly this pattern, informally reinvented per-project, usually as one-off shell glue. | memgate is that pattern formalized as a small, tested, reusable tool — for system RAM via macOS `vm_stat` here, with the memory-reading step isolated behind an overridable hook (`MEMGATE_READER_CMD`) so a different OS's memory source (e.g. Linux `/proc/meminfo`) is a small, contained change, not a rewrite. |
| **`flock`** | Wraps a command, refusing to run it while a lock is held. | Structurally similar (wrap-and-gate), but gates on a mutex, not measured memory. memgate's own `--lock-file` option is closer to this — a plain file any other process can create, no library or client needed — used as a *second*, independent gate ahead of the memory check. |

**What's specifically deliberate about memgate's own design**, beyond
just "check memory before starting":

- **`exec`, not fork+wait.** Many similar wrapper scripts get this
  wrong: if the supervisor sends a signal to "the process it started"
  (the wrapper) rather than the real workload, and the wrapper just
  forks and waits, the signal never reaches the child — you get an
  orphaned, fully-loaded process the supervisor thinks it already
  stopped. memgate replaces itself via `exec`, so the wrapped process
  inherits its PID directly and there is no wrapper left to orphan.
- **Two independent gates, checked in order.** An explicit yield lock
  (any process, no client library, just a file) takes precedence over
  the measured-memory floor — so something else can say "not now" for
  reasons memgate itself has no way to know about (another app needs
  the memory, a human said so, whatever), without memgate needing to
  understand why.
- **Zero dependencies, no daemon.** Bash and a memory reader, nothing
  else. It makes one decision and gets out of the way.
