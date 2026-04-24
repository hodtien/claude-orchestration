#!/usr/bin/env bash
# test-consensus.sh — Phase 7.1a sanity test for lib/consensus-vote.sh
#
# Goal: confirm the scaffolded consensus library functions (get_weight,
# compute_score, consensus_merge, find_winner) behave as expected after
# the Phase 7.1a remap and consensus_merge placeholder addition.
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
  {"agent_id":"gemmed","output":"third candidate text","confidence":0.7}
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

# ── Test 3: consensus_merge returns first candidate's output text ────────────
echo ""
echo "Test 3: consensus_merge returns first candidate's output"
MERGED=$(consensus_merge "$CANDIDATES_JSON")
[[ "$VERBOSE" == "true" ]] && echo "    merged = $MERGED"
if [[ "$MERGED" == "first candidate text" ]]; then
  assert_pass "merge returned first candidate output"
else
  assert_fail "merge returned wrong text" "got '$MERGED'"
fi

# ── Test 4: find_winner runs without error on simple positions array ─────────
echo ""
echo "Test 4: find_winner runs without error"
if WINNER=$(find_winner "$POSITIONS_JSON" 2>&1); then
  [[ "$VERBOSE" == "true" ]] && echo "    winner = '$WINNER'"
  assert_pass "find_winner exited 0 (output: '$WINNER')"
else
  assert_fail "find_winner exited non-zero" "$WINNER"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "------------------------------------------"
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
  echo "PASS — Phase 7.1a scaffold is healthy."
  exit 0
else
  echo "FAIL — $FAIL test(s) failed. See output above."
  exit 1
fi
