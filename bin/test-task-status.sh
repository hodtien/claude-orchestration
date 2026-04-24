#!/usr/bin/env bash
# test-task-status.sh — Phase 8.1 tests for lib/task-status.sh
#
# 5 tests verifying the canonical task status JSON schema v1.
#
# Usage:
#   bin/test-task-status.sh               # run all tests
#   bin/test-task-status.sh --verbose    # also print intermediate values

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/.orchestration/results"
mkdir -p "$RESULTS_DIR"

# Skip on bash 3.x
if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
  echo "SKIP — bash 3.x detected"
  exit 0
fi

# Skip if yq not available
if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP — yq not installed"
  exit 0
fi

# Skip if task-status.sh not present
if [[ ! -f "$PROJECT_ROOT/lib/task-status.sh" ]]; then
  echo "SKIP — lib/task-status.sh not present"
  exit 0
fi

source "$PROJECT_ROOT/lib/task-status.sh"

PASS=0
FAIL=0

assert_pass() { printf "  ✓ %s\n" "$1"; PASS=$((PASS+1)); }
assert_fail() { printf "  ✗ %s — %s\n" "$1" "$2"; FAIL=$((FAIL+1)); }

echo "Phase 8.1 — Task Status JSON Tests"
echo "==================================="

# Test 1: build_status_json with first_success inputs
echo ""
echo "Test 1: build_status_json — first_success success path"
RESULT=$(build_status_json "t001" "code_review" "first_success" "done" "t001.out" "1024" "gemini-pro" "gemini-pro" "" "0.0" "0" "" "45.0" "2026-04-24T10:00:00Z" "2026-04-24T10:00:45Z")
echo "$RESULT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['schema_version']==1, 'schema_version'
assert d['final_state']=='done', f\"final_state={d['final_state']}\"
assert d['strategy_used']=='first_success', f\"strategy={d['strategy_used']}\"
assert d['output_bytes']==1024, f\"bytes={d['output_bytes']}\"
assert d['winner_agent']=='gemini-pro', f\"winner={d['winner_agent']}\"
assert d['consensus_score']==0.0, f\"score={d['consensus_score']}\"
assert d['reflexion_iterations']==0, f\"refl={d['reflexion_iterations']}\"
assert d['markers']==[], f\"markers={d['markers']}\"
assert d['duration_sec']==45.0, f\"duration={d['duration_sec']}\"
print('PASS')
" && assert_pass "first_success success JSON valid" || assert_fail "first_success JSON" "python assert failed"

# Test 2: build_status_json with consensus inputs
echo ""
echo "Test 2: build_status_json — consensus success path"
RESULT=$(build_status_json "t002" "design_api" "consensus" "done" "t002.out" "5000" "merged" "gemini-pro,cc/claude-sonnet-4-6,minimax-code" "gemini-pro,minimax-code" "0.556" "0" "" "120.0" "2026-04-24T11:00:00Z" "2026-04-24T11:02:00Z")
echo "$RESULT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['final_state']=='done'
assert d['strategy_used']=='consensus'
assert d['consensus_score']==0.556
assert len(d['candidates_tried'])==3
assert len(d['successful_candidates'])==2
assert d['winner_agent']=='merged'
print('PASS')
" && assert_pass "consensus success JSON valid" || assert_fail "consensus JSON" "python assert failed"

# Test 3: build_status_json with exhausted
echo ""
echo "Test 3: build_status_json — consensus_exhausted"
RESULT=$(build_status_json "t003" "design_api" "consensus_exhausted" "exhausted" "t003.out" "2000" "merged" "gemini-pro,cc/claude-sonnet-4-6,minimax-code" "gemini-pro,minimax-code" "0.0" "2" ".exhausted" "240.0" "2026-04-24T12:00:00Z" "2026-04-24T12:04:00Z")
echo "$RESULT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['final_state']=='exhausted'
assert d['strategy_used']=='consensus_exhausted'
assert d['consensus_score']==0.0
assert d['reflexion_iterations']==2
assert '.exhausted' in d['markers']
print('PASS')
" && assert_pass "consensus_exhausted JSON valid" || assert_fail "exhausted JSON" "python assert failed"

# Test 4: atomic write
echo ""
echo "Test 4: write_task_status atomic write"
TEST_TID="status-atomic-test-$$"
TEST_JSON='{"schema_version":1,"task_id":"'"$TEST_TID"'","final_state":"done"}'
rm -f "$RESULTS_DIR/$TEST_TID.status.json" "$RESULTS_DIR/.${TEST_TID}.status.json.tmp"
write_task_status "$TEST_TID" "$TEST_JSON"
if [[ -f "$RESULTS_DIR/$TEST_TID.status.json" ]] && [[ ! -f "$RESULTS_DIR/.${TEST_TID}.status.json.tmp" ]]; then
    assert_pass "atomic write: .tmp renamed to final path"
else
    assert_fail "atomic write" "file missing or tmp leaked"
fi
rm -f "$RESULTS_DIR/$TEST_TID.status.json"

# Test 5: kill switch
echo ""
echo "Test 5: STATUS_JSON_DISABLED=1 kills writes"
TEST_TID="status-kill-test-$$"
rm -f "$RESULTS_DIR/$TEST_TID.status.json"
STATUS_JSON_DISABLED=1 write_task_status "$TEST_TID" '{"test":1}'
if [[ ! -f "$RESULTS_DIR/$TEST_TID.status.json" ]]; then
    assert_pass "kill switch: STATUS_JSON_DISABLED=1 prevents write"
else
    assert_fail "kill switch" "file was written despite DISABLED=1"
fi

echo ""
echo "------------------------------------------"
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS — Phase 8.1 task status JSON is healthy."
    exit 0
else
    echo "FAIL — $FAIL test(s) failed."
    exit 1
fi