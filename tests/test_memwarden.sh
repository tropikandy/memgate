#!/bin/bash
# Exercises memwarden's lock + ladder core (WP-014) without a live gateway.
# T-21 (lock yield) and T-22 (release + stale lock) style checks, adapted
# to run headless: the unload HTTP call is expected to fail here (no
# gateway running) and that failure is logged, not fatal.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mw="$here/../memwarden/memwarden"
lock="$here/test.yield"
log="$here/test-events.jsonl"
fail=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fail=1; }

rm -f "$lock" "$log"

# yield creates the lock file
python3 "$mw" --lock-file "$lock" --event-log "$log" --gateway-url "http://127.0.0.1:1" \
  yield --reason "test" --requested-by "tester" >/dev/null 2>&1
if [ -f "$lock" ]; then
  pass "T-21: yield creates the lock file"
else
  fail "T-21: lock file was not created"
fi

state=$(python3 "$mw" --lock-file "$lock" --event-log "$log" state 2>/dev/null)
if echo "$state" | grep -q '"lock_held": true'; then
  pass "T-21: state reports lock_held=true"
else
  fail "T-21: state did not report lock_held=true: $state"
fi

# release removes the lock file and restores normal service
python3 "$mw" --lock-file "$lock" --event-log "$log" release >/dev/null 2>&1
if [ ! -f "$lock" ]; then
  pass "T-22: release removes the lock file"
else
  fail "T-22: lock file still present after release"
fi

# stale lock (past expires) auto-releases and is logged
python3 - "$lock" <<'EOF'
import json, sys, time
path = sys.argv[1]
past = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600))
with open(path, "w") as f:
    json.dump({"reason": "stale test", "requested_by": "tester", "expires": past}, f)
EOF
python3 "$mw" --lock-file "$lock" --event-log "$log" state >/dev/null 2>&1
if [ ! -f "$lock" ]; then
  pass "T-22: stale lock auto-released"
else
  fail "T-22: stale lock was not auto-released"
fi
if grep -q "stale lock auto-released" "$log"; then
  pass "T-22: stale auto-release is logged"
else
  fail "T-22: stale auto-release not found in event log"
fi

rm -f "$lock" "$log"

echo "---"
if [ "$fail" -eq 0 ]; then
  echo "all tests passed"
  exit 0
else
  echo "some tests FAILED"
  exit 1
fi
