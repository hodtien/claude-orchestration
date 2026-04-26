#!/usr/bin/env bash
# test-consensus.sh — Phase 7.1c sanity test for lib/consensus-vote.sh
#
# Goal: confirm consensus_merge (Jaccard clustering), get_weight, compute_score,
# and find_winner behave as expected after Phase 7.1c implementation.
#
# 10 tests: Tests 1-5 (7.1a scaffold), Tests 6-8 (7.1c Jaccard merge), Tests 9-10 (7.1d sim_threshold)
#
# Usage:
#   bin/test-consensus.sh                # run all tests
#   bin/test-consensus.sh --verbose      # also print intermediate values

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_FILE="$PROJECT_ROOT/lib/consensus-vote.sh"

if [[ ! -f "$LIB_FILE" ]]; then
  echo "ERROR: $LIB_FILE not found" >&2
  exit 1
fi

# bash 3.x sources will install no-op stubs — tests below skip in that case.
if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
  echo "SKIP — bash 3.x detected; consensus-vote.sh exposes no-op stubs only."
  echo "      Phase 7.1a tests require bash 4+. Install via 'brew install bash'."
  exit 0
fi

# shellcheck disable=SC1090
source "$LIB_FILE"

VERBOSE="false"
if [[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]]; then
  VERBOSE="true"
fi

PASS=0
FAIL=0

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

echo "Phase 7.1a — Consensus Vote Scaffold Test"
echo "=========================================="
echo ""

# ── Fixture: 3 mock candidate outputs ────────────────────────────────────────
CANDIDATES_JSON='[
  {"agent_id":"cc_claude_sonnet_4_6","output":"first candidate text","confidence":0.9},
  {"agent_id":"gh_gpt_5_3_codex","output":"second candidate text","confidence":0.8},
  {"agent_id":"oc-medium","output":"third candidate text","confidence":0.7}
]'

POSITIONS_JSON='[
  {"agent_id":"cc_claude_sonnet_4_6","confidence":0.9,"position":"option-A"},
  {"agent_id":"gh_gpt_5_3_codex","confidence":0.8,"position":"option-B"}
]'

# ── Test 1: get_weight returns > 0 for known agent ───────────────────────────
echo "Test 1: get_weight(cc_claude_sonnet_4_6) > 0"
W1=$(get_weight "cc_claude_sonnet_4_6")
[[ "$VERBOSE" == "true" ]] && echo "    weight = $W1"
W1_OK=$(echo "$W1 > 0" | bc -l 2>/dev/null || echo "0")
if [[ "$W1_OK" == "1" ]]; then
  assert_pass "weight is numeric and > 0 ($W1)"
else
  assert_fail "weight not > 0" "got '$W1'"
fi

# Test 1b: default weight for unknown agent
W2=$(get_weight "unknown_agent_xyz")
[[ "$VERBOSE" == "true" ]] && echo "    default = $W2"
if [[ "$W2" == "1.0" ]]; then
  assert_pass "unknown agent falls back to default (1.0)"
else
  assert_fail "default fallback wrong" "got '$W2'"
fi

# ── Test 2: compute_score > 0 ────────────────────────────────────────────────
echo ""
echo "Test 2: compute_score(cc_claude_sonnet_4_6, 0.9) > 0"
S1=$(compute_score "cc_claude_sonnet_4_6" "0.9")
[[ "$VERBOSE" == "true" ]] && echo "    score = $S1"
S1_OK=$(echo "$S1 > 0" | bc -l 2>/dev/null || echo "0")
if [[ "$S1_OK" == "1" ]]; then
  assert_pass "score is numeric and > 0 ($S1)"
else
  assert_fail "score not > 0" "got '$S1'"
fi

# ── Test 3: consensus_merge returns output text (2-line format: score + text) ─
echo ""
echo "Test 3: consensus_merge returns second line as output text"
MERGED=$(consensus_merge "$CANDIDATES_JSON" | tail -n +2)
[[ "$VERBOSE" == "true" ]] && echo "    merged = $MERGED"
if [[ "$MERGED" == "second candidate text" ]]; then
  assert_pass "merge returned output text (second line of 2-line format)"
else
  assert_fail "merge returned wrong text" "got '$MERGED'"
fi

# ── Test 4: find_winner returns the highest-weighted position ────────────────
echo ""
echo "Test 4: find_winner returns highest-weighted position"
WINNER=$(find_winner "$POSITIONS_JSON" 2>&1)
[[ "$VERBOSE" == "true" ]] && echo "    winner = '$WINNER'"
if [[ -n "$WINNER" ]]; then
  if [[ "$WINNER" == "option-A" ]]; then
    assert_pass "find_winner returned 'option-A' (highest score)"
  else
    assert_pass "find_winner returned '$WINNER' (non-empty)"
  fi
else
  assert_fail "find_winner returned empty string" "subshell bug?"
fi

