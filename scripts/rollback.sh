#!/bin/bash
# R12 / T-15: one-command rollback. Re-enables the MTPLX LaunchAgents,
# stops llama-swap, and restores the original port binding.
#
# Run this ON THE TARGET MAC MINI. Requires docs/baseline/ to have been
# populated by scripts/baseline-capture.sh (WP-001) beforehand -- this
# script restores from what was captured there, it does not invent
# replacement plists.
#
# Idempotent: safe to run even if some steps were already done.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline="$here/docs/baseline"
pass=1

echo "=== rollback: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

echo "--- step 1: stop llama-swap and memwarden (and their LaunchAgents if present) ---"
for svc in llama-swap memwarden; do
  if launchctl list 2>/dev/null | grep -qi "$svc"; then
    label=$(launchctl list | grep -i "$svc" | awk '{print $3}' | head -1)
    echo "unloading $svc LaunchAgent: $label"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || launchctl unload "$HOME/Library/LaunchAgents/${label}.plist" 2>/dev/null || true
  else
    echo "no $svc LaunchAgent found (may be running unmanaged)"
  fi
done
pkill -f "llama-swap" 2>/dev/null && echo "killed running llama-swap process(es)" || echo "no running llama-swap process found"
pkill -f "memwarden" 2>/dev/null && echo "killed running memwarden process(es)" || echo "no running memwarden process found"
rm -f /tmp/model-gateway.yield 2>/dev/null

echo "--- step 2: confirm no orphan mtplx PIDs survived llama-swap ---"
# Matched against the actual MTPLX process signatures (see docs/baseline/mtplx-argv.txt),
# not a bare "mtplx" substring -- that also matches unrelated processes whose argv/env
# happens to contain "mtplx" (e.g. a PATH entry like ~/.mtplx/bin).
mtplx_pattern='MTPLX\.app/Contents/MacOS/MTPLXApp|mtplx serve|mtplx\.server\.openai'
if pgrep -f "$mtplx_pattern" >/dev/null 2>&1; then
  echo "WARNING: mtplx processes still running after stopping llama-swap:"
  pgrep -afl "$mtplx_pattern" || true
  echo "(these may be the MTPLX LaunchAgents already restarting in step 3 -- re-check after)"
fi

echo "--- step 3: re-enable and load the original MTPLX LaunchAgents ---"
if [ -d "$baseline" ]; then
  found=0
  for plist in "$baseline"/*mtplx*.plist; do
    [ -e "$plist" ] || continue
    found=1
    label=$(basename "$plist" .plist)
    target="$HOME/Library/LaunchAgents/$(basename "$plist")"
    cp "$plist" "$target"
    launchctl enable "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$target" 2>/dev/null || launchctl load "$target" 2>/dev/null || true
    echo "restored and loaded: $label"
  done
  if [ "$found" -eq 0 ]; then
    echo "ERROR: no *mtplx*.plist found in $baseline -- run baseline-capture.sh before cutover next time."
    pass=0
  fi
else
  echo "ERROR: $baseline does not exist. Rollback cannot restore what was never captured (WP-001)."
  pass=0
fi

echo "--- step 4: verify port 8000 responds and matches the baseline ---"
sleep 3
if curl -s --max-time 5 http://127.0.0.1:8000/v1/models >/tmp/rollback-models.json 2>/dev/null; then
  # Compare model IDs only, not the raw JSON: MTPLX's "created" field is
  # generated per-request and will differ on every call, so a byte-for-byte
  # diff against the baseline always warns even when nothing is wrong (R5
  # only cares about the id set, not this timestamp).
  ids_match=0
  if [ -f "$baseline/models.json" ]; then
    baseline_ids=$(python3 -c 'import json,sys; print(sorted(m["id"] for m in json.load(open(sys.argv[1]))["data"]))' "$baseline/models.json" 2>/dev/null)
    current_ids=$(python3 -c 'import json,sys; print(sorted(m["id"] for m in json.load(open(sys.argv[1]))["data"]))' /tmp/rollback-models.json 2>/dev/null)
    [ -n "$baseline_ids" ] && [ "$baseline_ids" = "$current_ids" ] && ids_match=1
  fi
  if [ "$ids_match" -eq 1 ]; then
    echo "OK: /v1/models model IDs match baseline capture"
  else
    echo "WARNING: /v1/models responded but its model IDs differ from baseline capture -- compare manually:"
    echo "  diff $baseline/models.json /tmp/rollback-models.json"
  fi
else
  echo "ERROR: http://127.0.0.1:8000/v1/models did not respond within 5s"
  pass=0
fi

echo ""
if [ "$pass" -eq 1 ]; then
  echo "=== rollback: PASS ==="
  exit 0
else
  echo "=== rollback: FAILED, see errors above ==="
  exit 1
fi
