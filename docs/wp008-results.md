# WP-008 results — LaunchAgent for llama-swap (2026-08-16, on-machine)

**Requirements satisfied:** R9, R2. **Depends on:** WP-007.

## What was done

- `~/Library/LaunchAgents/com.local.llama-swap.plist` created, modeled
  on the captured MTPLX plist's shape (`RunAtLoad`, `KeepAlive`,
  `ThrottleInterval` 15s, `ExitTimeOut` 20s, combined stdout/stderr log
  at `~/Library/Logs/llama-swap.log`). `ProgramArguments` points at the
  real installed binary (`~/.local/bin/llama-swap`) and the real config
  (`/Users/andreaslarsson/memgate/config/llama-swap.yaml`), listening on
  `127.0.0.1:8000`.
- Manually-run llama-swap (from WP-007) stopped, LaunchAgent bootstrapped
  in its place. T-1 re-run against the LaunchAgent-managed instance:
  PASS, `/v1/models` correct, logs landing where the plist says.
- `scripts/rollback.sh` already handles this without any changes needed
  — its step 1 greps `launchctl list` for `llama-swap` (matches
  `com.local.llama-swap` by substring) and `bootout`s it before the
  catch-all `pkill`, so a `KeepAlive`-respawn during rollback isn't a
  risk. Verified by reading the script, not by re-running a full
  rollback (would tear down the just-completed cutover for no reason).

## What's not done: T-4 (real reboot)

**Deliberately not performed in this session.** A real reboot would end
this Claude Code session and close every other app the user has open —
that's not something to do without explicit, separately-timed
confirmation, unlike the other actions in this WP. Everything else that
can be verified without a reboot has been (LaunchAgent loads correctly,
`RunAtLoad`/`KeepAlive` are set, logs land correctly).

**To close this out:** next time the machine reboots (planned or
otherwise), confirm:
- `curl http://127.0.0.1:8000/v1/models` succeeds without manual
  intervention (R9).
- After 5 minutes of no traffic, `pgrep -f mtplx` returns nothing and
  PhysMem is within 500MB of the WP-001 floor (R2) — llama-swap running
  is not the same as a model running, and this is the check that proves
  it.

If it's useful later, a good moment to actually reboot for this check is
whenever a reboot is happening anyway (macOS update, etc.) rather than
scheduling one just for this test.