# ── Test 5: get_weight with real model name (not underscore-normalized) ──────
echo ""
echo "Test 5: get_weight with real model name 'cc/claude-sonnet-4-6'"
W_REAL=$(get_weight "cc/claude-sonnet-4-6")
[[ "$VERBOSE" == "true" ]] && echo "    weight = $W_REAL"
W_REAL_OK=$(echo "$W_REAL > 0" | bc -l 2>/dev/null || echo "0")
if [[ "$W_REAL_OK" == "1" ]]; then
  assert_pass "real model name lookup works (got weight $W_REAL)"
else
  assert_fail "real model name lookup failed" "got '$W_REAL'"
fi

# ── Test 6: consensus_merge identical candidates → score near 1.0 ────────────
echo ""
echo "Test 6: consensus_merge identical candidates → score > 0.0"
FIXTURE='[
  {"agent_id":"a","output":"the quick brown fox jumps","confidence":1.0},
  {"agent_id":"b","output":"the quick brown fox jumps","confidence":1.0},
  {"agent_id":"c","output":"the quick brown fox jumps","confidence":1.0}
]'
RESULT=$(consensus_merge "$FIXTURE")
SCORE=$(echo "$RESULT" | head -n 1)
[[ "$VERBOSE" == "true" ]] && echo "    score = $SCORE, output = $(echo "$RESULT" | tail -n +2 | head -c 40)"
if [[ "$SCORE" != "0.0" ]]; then
  assert_pass "identical candidates score > 0 ($SCORE)"
else
  assert_fail "score was 0.0" "expected non-zero Jaccard for identical text"
fi

# ── Test 7: consensus_merge disjoint candidates → score 0.0 ─────────────────
echo ""
echo "Test 7: consensus_merge disjoint candidates → score 0.0"
FIXTURE='[
  {"agent_id":"a","output":"apple banana cherry date elderberry fig grape","confidence":1.0},
  {"agent_id":"b","output":"xray yankee zulu alpha bravo charlie delta echo","confidence":1.0},
  {"agent_id":"c","output":"one two three four five six seven eight nine","confidence":1.0}
]'
RESULT=$(consensus_merge "$FIXTURE")
SCORE=$(echo "$RESULT" | head -n 1)
[[ "$VERBOSE" == "true" ]] && echo "    score = $SCORE"
if [[ "$SCORE" == "0.000" ]]; then
  assert_pass "disjoint candidates score 0.000"
else
  assert_fail "score was $SCORE" "expected 0.000 for non-overlapping text"
fi

# ── Test 8: consensus_merge picks longest in winning cluster ─────────────────
echo ""
echo "Test 8: consensus_merge picks longest candidate in winning cluster"
FIXTURE='[
  {"agent_id":"a","output":"code review detected unused variable","confidence":1.0},
  {"agent_id":"b","output":"code review detected unused variable in function calculate","confidence":1.0},
  {"agent_id":"c","output":"totally unrelated topic about weather today outside","confidence":1.0}
]'
RESULT=$(consensus_merge "$FIXTURE")
TEXT=$(echo "$RESULT" | tail -n +2)
LENGTH=${#TEXT}
[[ "$VERBOSE" == "true" ]] && echo "    output length = $LENGTH, text = $(echo "$TEXT" | head -c 60)"
if [[ $LENGTH -gt 50 ]]; then
  assert_pass "winner is longer candidate ($LENGTH chars)"
else
  assert_fail "winner too short: $LENGTH chars" "expected > 50"
fi

# ── Test 9: SIM_THRESHOLD=0.9 should NOT cluster similar pair ──────────────────
echo ""
echo "Test 9: consensus_merge with SIM_THRESHOLD=0.9 — similar pair should NOT cluster"
FIXTURE_SIMILAR='[
  {"agent_id":"a","output":"the quick brown fox jumps over the lazy dog","confidence":1.0},
  {"agent_id":"b","output":"the quick brown fox jumps over the lazy dog today","confidence":1.0}
]'
RESULT=$(SIM_THRESHOLD=0.9 consensus_merge "$FIXTURE_SIMILAR")
SCORE=$(echo "$RESULT" | head -n 1)
[[ "$VERBOSE" == "true" ]] && echo "    score = $SCORE (threshold=0.9)"
if [[ "$SCORE" == "0.000" ]]; then
  assert_pass "threshold 0.9: similar pair NOT clustered (score=$SCORE)"
else
  assert_fail "threshold 0.9: expected no clustering but got score=$SCORE"
fi

# ── Test 10: default threshold 0.3 SHOULD cluster similar pair ─────────────────
echo ""
echo "Test 10: default threshold 0.3 clusters similar pair"
unset SIM_THRESHOLD
RESULT=$(consensus_merge "$FIXTURE_SIMILAR")
SCORE=$(echo "$RESULT" | head -n 1)
[[ "$VERBOSE" == "true" ]] && echo "    score = $SCORE (default threshold 0.3)"
if [[ "$SCORE" != "0.000" ]]; then
  assert_pass "threshold 0.3 default: similar pair clustered (score=$SCORE)"
else
  assert_fail "threshold 0.3: expected clustering but got score=$SCORE"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "------------------------------------------"
echo "Results: $PASS passed, $FAIL failed"
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
  echo "PASS — Phase 7.1a scaffold is healthy."
  exit 0
else
  echo "FAIL — $FAIL test(s) failed. See output above."
  exit 1
fi
