#!/bin/bash
# WP-001 step 1-2: baseline capture. Run this ON THE TARGET MAC MINI, while
# MTPLX-4B is still running exactly as it does today (before any llama-swap
# or memgate change). Cannot be run from a remote sandbox -- it depends on
# launchctl, real MTPLX processes, a real ~/.hermes/config.yaml, and the
# machine's own port/memory state.
#
# Usage: ./baseline-capture.sh [output-dir]   (default: docs/baseline)
set -euo pipefail

out="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs/baseline}"
mkdir -p "$out"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "baseline capture starting: $(ts)" | tee "$out/capture.log"

echo "--- /v1/models (defines the R5 contract) ---" | tee -a "$out/capture.log"
curl -s http://127.0.0.1:8000/v1/models | tee "$out/models.json"

echo "--- ps: full argv for running MTPLX (source of truth for cmd) ---" | tee -a "$out/capture.log"
# shellcheck disable=SC2009  # WP-001 asks for this exact ps|grep form, full argv matters more than pgrep's truncation
ps -axww -o pid,rss,command | grep -i mtplx | tee "$out/mtplx-argv.txt"

echo "--- MTPLX 4B LaunchAgent plist ---" | tee -a "$out/capture.log"
plist=$(launchctl list | grep -i mtplx | awk '{print $3}' | head -1 || true)
if [ -n "$plist" ]; then
  find ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons -iname "*${plist}*" -exec cp {} "$out/" \; 2>/dev/null || true
fi
echo "recorded launchd label: ${plist:-<not found, capture manually>}" | tee -a "$out/capture.log"

echo "--- launchctl list | grep -i mtplx ---" | tee -a "$out/capture.log"
launchctl list | grep -i mtplx | tee "$out/launchctl-mtplx.txt" || echo "(none found)" | tee "$out/launchctl-mtplx.txt"

echo "--- port inventory (confirms 9200+ is free for startPort) ---" | tee -a "$out/capture.log"
lsof -nP -iTCP -sTCP:LISTEN | tee "$out/listening-ports.txt"

echo "--- iogpu.wired_limit_mb ---" | tee -a "$out/capture.log"
sysctl iogpu.wired_limit_mb | tee "$out/wired-limit.txt"

echo "--- ~/.hermes/config.yaml hash + copy ---" | tee -a "$out/capture.log"
if [ -f ~/.hermes/config.yaml ]; then
  shasum -a 256 ~/.hermes/config.yaml | tee "$out/hermes-config.sha256"
  cp ~/.hermes/config.yaml "$out/hermes-config.yaml.baseline"
else
  echo "$HOME/.hermes/config.yaml not found on this machine" | tee -a "$out/capture.log"
fi

echo ""
echo "--- memory floor (WP-001 step 2) ---" | tee -a "$out/capture.log"
echo "Stop all model processes first, wait 60s, then run:" | tee -a "$out/capture.log"
echo "  vm_stat" | tee -a "$out/capture.log"
echo "three times and record the median. This step is NOT automated here" | tee -a "$out/capture.log"
echo "because it requires deliberately stopping models first; do it by hand" | tee -a "$out/capture.log"
echo "and write the result to $out/memory-floor.json in this shape:" | tee -a "$out/capture.log"
cat <<'EOF' | tee -a "$out/capture.log"
{
  "captured_at": "<ISO8601>",
  "samples_mb": [<used1>, <used2>, <used3>],
  "median_used_mb": <median>
}
EOF

echo ""
echo "baseline capture done: $(ts)"
echo "review $out/ and fill docs/baseline/memory-floor.json and the N3 ceiling by hand."
