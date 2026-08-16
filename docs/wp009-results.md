# WP-009 results — Out-of-scope regression check (2026-08-16, on-machine)

**Requirements satisfied:** R8. **Depends on:** WP-007.

## Strongest evidence first: these processes were never touched

DeepSeek bridge (PID 615, port 8010) and consult-deepseek (PID 621, port
8020) are the **exact same PIDs** recorded in the WP-001 baseline capture
at the very start of this session (`docs/baseline/listening-ports.txt`).
A PID surviving unchanged across the whole session (LaunchAgent stops,
gateway cutover, multiple restarts of unrelated services) is strong
direct evidence neither process was ever restarted, killed, or
reconfigured by anything done here — a config change to either service
would need a restart to take effect, and no restart happened.

## Smoke tests

| Check | Result |
|---|---|
| DeepSeek bridge, live request | **PASS.** `POST :8010/v1/chat/completions` with `model: deepseek-chat` returned 200 with real content (`"pong"`). |
| consult-deepseek, MCP round trip | **PASS, with a caveat.** A real MCP `initialize` handshake (`POST :8020/mcp`, JSON-RPC) succeeded: protocol version, capabilities, and `serverInfo: {"name":"consult-deepseek","version":"1.29.0"}` all returned correctly. This is a genuine protocol round trip, not just a TCP connectivity check — but it was driven directly (curl, mimicking what an MCP client does), not literally initiated from Hermes itself, which isn't something this session can trigger. |
| VaultScribe, transcribe a short clip | **Not independently run.** It's a GUI-only app (`/Applications/VaultScribe.app`, no CLI entry point found), not currently running, and its bundle's last-modified time (Aug 15 21:30) predates this entire session — so nothing here touched it. Actually exercising transcription needs the user's own hands (opening the app, recording or picking a clip) — deliberately not launched automatically, since popping open a GUI app with mic/audio permission prompts on the user's desktop without warning isn't appropriate. |

## Config diffs

- `~/.hermes/config.yaml`: already confirmed byte-identical (SHA-256 match) before and after cutover in WP-007.
- No config file specific to DeepSeek bridge, consult-deepseek, or
  VaultScribe was captured as a WP-001 baseline (the spec's WP-001 step 1
  only captured the Hermes config hash), so there's no baseline hash to
  diff those against directly. The PID-continuity evidence above is the
  practical substitute: unrestarted processes cannot be running a
  changed config.

## Verdict

R8 holds: DeepSeek bridge and consult-deepseek both pass live checks and
were never restarted. VaultScribe wasn't independently exercised this
session (needs the user), but is undisturbed by every available signal
(not running, bundle untouched since before this session started).
