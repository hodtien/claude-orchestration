#!/usr/bin/env bash
# test-orch-metrics-rollup.sh — Tests for Phase 8.2: orch-metrics.sh rollup
#
# Covers:
#   1. Empty dir → valid empty rollup
#   2. Seed 9 fixtures → all 4 strategies + all 4 final_states → counts match
#   3. Malformed JSON → counted in schema_invalid_or_unreadable, no crash
#   4. schema_version=2 → skipped, counted invalid
#   5. --since 1h filter excludes old completed_at
#   6. Human-readable output smoke test
#   7. No regression: event-log mode still works

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
METRICS="$SCRIPT_DIR/orch-metrics.sh"
FIXTURES="$PROJECT_ROOT/test-fixtures/metrics"

PASS=0
FAIL=0
TOTAL=0

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: $1"; echo "       $2"; }

# json_get JSON_STRING key1 key2 ...  → prints leaf value
json_get() {
  local json_data="$1"; shift
  local keys_csv
  keys_csv=$(printf '"%s",' "$@")
  keys_csv="${keys_csv%,}"
  echo "$json_data" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in [${keys_csv}]:
    d = d[k]
print(d)
" 2>/dev/null
}

# assert_eq LABEL JSON KEY1 KEY2 ... EXPECTED
# last argument is the expected value
assert_eq() {
  local label="$1"; shift
  local json_data="$1"; shift
  local expected="${@: -1}"   # last arg
  local keys=("${@:1:$#-1}") # all but last
  local actual
  actual=$(json_get "$json_data" "${keys[@]}")
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label" "expected=$expected actual=$actual"
  fi
}

echo "============================================================"
echo "  TEST: orch-metrics.sh rollup (Phase 8.2)"
echo "============================================================"
echo

# ── Test 1: Empty dir ─────────────────────────────────────────────────────────
echo "── Test 1: Empty dir → valid empty rollup"
EMPTY_DIR=$(mktemp -d)
EMPTY_OUT=$("$METRICS" rollup --json --dir "$EMPTY_DIR" 2>/dev/null)
RC=$?
rmdir "$EMPTY_DIR"

if [ $RC -eq 0 ]; then
  pass "exit code 0"
else
  fail "exit code 0" "got $RC"
fi

assert_eq "files_scanned=0"  "$EMPTY_OUT" totals status_files_scanned 0
assert_eq "unique_tasks=0"   "$EMPTY_OUT" totals unique_tasks 0
assert_eq "schema_v1_valid=0" "$EMPTY_OUT" totals schema_v1_valid 0
echo

# ── Test 2: Seed fixtures — counts match ──────────────────────────────────────
echo "── Test 2: Seed fixtures — strategy × final_state counts"
FIXTURE_OUT=$("$METRICS" rollup --json --dir "$FIXTURES" 2>/dev/null)

# 9 files: 7 valid v1, fix-007 malformed + fix-008 schema v2 → 2 invalid
assert_eq "files_scanned=9"  "$FIXTURE_OUT" totals status_files_scanned 9
assert_eq "schema_v1_valid=7" "$FIXTURE_OUT" totals schema_v1_valid 7
assert_eq "schema_invalid=2" "$FIXTURE_OUT" totals schema_invalid_or_unreadable 2
assert_eq "unique_tasks=7"   "$FIXTURE_OUT" totals unique_tasks 7

assert_eq "done=4"           "$FIXTURE_OUT" final_state_counts done 4
assert_eq "exhausted=1"      "$FIXTURE_OUT" final_state_counts exhausted 1
assert_eq "failed=1"         "$FIXTURE_OUT" final_state_counts failed 1
assert_eq "needs_revision=1" "$FIXTURE_OUT" final_state_counts needs_revision 1

# architecture_analysis: fix-001(consensus/done), fix-003(consensus_exhausted/exhausted), fix-009(consensus/done)
assert_eq "arch total=3"     "$FIXTURE_OUT" by_task_type architecture_analysis total 3

# implement_feature: fix-002(consensus/done), fix-004(first_success/done), fix-005(failed/failed)
assert_eq "impl total=3"     "$FIXTURE_OUT" by_task_type implement_feature total 3

# code_review: fix-006(consensus/needs_revision)
assert_eq "review total=1"   "$FIXTURE_OUT" by_task_type code_review total 1

