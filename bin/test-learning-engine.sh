#!/usr/bin/env bash
# test-learning-engine.sh — 30 assertions for lib/learning-engine.sh,
# orch-dashboard.sh learn, and MCP get_routing_advice
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────────────────────────

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

assert_not_empty() {
    local label="$1" value="$2"
    if [ -n "$value" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label — value was empty"
        FAIL=$((FAIL+1))
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label — file not found: $path"
        FAIL=$((FAIL+1))
    fi
}

# ── Test isolation ────────────────────────────────────────────────────────────

TMPTEST_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT

export ORCH_DIR="$TMPTEST_DIR/.orchestration"
export LEARN_DIR="$ORCH_DIR/learnings"
export LEARN_DB="$LEARN_DIR/learnings.jsonl"
export ROUTING_RULES="$LEARN_DIR/routing-rules.json"
export CONFIG_DIR="$ORCH_DIR/config"

# Source the library
# shellcheck source=../lib/learning-engine.sh
. "$PROJECT_ROOT/lib/learning-engine.sh"

# ── 1. Double-source guard ────────────────────────────────────────────────────

T1_BEFORE="${_LEARNING_ENGINE_LOADED:-}"
. "$PROJECT_ROOT/lib/learning-engine.sh"
T1_AFTER="${_LEARNING_ENGINE_LOADED:-}"
assert_eq "T01 double-source guard: _LEARNING_ENGINE_LOADED set" "1" "$T1_BEFORE"
assert_eq "T02 double-source guard: second source is no-op" "$T1_BEFORE" "$T1_AFTER"

# ── 2. No dirs created at source time ────────────────────────────────────────

assert_eq "T03 LEARN_DIR not created at source time" "" "$([ -d "$LEARN_DIR" ] && echo exists || echo '')"

# ── 3. init_routing_rules ────────────────────────────────────────────────────

init_routing_rules
assert_file_exists "T04 init_routing_rules creates routing-rules.json" "$ROUTING_RULES"

RULES_CONTENT="$(cat "$ROUTING_RULES")"
assert_contains "T05 routing-rules.json has rules key" '"rules"' "$RULES_CONTENT"
assert_contains "T06 routing-rules.json has version key" '"version"' "$RULES_CONTENT"

# Idempotent: calling twice should not corrupt file
init_routing_rules
RULES_CONTENT2="$(cat "$ROUTING_RULES")"
assert_contains "T07 init_routing_rules idempotent" '"rules"' "$RULES_CONTENT2"

# ── 4. learn_from_outcome — success ──────────────────────────────────────────

OUT="$(learn_from_outcome "batch-001" "true" "gemini" "code_review" "120" "5000" "great job")"
assert_contains "T08 learn_from_outcome success prints category" "success_patterns" "$OUT"
assert_file_exists "T09 learn_from_outcome creates learnings.jsonl" "$LEARN_DB"

RECORD="$(tail -1 "$LEARN_DB")"
assert_contains "T10 record has batch_id" '"batch-001"' "$RECORD"
assert_contains "T11 record has agent" '"gemini"' "$RECORD"
assert_contains "T12 record has task_type" '"code_review"' "$RECORD"
assert_contains "T13 record success=true" '"success": true' "$RECORD"

# ── 5. learn_from_outcome — failure ──────────────────────────────────────────

learn_from_outcome "batch-001" "false" "copilot" "implement_feature" "60" "2000" "timeout" >/dev/null
FAIL_RECORD="$(tail -1 "$LEARN_DB")"
assert_contains "T14 failure record has correct agent" '"copilot"' "$FAIL_RECORD"
assert_contains "T15 failure record success=false" '"success": false' "$FAIL_RECORD"

# ── 6. update_routing_for_success ────────────────────────────────────────────

update_routing_for_success "architecture" "gemini" "8000" "200"
RULES_AFTER="$(cat "$ROUTING_RULES")"
assert_contains "T16 routing rule added for architecture" '"architecture"' "$RULES_AFTER"
assert_contains "T17 routing rule best_agent is gemini" '"gemini"' "$RULES_AFTER"

# Second call with worse cost_per_min should not displace first
update_routing_for_success "architecture" "copilot" "99999" "1"
RULES_AFTER2="$(cat "$ROUTING_RULES")"
assert_contains "T18 cheaper agent retained after second call" '"gemini"' "$RULES_AFTER2"

# ── 7. get_agent_recommendation ──────────────────────────────────────────────

REC="$(get_agent_recommendation "architecture")"
assert_eq "T19 get_agent_recommendation returns gemini for architecture" "gemini" "$REC"

# Unknown type falls back to 'auto'
REC_UNKNOWN="$(get_agent_recommendation "totally_unknown_type")"
assert_eq "T20 get_agent_recommendation returns auto for unknown type" "auto" "$REC_UNKNOWN"

# ── 8. analyze_batch ─────────────────────────────────────────────────────────

# Add more records for batch-002
learn_from_outcome "batch-002" "true"  "gemini"  "security"          "90"  "4000" "" >/dev/null
learn_from_outcome "batch-002" "true"  "copilot" "implement_feature"  "75"  "3500" "" >/dev/null
learn_from_outcome "batch-002" "false" "copilot" "implement_feature"  "120" "5000" "" >/dev/null

ANALYSIS_FILE="$(analyze_batch "batch-002")"
assert_file_exists "T21 analyze_batch writes analysis file" "$ANALYSIS_FILE"

ANALYSIS="$(cat "$ANALYSIS_FILE")"
assert_contains "T22 analysis has batch_id" '"batch-002"' "$ANALYSIS"
assert_contains "T23 analysis has total_tasks" '"total_tasks"' "$ANALYSIS"
assert_contains "T24 analysis has success_count" '"success_count"' "$ANALYSIS"

SUCCESS_COUNT="$(python3 -c "import json,sys; d=json.load(open('$ANALYSIS_FILE')); print(d['summary']['success_count'])" 2>/dev/null || echo -1)"
assert_eq "T25 analysis success_count=2" "2" "$SUCCESS_COUNT"

# ── 9. get_routing_advice ─────────────────────────────────────────────────────

ADVICE="$(get_routing_advice "architecture")"
assert_not_empty "T26 get_routing_advice returns non-empty string" "$ADVICE"
assert_contains "T27 get_routing_advice mentions recommended agent" "gemini" "$ADVICE"

# ── 10. orch-dashboard.sh learn (human output) ────────────────────────────────

DASH_OUT="$(LEARN_DB="$LEARN_DB" ROUTING_RULES="$ROUTING_RULES"
    bash "$PROJECT_ROOT/bin/orch-dashboard.sh" learn 2>&1)"
assert_contains "T28 dashboard learn shows Learning records" "Learning records:" "$DASH_OUT"

# ── 11. orch-dashboard.sh learn --json ───────────────────────────────────────

JSON_OUT="$(LEARN_DB="$LEARN_DB" ROUTING_RULES="$ROUTING_RULES"
    bash "$PROJECT_ROOT/bin/orch-dashboard.sh" learn --json 2>&1)"
assert_contains "T29 dashboard learn --json has records key" '"records"' "$JSON_OUT"
assert_contains "T30 dashboard learn --json has routing_rules key" '"routing_rules"' "$JSON_OUT"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
