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

echo "--- step 1: stop llama-swap (and its LaunchAgent if present) ---"
if launchctl list 2>/dev/null | grep -qi llama-swap; then
  label=$(launchctl list | grep -i llama-swap | awk '{print $3}' | head -1)
  echo "unloading llama-swap LaunchAgent: $label"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || launchctl unload "$HOME/Library/LaunchAgents/${label}.plist" 2>/dev/null || true
else
  echo "no llama-swap LaunchAgent found (may be running unmanaged)"
fi
pkill -f "llama-swap" 2>/dev/null && echo "killed running llama-swap process(es)" || echo "no running llama-swap process found"

echo "--- step 2: confirm no orphan mtplx PIDs survived llama-swap ---"
if pgrep -f mtplx >/dev/null 2>&1; then
  echo "WARNING: mtplx processes still running after stopping llama-swap:"
  pgrep -afl mtplx || true
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
  if [ -f "$baseline/models.json" ] && diff -q "$baseline/models.json" /tmp/rollback-models.json >/dev/null 2>&1; then
    echo "OK: /v1/models matches baseline capture"
  else
    echo "WARNING: /v1/models responded but differs from baseline capture -- compare manually:"
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
