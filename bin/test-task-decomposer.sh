#!/usr/bin/env bash
# test-task-decomposer.sh — Phase 9.1 test suite for lib/task-decomposer.sh
#
# 15 tests covering: estimate_complexity, decompose_task, analyze_intent,
# generate_spec, strategy detection, graph generation.
#
# Usage:
#   bin/test-task-decomposer.sh           # run all tests
#   bin/test-task-decomposer.sh --verbose # print intermediate values

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_FILE="$PROJECT_ROOT/lib/task-decomposer.sh"
FIXTURES="$PROJECT_ROOT/test-fixtures/decomposer"

if [[ ! -f "$LIB_FILE" ]]; then
  echo "ERROR: $LIB_FILE not found" >&2
  exit 1
fi

# Use temp dir for decomposition output to avoid polluting real orchestration
TMPDIR_DECOMP="$(mktemp -d)"
export ORCH_DIR="$TMPDIR_DECOMP"
export DECOMP_DIR="$TMPDIR_DECOMP/decomposed"
mkdir -p "$DECOMP_DIR"

# shellcheck disable=SC1090
source "$LIB_FILE"

VERBOSE="false"
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE="true"

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

cleanup() {
  rm -rf "$TMPDIR_DECOMP"
}
trap cleanup EXIT

echo "Phase 9.1 — Task Decomposer Test Suite"
echo "======================================="
echo ""

# ── Test 1: estimate_complexity baseline ─────────────────────────────────────
echo "Test 1: estimate_complexity with plain text (baseline ~500)"
C1=$(estimate_complexity "add a button to the UI")
[[ "$VERBOSE" == "true" ]] && echo "    complexity = $C1"
if [[ "$C1" -ge 400 ]] && [[ "$C1" -le 900 ]]; then
  assert_pass "baseline complexity in expected range ($C1)"
else
  assert_fail "baseline complexity out of range" "got $C1, expected 400-900"
fi

# ── Test 2: estimate_complexity with keywords ────────────────────────────────
echo ""
echo "Test 2: estimate_complexity with security+database keywords"
C2=$(estimate_complexity "refactor the security layer and fix the database migration")
[[ "$VERBOSE" == "true" ]] && echo "    complexity = $C2"
if [[ "$C2" -ge 1500 ]]; then
  assert_pass "keyword-boosted complexity >= 1500 ($C2)"
else
  assert_fail "keyword boost too low" "got $C2, expected >= 1500"
fi

# ── Test 3: estimate_complexity with file reference ──────────────────────────
echo ""
echo "Test 3: estimate_complexity with file line count"
C3=$(estimate_complexity "update lib/task-decomposer.sh" "$LIB_FILE")
[[ "$VERBOSE" == "true" ]] && echo "    complexity = $C3"
if [[ "$C3" -ge 2000 ]]; then
  assert_pass "file-boosted complexity >= 2000 ($C3)"
else
  assert_fail "file boost too low" "got $C3, expected >= 2000"
fi

