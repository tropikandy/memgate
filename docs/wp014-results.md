# WP-014 results — memwarden: lock and ladder core (2026-08-16, on-machine)

**Requirements satisfied:** R17, R19, N6. **Depends on:** WP-007. **Scope:** explicit lock only, all inferred signals disabled (WP-015's own scope, not touched here).

## Real bug found and fixed: externally-created locks were inert

IF-6 is explicit: "Any process may create the file; nothing checks
ownership, that is the point." The daemon's poll loop
(`check_stale_lock`) only handled two cases — lock file missing (revert
to normal) and lock file expired (auto-release) — and never handled
"lock file exists, but the daemon's own level is still NORMAL." A lock
file created by anything other than memwarden's own CLI/HTTP was
correctly *reported* in `/state` (`lock_held: true`) but never actually
triggered drain-and-unload. Verified live before fixing (external
`echo ... > lockfile` left `level: 0`, no event logged) and after
(level transitions to DRAIN, a `yield` event logs with
`detected: "externally created lock file"`, the gateway's unload
endpoint is actually called). This was the single most important gap to
close for R17, since the whole design point of the lock file (vs. only
a CLI/HTTP API) is that arbitrary other tools can use it with zero
integration effort.

## What was done

- Fixed the bug above (`memwarden/memwarden`, `check_stale_lock`).
- `bin/memgate` gained `--preexec-cmd` in WP-013; separately, its lock
  refusal message now names the lock's `reason`/`requested_by` (WP-014's
  own acceptance criterion: "refused with a reason naming the lock and
  its requested_by").
- `config/llama-swap.yaml`: both tiers' memgate macros gained
  `--lock-file /tmp/model-gateway.yield`, checked before the memory
  floor (already memgate's existing order).
- `com.local.memwarden.plist` created and loaded as a LaunchAgent —
  `WorkingDirectory` and `EnvironmentVariables` set from the start this
  time, applying the WP-008 lesson (worked on the first bootstrap, no
  repeat of that incident).
- `scripts/rollback.sh` extended to stop memwarden too (was llama-swap
  only), and to clean up a stray lock file if one is held during
  rollback.

## Live end-to-end test (T-21/T-22 equivalents, real gateway)

1. Loaded the 4B through the real gateway (confirmed `status: loaded`).
2. `memwarden yield --reason "..." --requested-by "..."`: resident 4B
   drained and unloaded within ~2s. A concurrent load attempt during the
   yield was refused (500) and the model stayed unloaded — R17's "blocks
   new loads" holds. (The HTTP error body itself is llama-swap's own
   generic group-abort message, not memgate's specific lock reason —
   memgate's own refusal log is written to its stderr, which is where
   IF-3 puts it; forwarding that detail into llama-swap's own HTTP error
   surface would mean patching llama-swap, explicitly out of scope.)
3. `memwarden release`: lock file removed immediately. The **daemon's
   own in-memory ladder level** took one poll cycle (~5-6s, the
   configured `--poll-interval 5`) to catch up and report `level: 0` —
   the CLI `release` and the running daemon are separate processes, so
   they only share the filesystem lock file, not memory. This is
   eventually-consistent by design, not a bug, and well inside N6's 20s
   idle-yield budget.
4. Normal service resumed cleanly after release (200 OK, 5.97s cold
   load).

## What's still open (WP-015's own scope, not this WP's)

All inferred signals (`memory_pressure`, `available_memory`,
`swap_activity`, `gpu_utilisation`, `priority_processes`) remain
disabled, exactly as WP-014 specifies. The spec's own rule: WP-015 does
not start until Phase 1 has run a normal working week on the real
machine, so thresholds come from observed behavior, not intuition. Not
touched here, on purpose.
