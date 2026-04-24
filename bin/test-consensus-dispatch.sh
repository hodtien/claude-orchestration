#!/usr/bin/env bash
# test-consensus-dispatch.sh — Phase 7.1b consensus fan-out dispatch tests
#
# Goal: confirm the consensus dispatch path (is_consensus_type, get_pick_strategy,
# get_parallel_candidates, escape_agent_filename, dispatch_task consensus routing)
# behaves as expected using mock-agent.sh.
#
# Usage:
#   bin/test-consensus-dispatch.sh              # run all tests
#   bin/test-consensus-dispatch.sh --verbose   # also print intermediate values

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DISPATCH="$SCRIPT_DIR/task-dispatch.sh"
MODELS_YAML="$PROJECT_ROOT/config/models.yaml"
MOCK_AGENT="$PROJECT_ROOT/tests/fixtures/mock-agent.sh"

if [[ ! -f "$BIN_DISPATCH" ]]; then
  echo "ERROR: $BIN_DISPATCH not found" >&2
  exit 1
fi

if [[ ! -f "$MODELS_YAML" ]]; then
  echo "ERROR: $MODELS_YAML not found" >&2
  exit 1
fi

if [[ ! -x "$MOCK_AGENT" ]]; then
  echo "ERROR: $MOCK_AGENT not found or not executable" >&2
  exit 1
fi

# bash 3.x — skip since consensus helpers require bash 4+
if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
  echo "SKIP — bash 3.x detected; consensus helpers require bash 4+."
  exit 0
fi

# yq required for consensus helper functions
if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP — yq not installed. Install: brew install yq"
  exit 0
fi

VERBOSE="false"
if [[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]]; then
  VERBOSE="true"
fi

PASS=0
FAIL=0
BATCH_DIR=""
RESULTS_DIR=""
PIDS_DIR=""

cleanup() {
  unset AGENT_SH_MOCK MOCK_OUTPUT_* MOCK_EXIT_* 2>/dev/null || true
  [[ -n "$BATCH_DIR" ]] && rm -rf "$BATCH_DIR" 2>/dev/null || true
  rm -f "$RESULTS_DIR/arch-test-001.out" "$RESULTS_DIR/arch-test-001.log" \
    "$RESULTS_DIR/arch-test-001.consensus.json" "$RESULTS_DIR/arch-test-001.report.json" \
    "$RESULTS_DIR/arch-test-001.cancelled" \
    "$RESULTS_DIR/impl-test-001.out" "$RESULTS_DIR/impl-test-001.log" \
    "$RESULTS_DIR/impl-test-001.report.json" "$RESULTS_DIR/impl-test-001.cancelled" \
    "$RESULTS_DIR/.arch-test-001.revlock" "$RESULTS_DIR/.impl-test-001.revlock" \
    "$RESULTS_DIR/arch-test-001.candidates" \
    2>/dev/null || true
}
trap cleanup EXIT

assert_pass() {
  local name="$1"
  printf "  ✓ %s\n" "$name"
  PASS=$((PASS + 1))
}

assert_fail() {
  local name="$1"
  local detail="${2:-}"
  printf "  ✗ %s" "$name"
  [[ -n "$detail" ]] && printf " — %s" "$detail"
  printf "\n"
  FAIL=$((FAIL + 1))
}

setup_batch() {
  local batch_id="$1"
  BATCH_DIR=$(mktemp -d "$PROJECT_ROOT/.orchestration/tasks/${batch_id}.XXXXXX")
  RESULTS_DIR="$PROJECT_ROOT/.orchestration/results"
  PIDS_DIR="$PROJECT_ROOT/.orchestration/pids"
  mkdir -p "$RESULTS_DIR" "$PIDS_DIR"
}

# ── Consensus helpers (mirrored from task-dispatch.sh for test isolation) ──────
is_consensus_type() {
  local task_type="$1"
  local enabled
  enabled=$(yq -r ".task_mapping.${task_type}.consensus // false" \
    "$MODELS_YAML" 2>/dev/null)
  [[ "$enabled" == "true" ]]
}

get_pick_strategy() {
  yq -r ".parallel_policy.pick_strategy // \"first_success\"" \
    "$MODELS_YAML" 2>/dev/null
}

get_parallel_candidates() {
  local task_type="$1" max_parallel
  max_parallel=$(yq -r ".parallel_policy.max_parallel // 3" "$MODELS_YAML")
  yq -r ".task_mapping.${task_type}.parallel[]" "$MODELS_YAML" 2>/dev/null \
    | head -n "$max_parallel"
}

escape_agent_filename() {
  local agent="$1"
  echo "${agent//\//_}"
}

# Source consensus-vote.sh for consensus_merge
if [ -f "$PROJECT_ROOT/lib/consensus-vote.sh" ]; then
  # shellcheck source=../lib/consensus-vote.sh
  . "$PROJECT_ROOT/lib/consensus-vote.sh"
