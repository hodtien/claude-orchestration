#!/usr/bin/env bash
# test-selfheal-redispatch.sh — tests for 11.5 self-healing DAG redispatch
# Validates suggest_spec_fix() and learn_from_fix() in lib/learning-engine.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        FAIL=$((FAIL+1))
    fi
}

assert_gt() {
    local label="$1" min="$2" actual="$3"
    if python3 -c "import sys; sys.exit(0 if float(sys.argv[1])>float(sys.argv[2]) else 1)" "$actual" "$min" 2>/dev/null; then
        echo "PASS: $label ($actual > $min)"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label — $actual not > $min"
        FAIL=$((FAIL+1))
    fi
}

assert_lt() {
    local label="$1" max="$2" actual="$3"
    if python3 -c "import sys; sys.exit(0 if float(sys.argv[1])<float(sys.argv[2]) else 1)" "$actual" "$max" 2>/dev/null; then
        echo "PASS: $label ($actual < $max)"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label — $actual not < $max"
        FAIL=$((FAIL+1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label"
        echo "  expected to contain: $needle"
        echo "  actual: $haystack"
        FAIL=$((FAIL+1))
    fi
}

# Isolate test storage
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

export ORCH_DIR="$TEST_TMP/.orchestration"
export LEARN_DIR="$ORCH_DIR/learnings"
export LEARN_DB="$LEARN_DIR/learnings.jsonl"
export ROUTING_RULES="$LEARN_DIR/routing-rules.json"
mkdir -p "$LEARN_DIR" "$ORCH_DIR/dlq"

# shellcheck source=../lib/learning-engine.sh
. "$PROJECT_ROOT/lib/learning-engine.sh"

# ── Test 1: timeout failure → transient with high confidence ─────────────────
TID="t-timeout-001"
ERR_PATH="$ORCH_DIR/dlq/${TID}.error.log"
SPEC_PATH="$ORCH_DIR/dlq/${TID}.spec.md"
echo "Error: connection refused, timed out after 60s" > "$ERR_PATH"
cat > "$SPEC_PATH" <<'SPEC'
---
id: t-timeout-001
agent: copilot
task_type: implement_feature
---
Implement timeout-prone feature.
SPEC

RESULT=$(suggest_spec_fix "$TID" "$ERR_PATH" "$SPEC_PATH")
TYPE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['fix_type'])" "$RESULT")
CONF=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['confidence'])" "$RESULT")
assert_eq "timeout failure classified as transient" "transient" "$TYPE"
assert_gt "transient confidence > 0.7" "0.7" "$CONF"

# ── Test 2: budget failure → budget with patched model ───────────────────────
TID="t-budget-001"
ERR_PATH="$ORCH_DIR/dlq/${TID}.error.log"
SPEC_PATH="$ORCH_DIR/dlq/${TID}.spec.md"
echo "Error: token budget exceeded for this batch (rate limit)" > "$ERR_PATH"
cat > "$SPEC_PATH" <<'SPEC'
---
id: t-budget-001
agent: copilot
model: claude-opus-4-7
task_type: implement_feature
---
Heavy feature.
SPEC

RESULT=$(suggest_spec_fix "$TID" "$ERR_PATH" "$SPEC_PATH")
TYPE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['fix_type'])" "$RESULT")
PATCHED=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['patched_spec'])" "$RESULT")
assert_eq "budget failure classified" "budget" "$TYPE"
assert_contains "patched spec routes to haiku" "claude-haiku-4-5-20251001" "$PATCHED"

# ── Test 3: impossible → low confidence ───────────────────────────────────────
TID="t-impossible-001"
ERR_PATH="$ORCH_DIR/dlq/${TID}.error.log"
SPEC_PATH="$ORCH_DIR/dlq/${TID}.spec.md"
echo "Error: cannot complete task — file does not exist, blocked" > "$ERR_PATH"
cat > "$SPEC_PATH" <<'SPEC'
---
id: t-impossible-001
agent: copilot
task_type: implement_feature
---
Bad feature.
SPEC

RESULT=$(suggest_spec_fix "$TID" "$ERR_PATH" "$SPEC_PATH")
TYPE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['fix_type'])" "$RESULT")
CONF=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['confidence'])" "$RESULT")
assert_eq "impossible failure classified" "impossible" "$TYPE"
assert_lt "impossible confidence < 0.3" "0.3" "$CONF"

# ── Test 4: malformed → low confidence ────────────────────────────────────────
TID="t-malformed-001"
ERR_PATH="$ORCH_DIR/dlq/${TID}.error.log"
SPEC_PATH="$ORCH_DIR/dlq/${TID}.spec.md"
echo "Error: yaml parse error invalid syntax in frontmatter" > "$ERR_PATH"
cat > "$SPEC_PATH" <<'SPEC'
---
id: t-malformed-001
agent: copilot
task_type: implement_feature
---
Feature.
SPEC

RESULT=$(suggest_spec_fix "$TID" "$ERR_PATH" "$SPEC_PATH")
TYPE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['fix_type'])" "$RESULT")
CONF=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['confidence'])" "$RESULT")
assert_eq "malformed failure classified" "malformed" "$TYPE"
assert_lt "malformed confidence < 0.4" "0.4" "$CONF"

