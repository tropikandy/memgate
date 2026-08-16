#!/bin/bash
# Exercises memgate per IF-3 / T-6, T-7, T-8 without touching real system
# memory or requiring a Mac. Run: bash tests/test_memgate.sh
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
memgate="$here/../bin/memgate"
fail=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fail=1; }

# T-7a: below floor blocks and exits 75 at timeout
out=$(MEMGATE_READER_CMD="$here/fake_vm_stat_below.sh" \
  "$memgate" --require-free-mb 6144 --timeout 2 --poll 1 -- /bin/echo should-not-run 2>&1)
rc=$?
if [ "$rc" -eq 75 ] && ! printf '%s' "$out" | grep -q should-not-run; then
  pass "T-7a: below floor blocks and times out with exit 75"
else
  fail "T-7a: expected exit 75 and no child output, got rc=$rc out=$out"
fi

# T-7b: above floor execs immediately
out=$(MEMGATE_READER_CMD="$here/fake_vm_stat_above.sh" \
  "$memgate" --require-free-mb 6144 --timeout 5 --poll 1 -- /bin/echo hello-world 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "hello-world" ]; then
  pass "T-7b: above floor execs the command"
else
  fail "T-7b: expected 'hello-world' and rc=0, got rc=$rc out=$out"
fi

# T-6: exec handoff - the child replaces the memgate process (same PID),
# so a signal to that PID reaches the child directly, no orphan wrapper.
MEMGATE_READER_CMD="$here/fake_vm_stat_above.sh" \
  "$memgate" --require-free-mb 6144 --timeout 5 --poll 1 -- \
  /bin/sh -c 'echo $$ > "$0.pid"; sleep 30' "$here/t6" &
launcher_pid=$!
sleep 1
if [ -f "$here/t6.pid" ]; then
  child_pid=$(cat "$here/t6.pid")
  if [ "$child_pid" = "$launcher_pid" ]; then
    pass "T-6: exec replaced the memgate PID (no fork/wait wrapper)"
  else
    fail "T-6: child PID ($child_pid) differs from launched PID ($launcher_pid), exec did not replace the process"
  fi
  kill "$launcher_pid" 2>/dev/null
else
  fail "T-6: child never started"
fi
rm -f "$here/t6.pid"
wait 2>/dev/null

# T-8: genericity - runs against a trivial command with all args supplied,
# no machine-specific defaults required (no hardcoded paths/ports/model IDs).
if grep -nE '/Volumes|/Users/[a-z]+|8000|mtplx' "$memgate" >/dev/null; then
  fail "T-8: memgate source references machine-specific values"
else
  pass "T-8: memgate source is free of machine-specific hardcodes"
fi

# --dry-run reports without exec
out=$(MEMGATE_READER_CMD="$here/fake_vm_stat_above.sh" \
  "$memgate" --require-free-mb 6144 --timeout 5 --dry-run -- /bin/echo should-not-run)
if [ "$out" = "clear" ]; then
  pass "--dry-run reports the decision without exec"
else
  fail "--dry-run: expected 'clear', got '$out'"
fi

# bad usage exits 64
"$memgate" --timeout 5 -- /bin/echo x >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 64 ]; then
  pass "missing --require-free-mb exits 64"
else
  fail "missing --require-free-mb: expected exit 64, got $rc"
fi

echo "---"
if [ "$fail" -eq 0 ]; then
  echo "all tests passed"
  exit 0
else
  echo "some tests FAILED"
  exit 1
fi