fi

echo "Phase 7.1b — Consensus Fan-Out Dispatch Test"
echo "==============================================="
echo ""

# ── Test 1: is_consensus_type returns true for architecture_analysis ───────────
echo "Test 1: is_consensus_type(architecture_analysis) == true"
if is_consensus_type "architecture_analysis"; then
  assert_pass "architecture_analysis is consensus type"
else
  assert_fail "architecture_analysis should be consensus type"
fi

# ── Test 2: is_consensus_type returns false for implement_feature ──────────────
echo ""
echo "Test 2: is_consensus_type(implement_feature) == false"
if is_consensus_type "implement_feature"; then
  assert_fail "implement_feature should NOT be consensus type" "got true"
else
  assert_pass "implement_feature is NOT consensus type"
fi

# ── Test 3: get_pick_strategy returns consensus ───────────────────────────────
echo ""
echo "Test 3: get_pick_strategy() == consensus"
strategy=$(get_pick_strategy)
if [[ "$strategy" == "consensus" ]]; then
  assert_pass "pick_strategy is 'consensus' (got '$strategy')"
else
  assert_fail "pick_strategy wrong" "got '$strategy'"
fi

# ── Test 4: get_parallel_candidates returns correct list for consensus type ───────
echo ""
echo "Test 4: get_parallel_candidates(architecture_analysis) returns candidates"
candidates_output=$(get_parallel_candidates "architecture_analysis")
[[ "$VERBOSE" == "true" ]] && echo "    candidates = $candidates_output"
candidates_count=$(echo "$candidates_output" | grep -c . || echo 0)
if [[ "$candidates_count" -gt 0 ]]; then
  if echo "$candidates_output" | grep -q "gemini-pro"; then
    assert_pass "gemini-pro listed in candidates ($candidates_count total)"
  else
    assert_fail "gemini-pro missing from candidates"
  fi
else
  assert_fail "get_parallel_candidates returned empty"
fi

# ── Test 5: escape_agent_filename normalizes slash to underscore ──────────────
echo ""
echo "Test 5: escape_agent_filename(cc/claude-sonnet-4-6) normalizes slashes"
escaped=$(escape_agent_filename "cc/claude-sonnet-4-6")
if [[ "$escaped" == "cc_claude-sonnet-4-6" ]]; then
  assert_pass "slash normalized to underscore (got '$escaped')"
else
  assert_fail "escape_agent_filename wrong" "got '$escaped', expected 'cc_claude-sonnet-4-6'"
fi

# ── Test 6: dispatch with AGENT_SH_MOCK — consensus type produces result ─────────
echo ""
echo "Test 6: dispatch task with consensus type (architecture_analysis)"

setup_batch "test-consensus-routing"

cat > "$BATCH_DIR/task-arch-test.md" <<'TASKEOF'
---
id: arch-test-001
agent: gemini-pro
task_type: architecture_analysis
priority: normal
---
Analyze the architecture of this project and provide recommendations.
TASKEOF

cat > "$BATCH_DIR/batch.conf" <<'CONFEOF'
failure_mode: skip-failed
CONFEOF

# Mock outputs for 3 parallel candidates for architecture_analysis
# Key: normalized names (slashes->underscores for shell env var lookup)
export MOCK_OUTPUT_gemini_pro="Consensus output from gemini-pro"
export MOCK_OUTPUT_cc_claude_sonnet_4_6="Consensus output from cc/claude-sonnet-4-6"
export MOCK_OUTPUT_minimax_code="Consensus output from minimax-code"
export MOCK_EXIT_gemini_pro=0
export MOCK_EXIT_cc_claude_sonnet_4_6=0
export MOCK_EXIT_minimax_code=0

export AGENT_SH_MOCK="$MOCK_AGENT"

# Run dispatcher — consensus path writes candidates/ dir + consensus.json
bash "$BIN_DISPATCH" "$BATCH_DIR" --sequential 2>&1 | head -50 > /tmp/dispatch-out.$$.log || true
[[ "$VERBOSE" == "true" ]] && cat /tmp/dispatch-out.$$.log
rm -f /tmp/dispatch-out.$$.log

if [ -f "$RESULTS_DIR/arch-test-001.out" ]; then
  output_size=$(wc -c < "$RESULTS_DIR/arch-test-001.out" | tr -d ' ')
  [[ "$VERBOSE" == "true" ]] && echo "    result output: $output_size bytes"
  if [ "$output_size" -gt 0 ]; then
    assert_pass "consensus dispatch produced output ($output_size bytes)"
  else
    assert_fail "consensus dispatch produced empty output"
  fi
else
  assert_fail "consensus dispatch produced no result file"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "------------------------------------------"
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
  echo "PASS — Phase 7.1b consensus dispatch is healthy."
  exit 0
else
  echo "FAIL — $FAIL test(s) failed. See output above."
  exit 1
fi
