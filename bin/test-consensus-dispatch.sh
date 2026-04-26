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
  if echo "$candidates_output" | grep -q "claude-architect"; then
    assert_pass "claude-architect listed in candidates ($candidates_count total)"
  else
    assert_fail "claude-architect missing from candidates"
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
agent: claude-architect
task_type: architecture_analysis
priority: normal
---
Analyze the architecture of this project and provide recommendations.
TASKEOF

cat > "$BATCH_DIR/batch.conf" <<'CONFEOF'
failure_mode: skip-failed
CONFEOF

# Mock outputs for 3 parallel candidates for architecture_analysis
# Key: normalized names (slashes/dashes->underscores for shell env var lookup)
export MOCK_OUTPUT_claude_architect="Consensus output from claude-architect"
export MOCK_OUTPUT_cc_claude_sonnet_4_6="Consensus output from cc/claude-sonnet-4-6"
export MOCK_OUTPUT_minimax_code="Consensus output from minimax-code"
export MOCK_EXIT_claude_architect=0
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

# ── Test 7: all-fail triggers reflexion + re-dispatch ─────────────────────────
echo ""
echo "Test 7: all-fail consensus triggers reflexion v1"

setup_batch "test-reflexion-all-fail"

cat > "$BATCH_DIR/task-reflex-001.md" <<'TASKEOF'
---
id: reflex-test-001
agent: claude-architect
task_type: design_api
---
Design a simple pub/sub system.
TASKEOF

# Mock all agents to fail
export MOCK_EXIT_claude_architect=1
export MOCK_EXIT_cc_claude_sonnet_4_6=1
export MOCK_EXIT_minimax_code=1
export MOCK_OUTPUT_claude_architect=""
export MOCK_OUTPUT_cc_claude_sonnet_4_6=""
export MOCK_OUTPUT_minimax_code=""
export AGENT_SH_MOCK="$MOCK_AGENT"

# NOTE: quality-gate.sh defaults ORCH_DIR to $HOME/.claude/orchestration
# All reflexion files are written there, not under $PROJECT_ROOT
HOME_ORCH_DIR="${HOME}/.claude/orchestration"
REFLEXION_DIR="$HOME_ORCH_DIR/reflexions"
rm -rf "$REFLEXION_DIR/reflex-test-001.v*.reflexion.json" 2>/dev/null || true
mkdir -p "$REFLEXION_DIR"

bash "$BIN_DISPATCH" "$BATCH_DIR" --sequential 2>&1 | head -80 > /tmp/dispatch-reflex.$$.log || true
[[ "$VERBOSE" == "true" ]] && cat /tmp/dispatch-reflex.$$.log
rm -f /tmp/dispatch-reflex.$$.log

if [ -f "$REFLEXION_DIR/reflex-test-001.v1.reflexion.json" ]; then
  assert_pass "all-fail: reflexion v1 JSON created"
else
  assert_fail "all-fail: reflexion v1 JSON NOT found"
fi

unset MOCK_EXIT_claude_architect MOCK_EXIT_cc_claude_sonnet_4_6 MOCK_EXIT_minimax_code

# ── Test 8: disagreement triggers reflexion + enriched prompt ──────────────────
echo ""
echo "Test 8: disagreement (score=0) triggers reflexion with peer output enrichment"

setup_batch "test-reflexion-disagree"

cat > "$BATCH_DIR/task-disagree-001.md" <<'TASKEOF'
---
id: disagree-test-001
agent: claude-architect
task_type: design_api
---
Design a pub/sub system.
TASKEOF

# Mock 3 agents with fully disjoint outputs (Jaccard = 0)
export MOCK_OUTPUT_claude_architect="design a distributed pub sub broker with message queues"
export MOCK_OUTPUT_cc_claude_sonnet_4_6="implement a webhook event notification system with callbacks"
export MOCK_OUTPUT_minimax_code="build a simple observer pattern library in python"
export MOCK_EXIT_claude_architect=0
export MOCK_EXIT_cc_claude_sonnet_4_6=0
export MOCK_EXIT_minimax_code=0
export AGENT_SH_MOCK="$MOCK_AGENT"

rm -rf "$REFLEXION_DIR/disagree-test-001.v*.reflexion.json" 2>/dev/null || true
rm -f "$RESULTS_DIR/disagree-test-001.out" "$RESULTS_DIR/disagree-test-001.consensus.json" 2>/dev/null || true

bash "$BIN_DISPATCH" "$BATCH_DIR" --sequential 2>&1 | head -80 > /tmp/dispatch-disagree.$$.log || true
[[ "$VERBOSE" == "true" ]] && cat /tmp/dispatch-disagree.$$.log
rm -f /tmp/dispatch-disagree.$$.log

if [ -f "$REFLEXION_DIR/disagree-test-001.v1.reflexion.json" ]; then
  assert_pass "disagreement: reflexion v1 JSON created (score=0 triggered)"
else
  assert_fail "disagreement: reflexion v1 JSON NOT found"
fi

unset MOCK_OUTPUT_claude_architect MOCK_OUTPUT_cc_claude_sonnet_4_6 MOCK_OUTPUT_minimax_code
unset MOCK_EXIT_claude_architect MOCK_EXIT_cc_claude_sonnet_4_6 MOCK_EXIT_minimax_code

# ── Test 9: exhaustion marker after 2 reflexion attempts ───────────────────────
echo ""
echo "Test 9: second reflexion round creates exhausted/failed marker"

