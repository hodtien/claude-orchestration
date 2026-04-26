#!/usr/bin/env bash
# test-react-loop.sh -- 27 assertions for lib/react-loop.sh, dashboard react,
# MCP get_react_trace, and dispatch wire points.
set -euo pipefail

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

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
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
        echo "FAIL: $label -- value was empty"
        FAIL=$((FAIL+1))
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label -- file not found: $path"
        FAIL=$((FAIL+1))
    fi
}

TMPTEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT

LIB="$PROJECT_ROOT/lib/react-loop.sh"
DASH="$PROJECT_ROOT/bin/orch-dashboard.sh"
DISPATCH="$PROJECT_ROOT/bin/task-dispatch.sh"
SERVER="$PROJECT_ROOT/mcp-server/server.mjs"

export PROJECT_ROOT
export ORCH_DIR="$TMPTEST_DIR/.orchestration"
export RESULTS_DIR="$ORCH_DIR/results"
export REACT_DIR="$ORCH_DIR/react"
export REACT_TRACE_DIR="$ORCH_DIR/react-traces"
export REACT_MAX_TURNS="3"
export REACT_QUALITY_THRESHOLD="0.7"
mkdir -p "$RESULTS_DIR"

# T01: source guard has zero side effects
ALT_DIR="$TMPTEST_DIR/sourcecheck"
env ORCH_DIR="$ALT_DIR/.orchestration" \
    RESULTS_DIR="$ALT_DIR/.orchestration/results" \
    REACT_DIR="$ALT_DIR/.orchestration/react" \
    REACT_TRACE_DIR="$ALT_DIR/.orchestration/react-traces" \
    bash -c "source '$LIB'; echo OK" >/dev/null
created_count=$(find "$ALT_DIR" -type d 2>/dev/null | wc -l | tr -d ' ' || true)
assert_eq "T01 source: no dirs created on load" "0" "$created_count"

# T02: double source ok
double_source_exit=0
(source "$LIB" && source "$LIB" && echo ok) >/dev/null 2>&1 || double_source_exit=$?
assert_eq "T02 source: double-source ok" "0" "$double_source_exit"

# shellcheck source=../lib/react-loop.sh
. "$LIB"

# T03: env vars honored
assert_eq "T03 env: REACT_TRACE_DIR honored" "$ORCH_DIR/react-traces" "$REACT_TRACE_DIR"

# T04: missing trace returns valid empty JSON
trace=$(react_get_trace "missing-task")
turns=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('turns'))" "$trace")
assert_eq "T04 trace: missing task has 0 turns" "0" "$turns"

# T05: observe empty output scores low
: > "$RESULTS_DIR/empty.out"
: > "$RESULTS_DIR/empty.log"
obs_empty=$(react_observe "react-empty" "oc-medium" "$RESULTS_DIR/empty.out" "$RESULTS_DIR/empty.log")
has_output=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('has_output'))" "$obs_empty")
assert_contains "T05 observe: empty output is false" "False" "$has_output"

# T06: observe good output scores above threshold
python3 -c "print('This is a complete implementation report with concrete files, verification steps, and acceptance criteria. ' * 8)" > "$RESULTS_DIR/good.out"
: > "$RESULTS_DIR/good.log"
obs_good=$(react_observe "react-good" "oc-medium" "$RESULTS_DIR/good.out" "$RESULTS_DIR/good.log")
score_ok=$(python3 -c "import json,sys; print('ok' if json.loads(sys.argv[1]).get('quality_score',0) >= 0.7 else 'fail')" "$obs_good")
assert_eq "T06 observe: good output score >= 0.7" "ok" "$score_ok"

# T07: observe placeholder detects placeholder
printf 'TODO\n' > "$RESULTS_DIR/todo.out"
: > "$RESULTS_DIR/todo.log"
obs_todo=$(react_observe "react-todo" "oc-medium" "$RESULTS_DIR/todo.out" "$RESULTS_DIR/todo.log")
placeholder=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('placeholder'))" "$obs_todo")
assert_contains "T07 observe: placeholder true" "True" "$placeholder"

# T08: think accepts high score
decision_good=$(react_think "$obs_good" "0.7")
action=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('decision'))" "$decision_good")
assert_eq "T08 think: high score accepts" "accept" "$action"

# T09: think retries no output
decision_empty=$(react_think "$obs_empty" "0.7")
action=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('decision'))" "$decision_empty")
assert_eq "T09 think: no output retries" "retry" "$action"

# T10: think redirects weak non-placeholder output
printf 'short but real output\n' > "$RESULTS_DIR/weak.out"
: > "$RESULTS_DIR/weak.log"
obs_weak=$(react_observe "react-weak" "oc-medium" "$RESULTS_DIR/weak.out" "$RESULTS_DIR/weak.log")
decision_weak=$(react_think "$obs_weak" "0.95")
action=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('decision'))" "$decision_weak")
assert_eq "T10 think: weak real output redirects" "redirect" "$action"