# ── Test 4: decompose_task short spec → single unit ─────────────────────────
echo ""
echo "Test 4: decompose_task on short spec → 1 unit"
SHORT_BODY=$(cat "$FIXTURES/short-spec.md")
D4=$(decompose_task "short-test-001" "$SHORT_BODY" 500)
[[ "$VERBOSE" == "true" ]] && echo "    output_dir = $D4"
UNIT_COUNT_4=$(ls "$D4"/unit-*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$UNIT_COUNT_4" -eq 1 ]]; then
  assert_pass "short spec produced 1 unit"
else
  assert_fail "short spec unit count wrong" "got $UNIT_COUNT_4, expected 1"
fi

# ── Test 5: decompose_task long spec → multiple units ───────────────────────
echo ""
echo "Test 5: decompose_task on long spec → multiple units"
LONG_BODY=$(cat "$FIXTURES/long-spec.md")
D5=$(decompose_task "long-test-001" "$LONG_BODY" 8000)
[[ "$VERBOSE" == "true" ]] && echo "    output_dir = $D5"
UNIT_COUNT_5=$(ls "$D5"/unit-*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$UNIT_COUNT_5" -ge 2 ]]; then
  assert_pass "long spec produced >= 2 units ($UNIT_COUNT_5)"
else
  assert_fail "long spec unit count too low" "got $UNIT_COUNT_5, expected >= 2"
fi

# ── Test 6: decompose_task meta.json exists and valid ────────────────────────
echo ""
echo "Test 6: decompose_task writes valid meta.json"
META_FILE="$D5/meta.json"
if [[ -f "$META_FILE" ]]; then
  META_VALID=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('ok' if 'task_id' in d and 'unit_count' in d else 'bad')" "$META_FILE" 2>/dev/null || echo "bad")
  [[ "$VERBOSE" == "true" ]] && echo "    meta = $(cat "$META_FILE")"
  if [[ "$META_VALID" == "ok" ]]; then
    assert_pass "meta.json valid with task_id and unit_count"
  else
    assert_fail "meta.json missing required fields"
  fi
else
  assert_fail "meta.json not created"
fi

# ── Test 7: strategy detection — parallel ────────────────────────────────────
echo ""
echo "Test 7: decompose_task detects parallel strategy"
PAR_BODY=$(cat "$FIXTURES/parallel-spec.md")
D7=$(decompose_task "par-test-001" "$PAR_BODY" 1500)
META7="$D7/meta.json"
STRAT7=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['strategy'])" "$META7" 2>/dev/null || echo "unknown")
[[ "$VERBOSE" == "true" ]] && echo "    strategy = $STRAT7"
if [[ "$STRAT7" == "parallel" ]]; then
  assert_pass "parallel strategy detected"
else
  assert_fail "parallel strategy not detected" "got '$STRAT7'"
fi

# ── Test 8: strategy detection — pipeline ────────────────────────────────────
echo ""
echo "Test 8: decompose_task detects pipeline strategy"
PIPE_BODY=$(cat "$FIXTURES/pipeline-spec.md")
D8=$(decompose_task "pipe-test-001" "$PIPE_BODY" 1500)
META8="$D8/meta.json"
STRAT8=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['strategy'])" "$META8" 2>/dev/null || echo "unknown")
[[ "$VERBOSE" == "true" ]] && echo "    strategy = $STRAT8"
if [[ "$STRAT8" == "pipeline" ]]; then
  assert_pass "pipeline strategy detected"
else
  assert_fail "pipeline strategy not detected" "got '$STRAT8'"
fi

# ── Test 9: strategy detection — sequential default ──────────────────────────
echo ""
echo "Test 9: decompose_task defaults to sequential for neutral text"
D9=$(decompose_task "seq-test-001" "$SHORT_BODY" 500)
META9="$D9/meta.json"
STRAT9=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['strategy'])" "$META9" 2>/dev/null || echo "unknown")
[[ "$VERBOSE" == "true" ]] && echo "    strategy = $STRAT9"
if [[ "$STRAT9" == "sequential" ]]; then
  assert_pass "sequential strategy as default"
else
  assert_fail "sequential strategy not defaulted" "got '$STRAT9'"
fi

# ── Test 10: dependencies.dot generated ──────────────────────────────────────
echo ""
echo "Test 10: decompose_task generates dependencies.dot"
DOT_FILE="$D8/dependencies.dot"
if [[ -f "$DOT_FILE" ]]; then
  HAS_DIGRAPH=$(grep -c "digraph" "$DOT_FILE" 2>/dev/null || echo "0")
  [[ "$VERBOSE" == "true" ]] && echo "    dot lines = $(wc -l < "$DOT_FILE" | tr -d ' ')"
  if [[ "$HAS_DIGRAPH" -ge 1 ]]; then
    assert_pass "dependencies.dot contains digraph"
  else
    assert_fail "dependencies.dot missing digraph keyword"
  fi
else
  assert_fail "dependencies.dot not generated"
fi

# ── Test 11: analyze_intent — security classification ────────────────────────
echo ""
echo "Test 11: analyze_intent classifies security intent"
INTENT11=$(analyze_intent "audit the system for security vulnerabilities and threats")
TYPE11=$(echo "$INTENT11" | python3 -c "import json,sys; print(json.load(sys.stdin)['intent_type'])" 2>/dev/null || echo "unknown")
[[ "$VERBOSE" == "true" ]] && echo "    intent_type = $TYPE11"
if [[ "$TYPE11" == "security" ]]; then
  assert_pass "security intent classified correctly"
else
  assert_fail "security intent wrong" "got '$TYPE11'"
fi