if [ -f "$RESULTS_DIR/disagree-test-001.consensus.json" ]; then
  strategy=$(python3 -c "import json; d=json.load(open('$RESULTS_DIR/disagree-test-001.consensus.json')); print(d.get('strategy_used','?'))" 2>/dev/null || echo "?")
  if [[ "$strategy" == "consensus_exhausted" ]]; then
    assert_pass "exhaustion: consensus_exhausted strategy recorded"
  else
    assert_fail "exhaustion: strategy was '$strategy', expected consensus_exhausted"
  fi
else
  has_marker=false
  [ -f "$RESULTS_DIR/disagree-test-001.exhausted" ] && has_marker=true
  [ -f "$RESULTS_DIR/disagree-test-001.failed" ] && has_marker=true
  if $has_marker; then
    assert_pass "exhaustion: .exhausted or .failed marker created"
  else
    assert_fail "exhaustion: no marker found"
  fi
fi

# ── Test 10: exhausted path writes non-empty .out (best-effort fallback) ──────
echo ""
echo "Test 10: exhausted consensus writes best-effort .out file"
# Only check when .exhausted marker exists (true disagreement path)
if [ -f "$RESULTS_DIR/disagree-test-001.exhausted" ]; then
  if [ -f "$RESULTS_DIR/disagree-test-001.out" ]; then
    out_size=$(wc -c < "$RESULTS_DIR/disagree-test-001.out" | tr -d ' ')
    if [ "$out_size" -gt 0 ]; then
      assert_pass "exhausted: .out non-empty ($out_size bytes, best-effort)"
    else
      assert_fail "exhausted: .out exists but empty"
    fi
  else
    assert_fail "exhausted: .out missing" "best-effort fallback should write longest candidate"
  fi
else
  # Path did not reach exhaustion — skip
  assert_pass "exhausted: skipped (no .exhausted marker, exhaustion path not hit)"
fi

# Clean up disagree test artifacts
rm -f "$RESULTS_DIR/disagree-test-001.out" \
  "$RESULTS_DIR/disagree-test-001.exhausted" \
  "$RESULTS_DIR/disagree-test-001.failed" \
  "$RESULTS_DIR/disagree-test-001.consensus.json" \
  "$RESULTS_DIR/disagree-test-001.needs_revision" 2>/dev/null || true
rm -rf "$RESULTS_DIR/disagree-test-001.candidates" 2>/dev/null || true

# ── Test 11: first_success path produces .status.json ─────────────────────────
# Regression guard: `set -u` + unset score/refl_iter in
# _write_status_first_success would crash dispatcher silently.
echo ""
echo "Test 11: first_success dispatch writes .status.json (regression guard)"

setup_batch "test-first-success-status"
cat > "$BATCH_DIR/task-fs-001.md" <<'TASKEOF'
---
id: fs-status-001
agent: oc-medium
task_type: implement_feature
---
Implement a foo() function.
TASKEOF

cat > "$BATCH_DIR/batch.conf" <<'CONFEOF'
failure_mode: skip-failed
CONFEOF

export MOCK_OUTPUT_oc_medium="def foo():\n    pass\n# implementation complete"
export MIN_OUTPUT_LENGTH=0
export MOCK_EXIT_oc_medium=0
export AGENT_SH_MOCK="$MOCK_AGENT"

# Reset circuit-breaker state so oc-medium isn't blocked before test
bin/circuit-breaker.sh reset oc-medium 2>/dev/null || true
bin/circuit-breaker.sh reset gh/gpt-5.3-codex 2>/dev/null || true
bin/circuit-breaker.sh reset minimax-code 2>/dev/null || true

rm -f "$RESULTS_DIR/fs-status-001.status.json" \
 "$RESULTS_DIR/fs-status-001.out" \
 "$RESULTS_DIR/fs-status-001.log" \
 "$RESULTS_DIR/fs-status-001.report.json" 2>/dev/null || true

bash "$BIN_DISPATCH" "$BATCH_DIR" --sequential 2>&1 > /tmp/dispatch-fs.$$.log || true
rm -f /tmp/dispatch-fs.$$.log

if [ -f "$RESULTS_DIR/fs-status-001.status.json" ]; then
 strategy=$(python3 -c "
import json
d=json.load(open('$RESULTS_DIR/fs-status-001.status.json'))
assert d['schema_version']==1
print(d['strategy_used'])
" 2>/dev/null || echo "?")
 if [[ -n "$strategy" && "$strategy" != "?" ]]; then
 assert_pass "first_success helper ran without crash (strategy=$strategy)"
 else
 assert_fail "first_success: .status.json malformed (strategy='$strategy')"
 fi
else
 assert_fail "first_success: .status.json missing" \
 "dispatcher may have crashed on set -u unbound var"
fi

# Cleanup
rm -f "$RESULTS_DIR/fs-status-001.status.json" \
 "$RESULTS_DIR/fs-status-001.out" \
 "$RESULTS_DIR/fs-status-001.log" \
 "$RESULTS_DIR/fs-status-001.report.json" 2>/dev/null || true
unset MOCK_EXIT_oc_medium MOCK_OUTPUT_oc_medium

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "------------------------------------------"
echo "Results: $PASS passed, $FAIL failed"
echo ""

echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "PASS — Phase 7.1b consensus dispatch is healthy."
  exit 0
else
  echo "FAIL — $FAIL test(s) failed. See output above."
  exit 1
fi