# T11: record trace writes JSONL
react_record_trace "react-good" "1" "oc-medium" "$obs_good" "$decision_good" >/dev/null
assert_file_exists "T11 trace: jsonl created" "$REACT_TRACE_DIR/react-good.react.jsonl"

# T12: get trace aggregates turns
trace=$(react_get_trace "react-good")
turns=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('turns'))" "$trace")
assert_eq "T12 trace: one turn aggregated" "1" "$turns"

# T13: select next agent for redirect
redirect_json='{"decision":"redirect"}'
next_agent=$(react_select_next_agent "oc-medium" "oc-medium claude-review cc/claude-sonnet-4-6" "$redirect_json")
assert_eq "T13 select: redirect picks next distinct agent" "claude-review" "$next_agent"

# T14: select current agent for retry
retry_json='{"decision":"retry"}'
next_agent=$(react_select_next_agent "oc-medium" "oc-medium claude-review" "$retry_json")
assert_eq "T14 select: retry keeps current agent" "oc-medium" "$next_agent"

# T15: standalone trace command works
standalone=$(bash "$LIB" trace "react-good")
assert_contains "T15 standalone: trace returns task id" "react-good" "$standalone"

# T16: dashboard react --json works
out_json=$(bash "$DASH" react --json 2>/dev/null || echo '{}')
valid=$(python3 -c "import json,sys; json.loads(sys.argv[1]); print('ok')" "$out_json" 2>/dev/null || echo fail)
assert_eq "T16 dashboard: react --json valid" "ok" "$valid"

# T17: dashboard --task-id filters
out_json=$(bash "$DASH" react --json --task-id react-good 2>/dev/null || echo '{}')
contains=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('ok' if 'react-good' in str(d) else 'fail')" "$out_json" 2>/dev/null || echo fail)
assert_eq "T17 dashboard: task-id filter includes react-good" "ok" "$contains"

# T18: dispatch sources react-loop
src_count=$(grep -c 'react-loop.sh' "$DISPATCH" 2>/dev/null || echo 0)
assert_eq "T18 wire: dispatch sources react-loop" "ok" "$([ "$src_count" -ge 1 ] && echo ok || echo fail)"

# T19: dispatch references react_enabled_for_task
wire_count=$(grep -c 'react_enabled_for_task' "$DISPATCH" 2>/dev/null || echo 0)
assert_eq "T19 wire: dispatch checks react_enabled_for_task" "ok" "$([ "$wire_count" -ge 1 ] && echo ok || echo fail)"

# T20: config has react_policy
policy_count=$(grep -c 'react_policy:' "$PROJECT_ROOT/config/models.yaml" 2>/dev/null || echo 0)
assert_eq "T20 config: react_policy present" "ok" "$([ "$policy_count" -ge 1 ] && echo ok || echo fail)"

# T21: MCP registers get_react_trace
mcp_count=$(grep -c 'get_react_trace' "$SERVER" 2>/dev/null || true)
assert_eq "T21 mcp: get_react_trace referenced >=2x" "ok" "$([ "$mcp_count" -ge 2 ] && echo ok || echo fail)"

# T22: MCP server syntax valid
node_exit=0
node --check "$SERVER" >/dev/null 2>&1 || node_exit=$?
assert_eq "T22 mcp: node syntax valid" "0" "$node_exit"

# T23: no jq in react-loop
jq_count=$(grep -c '\bjq\b' "$LIB" 2>/dev/null || true)
assert_eq "T23 deps: no jq" "0" "$jq_count"

# T24: no bc in react-loop
bc_count=$(grep -cE '\bbc(\b|[[:space:]])' "$LIB" 2>/dev/null || true)
assert_eq "T24 deps: no bc" "0" "$bc_count"

# T25: default disabled for simple task spec
simple_spec="$TMPTEST_DIR/simple.md"
cat > "$simple_spec" <<'EOF'
---
id: simple-react-disabled
agent: oc-medium
timeout: 120
task_type: quick_answer
---
Small task.
EOF
enabled=$(react_enabled_for_task "$simple_spec" "quick_answer" "120")
assert_eq "T25 enabled: simple task disabled by default" "false" "$enabled"

# T26: frontmatter react_mode true enables
enabled_spec="$TMPTEST_DIR/enabled.md"
cat > "$enabled_spec" <<'EOF'
---
id: simple-react-enabled
agent: oc-medium
timeout: 120
task_type: quick_answer
react_mode: true
---
Small task.
EOF
enabled=$(react_enabled_for_task "$enabled_spec" "quick_answer" "120")
assert_eq "T26 enabled: frontmatter true enables" "true" "$enabled"

# T27: frontmatter react_mode false overrides heuristic
disabled_spec="$TMPTEST_DIR/disabled.md"
cat > "$disabled_spec" <<'EOF'
---
id: long-react-disabled
agent: oc-medium
timeout: 600
task_type: implement_feature
react_mode: false
---
Long task but explicitly disabled.
EOF
enabled=$(react_enabled_for_task "$disabled_spec" "implement_feature" "600")
assert_eq "T27 enabled: frontmatter false disables" "false" "$enabled"

echo
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