# reflexion_iterations_histogram: 0→3 (fix-001,fix-004,fix-005), 1→1 (fix-002), 2→2 (fix-006,fix-009... wait fix-009=0)
# Re-check: fix-001=0, fix-002=1, fix-003=3(→3+), fix-004=0, fix-005=0, fix-006=2, fix-009=0
assert_eq "reflex 0=4"       "$FIXTURE_OUT" reflexion_iterations_histogram 0 4
assert_eq "reflex 1=1"       "$FIXTURE_OUT" reflexion_iterations_histogram 1 1
assert_eq "reflex 2=1"       "$FIXTURE_OUT" reflexion_iterations_histogram 2 1
assert_eq "reflex 3+=1"      "$FIXTURE_OUT" reflexion_iterations_histogram 3+ 1
echo

# ── Test 3: Malformed JSON → no crash ────────────────────────────────────────
echo "── Test 3: Malformed JSON → no crash"
SCHEMA_INVALID=$(json_get "$FIXTURE_OUT" totals schema_invalid_or_unreadable)
if [ "$SCHEMA_INVALID" -ge 1 ]; then
  pass "malformed counted in schema_invalid (=$SCHEMA_INVALID)"
else
  fail "malformed counted" "schema_invalid_or_unreadable=$SCHEMA_INVALID, expected >=1"
fi
echo

# ── Test 4: schema_version=2 → skipped with warning ──────────────────────────
echo "── Test 4: schema_version=2 → skipped with warning on stderr"
STDERR_OUT=$("$METRICS" rollup --json --dir "$FIXTURES" 2>&1 1>/dev/null || true)
if echo "$STDERR_OUT" | grep -q "schema_version=2"; then
  pass "stderr warns about schema_version=2"
else
  fail "stderr warns schema_version=2" "no warning in: $STDERR_OUT"
fi
echo

# ── Test 5: --since 1h filter ─────────────────────────────────────────────────
echo "── Test 5: --since 1h excludes old completed_at"
SINCE_OUT=$("$METRICS" rollup --json --since 1h --dir "$FIXTURES" 2>/dev/null)
VALID_SINCE=$(json_get "$SINCE_OUT" totals schema_v1_valid)
VALID_ALL=$(json_get "$FIXTURE_OUT" totals schema_v1_valid)

if [ "$VALID_SINCE" -lt "$VALID_ALL" ]; then
  pass "--since 1h returned fewer records ($VALID_SINCE < $VALID_ALL)"
else
  fail "--since 1h filter" "expected fewer, got since=$VALID_SINCE all=$VALID_ALL"
fi
echo

# ── Test 6: Human-readable output smoke test ──────────────────────────────────
echo "── Test 6: Human-readable output"
HUMAN=$("$METRICS" rollup --dir "$FIXTURES" 2>/dev/null)
if echo "$HUMAN" | grep -q "ORCHESTRATION ROLLUP"; then
  pass "header present"
else
  fail "header present" "missing ORCHESTRATION ROLLUP header"
fi
if echo "$HUMAN" | grep -q "Final State"; then
  pass "Final State section present"
else
  fail "Final State section" "missing"
fi
if echo "$HUMAN" | grep -q "Consensus Score Distribution"; then
  pass "Consensus Score Distribution present"
else
  fail "Consensus Score Distribution" "missing"
fi
if echo "$HUMAN" | grep -q "Reflexion Iterations"; then
  pass "Reflexion Iterations present"
else
  fail "Reflexion Iterations" "missing"
fi
echo

# ── Test 7: No regression — event-log mode ───────────────────────────────────
echo "── Test 7: No regression — event-log mode"
if [ -f "$PROJECT_ROOT/.orchestration/tasks.jsonl" ]; then
  EVENT_OUT=$("$METRICS" --json 2>/dev/null)
  if echo "$EVENT_OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'summary' in d" 2>/dev/null; then
    pass "event-log --json still works"
  else
    fail "event-log --json" "output missing 'summary' key"
  fi
else
  pass "event-log skipped (no tasks.jsonl present)"
fi
echo

# ── Summary ───────────────────────────────────────────────────────────────────
echo "============================================================"
if [ $FAIL -eq 0 ]; then
  echo "  ALL $TOTAL TESTS PASSED"
else
  echo "  $PASS/$TOTAL PASSED, $FAIL FAILED"
fi
echo "============================================================"

exit $FAIL