# ── Test 5: unknown failure → fallback ────────────────────────────────────────
TID="t-unknown-001"
ERR_PATH="$ORCH_DIR/dlq/${TID}.error.log"
SPEC_PATH="$ORCH_DIR/dlq/${TID}.spec.md"
echo "Error: something weird happened" > "$ERR_PATH"
cat > "$SPEC_PATH" <<'SPEC'
---
id: t-unknown-001
agent: copilot
task_type: implement_feature
---
Feature.
SPEC

RESULT=$(suggest_spec_fix "$TID" "$ERR_PATH" "$SPEC_PATH")
TYPE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['fix_type'])" "$RESULT")
assert_eq "unknown failure classified" "unknown" "$TYPE"

# ── Test 6: learn_from_fix records to learnings.jsonl ─────────────────────────
learn_from_fix "t-fix-001" "implement_feature" "transient" "true" "test note" >/dev/null
LINE=$(grep '"tid": "t-fix-001"' "$LEARN_DB" 2>/dev/null || echo "")
assert_contains "fix outcome recorded" "fix_outcome" "$LINE"
assert_contains "fix outcome success=true" '"success": true' "$LINE"

# ── Test 7: confidence calibration from past fix outcomes ─────────────────────
# Seed 4 successful transient fixes for implement_feature
for i in 1 2 3 4; do
    learn_from_fix "t-seed-$i" "implement_feature" "transient" "true" "" >/dev/null
done
# Now try a transient — confidence should be high (rule + history both favorable)
TID="t-calibrated-001"
ERR_PATH="$ORCH_DIR/dlq/${TID}.error.log"
SPEC_PATH="$ORCH_DIR/dlq/${TID}.spec.md"
echo "Error: timeout, network unreachable" > "$ERR_PATH"
cat > "$SPEC_PATH" <<'SPEC'
---
id: t-calibrated-001
agent: copilot
task_type: implement_feature
---
Feature.
SPEC

RESULT=$(suggest_spec_fix "$TID" "$ERR_PATH" "$SPEC_PATH")
CONF=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['confidence'])" "$RESULT")
assert_gt "calibrated confidence still > 0.7 after 4 successes" "0.7" "$CONF"

# ── Test 8: confidence calibration drops with failures ────────────────────────
# Reset DB and seed 5 failures of impossible fixes for a new task_type
: > "$LEARN_DB"
for i in 1 2 3 4 5; do
    learn_from_fix "t-failed-$i" "qa_test" "impossible" "false" "" >/dev/null
done
TID="t-drop-001"
ERR_PATH="$ORCH_DIR/dlq/${TID}.error.log"
SPEC_PATH="$ORCH_DIR/dlq/${TID}.spec.md"
echo "Error: cannot complete impossible blocked" > "$ERR_PATH"
cat > "$SPEC_PATH" <<'SPEC'
---
id: t-drop-001
agent: copilot
task_type: qa_test
---
Test.
SPEC

RESULT=$(suggest_spec_fix "$TID" "$ERR_PATH" "$SPEC_PATH")
CONF=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['confidence'])" "$RESULT")
assert_lt "impossible+history failures keeps confidence very low" "0.2" "$CONF"

# ── Test 9: task_type extracted from spec frontmatter ─────────────────────────
TID="t-extract-001"
ERR_PATH="$ORCH_DIR/dlq/${TID}.error.log"
SPEC_PATH="$ORCH_DIR/dlq/${TID}.spec.md"
echo "Error: timeout" > "$ERR_PATH"
cat > "$SPEC_PATH" <<'SPEC'
---
id: t-extract-001
agent: copilot
task_type: code_review
---
Review.
SPEC

RESULT=$(suggest_spec_fix "$TID" "$ERR_PATH" "$SPEC_PATH")
TT=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['task_type'])" "$RESULT")
assert_eq "task_type extracted from frontmatter" "code_review" "$TT"

# ── Test 10: missing dlq error → unknown classification ───────────────────────
TID="t-missing-001"
SPEC_PATH="$ORCH_DIR/dlq/${TID}.spec.md"
cat > "$SPEC_PATH" <<'SPEC'
---
id: t-missing-001
agent: copilot
task_type: implement_feature
---
Feature.
SPEC

RESULT=$(suggest_spec_fix "$TID" "$ORCH_DIR/dlq/nonexistent.error.log" "$SPEC_PATH")
TYPE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['fix_type'])" "$RESULT")
assert_eq "missing error log → unknown" "unknown" "$TYPE"

# ── Test 11: CLI suggest-fix subcommand ───────────────────────────────────────
TID="t-cli-001"
ERR_PATH="$ORCH_DIR/dlq/${TID}.error.log"
SPEC_PATH="$ORCH_DIR/dlq/${TID}.spec.md"
echo "Error: timeout" > "$ERR_PATH"
cat > "$SPEC_PATH" <<'SPEC'
---
id: t-cli-001
agent: copilot
task_type: implement_feature
---
Feature.
SPEC

CLI_OUT=$(bash "$PROJECT_ROOT/lib/learning-engine.sh" suggest-fix "$TID" "$ERR_PATH" "$SPEC_PATH")
assert_contains "CLI suggest-fix returns JSON" '"fix_type"' "$CLI_OUT"

# ── Test 12: CLI learn-fix subcommand ─────────────────────────────────────────
CLI_OUT=$(bash "$PROJECT_ROOT/lib/learning-engine.sh" learn-fix "t-cli-fix-001" "implement_feature" "transient" "true" "via cli")
assert_contains "CLI learn-fix prints confirmation" "Fix outcome recorded" "$CLI_OUT"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "PASS: $PASS  FAIL: $FAIL"
echo "═══════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