# ── Test 12: analyze_intent — feature classification ─────────────────────────
echo ""
echo "Test 12: analyze_intent classifies feature intent"
INTENT12=$(analyze_intent "implement a new caching layer for the API")
TYPE12=$(echo "$INTENT12" | python3 -c "import json,sys; print(json.load(sys.stdin)['intent_type'])" 2>/dev/null || echo "unknown")
[[ "$VERBOSE" == "true" ]] && echo "    intent_type = $TYPE12"
if [[ "$TYPE12" == "feature" ]]; then
  assert_pass "feature intent classified correctly"
else
  assert_fail "feature intent wrong" "got '$TYPE12'"
fi

# ── Test 13: analyze_intent — scope detection ────────────────────────────────
echo ""
echo "Test 13: analyze_intent detects system scope"
INTENT13=$(analyze_intent "refactor the entire architecture to microservices")
SCOPE13=$(echo "$INTENT13" | python3 -c "import json,sys; print(json.load(sys.stdin)['scope'])" 2>/dev/null || echo "unknown")
[[ "$VERBOSE" == "true" ]] && echo "    scope = $SCOPE13"
if [[ "$SCOPE13" == "system" ]]; then
  assert_pass "system scope detected"
else
  assert_fail "scope wrong" "got '$SCOPE13', expected 'system'"
fi

# ── Test 14: generate_spec — security routes to gemini ───────────────────────
echo ""
echo "Test 14: generate_spec routes security to gemini agent"
INTENT14=$(analyze_intent "audit the system for security vulnerabilities")
SPEC14=$(generate_spec "$INTENT14")
AGENT14=$(echo "$SPEC14" | grep "^agent:" | head -1 | sed 's/agent: *//')
[[ "$VERBOSE" == "true" ]] && echo "    agent = $AGENT14"
if [[ "$AGENT14" == "gemini" ]]; then
  assert_pass "security task routed to gemini"
else
  assert_fail "security routing wrong" "got '$AGENT14', expected 'gemini'"
fi

# ── Test 15: generate_spec — high priority for security ──────────────────────
echo ""
echo "Test 15: generate_spec sets high priority for security"
PRIO15=$(echo "$SPEC14" | grep "^priority:" | head -1 | sed 's/priority: *//')
[[ "$VERBOSE" == "true" ]] && echo "    priority = $PRIO15"
if [[ "$PRIO15" == "high" ]]; then
  assert_pass "security task priority is high"
else
  assert_fail "security priority wrong" "got '$PRIO15', expected 'high'"
fi

# ── Test 16: batch.conf auto_decompose parsed without crash ──────────────────
echo ""
echo "Test 16: batch.conf auto_decompose: true parsed by task-dispatch.sh"
TMPBATCH=$(mktemp -d)
cat > "$TMPBATCH/batch.conf" <<CONF
failure_mode: skip-failed
auto_decompose: true
CONF
DISPATCH_OUT=$(bash "$SCRIPT_DIR/task-dispatch.sh" "$TMPBATCH" --status 2>&1) || true
rm -rf "$TMPBATCH"
if echo "$DISPATCH_OUT" | grep -qiE 'batch|status|tasks|total|done|pending'; then
  assert_pass "batch.conf auto_decompose parsed without crash"
else
  assert_fail "batch.conf auto_decompose parse crashed or unexpected output" "${DISPATCH_OUT:0:200}"
fi

# ── Test 17: idempotent double-source ────────────────────────────────────────
echo ""
echo "Test 17: source lib/task-decomposer.sh twice has no side effects"
DOUBLE_SOURCE_OUT=$(
  TMPCHECK="$TMPDIR_DECOMP/dbl"
  export ORCH_DIR="$TMPCHECK"
  export DECOMP_DIR="$TMPCHECK/decomposed"
  # shellcheck disable=SC1090
  bash -c "source '$LIB_FILE'; source '$LIB_FILE'; echo double-source-ok"
) 2>/dev/null || true
if [[ "$DOUBLE_SOURCE_OUT" == *"double-source-ok"* ]]; then
  assert_pass "idempotent double-source: no error on second source"
else
  assert_fail "double-source failed or produced unexpected output" "got: $DOUBLE_SOURCE_OUT"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"

if [[ "$FAIL" -eq 0 ]]; then
  exit 0
else
  exit 1
fi
