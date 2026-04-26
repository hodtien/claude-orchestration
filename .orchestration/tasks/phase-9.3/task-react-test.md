---
id: react-test-001
agent: claude-review
timeout: 400
retries: 1
task_type: write_tests
depends_on: [react-core-001]
read_files: [lib/react-loop.sh, lib/quality-gate.sh, bin/task-dispatch.sh, bin/test-learning-engine.sh, bin/test-task-decomposer.sh, bin/test-trace-query.sh, bin/orch-dashboard.sh, mcp-server/server.mjs]
---

# Task: Phase 9.3 ReAct test suite

## Objective
Create a standalone test suite for Phase 9.3 ReAct adaptive dispatch.

Deliverables:
1. `bin/test-react-loop.sh` — 18+ assertion test suite covering `lib/react-loop.sh`, dashboard `react`, MCP helper registration, and dispatch wire points
2. Verify source-time side effects are zero
3. Verify ReAct trace JSONL is written and aggregated correctly
4. Verify dispatcher wiring is present but default behavior remains off

This task depends on `react-core-001`.

## Patterns to follow

Follow the style of `bin/test-learning-engine.sh` exactly:
- `#!/usr/bin/env bash`
- `set -euo pipefail`
- `PASS=0; FAIL=0`
- assertion helpers: `assert_eq`, `assert_contains`, `assert_not_empty`, `assert_file_exists`
- isolated `TMPTEST_DIR` with trap cleanup
- final line: `ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL`
- executable bit set: `chmod +x bin/test-react-loop.sh`

No real agent dispatch. No network calls. No MCP server boot. Only direct lib calls, static grep checks, dashboard invocation, and `node --check`.

## Required test setup

Use this skeleton:

```bash
#!/usr/bin/env bash
set -euo pipefail

PASS=0; FAIL=0

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label — got: '$actual' expected: '$expected'"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label — '$needle' not found"
    FAIL=$((FAIL+1))
  fi
}

assert_not_empty() {
  local label="$1" value="$2"
  if [ -n "$value" ]; then
    echo "  PASS $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label — value was empty"
    FAIL=$((FAIL+1))
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    echo "  PASS $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label — file missing: $path"
    FAIL=$((FAIL+1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PROJECT_ROOT/lib/react-loop.sh"
DASH="$PROJECT_ROOT/bin/orch-dashboard.sh"
DISPATCH="$PROJECT_ROOT/bin/task-dispatch.sh"
SERVER="$PROJECT_ROOT/mcp-server/server.mjs"

TMPTEST_DIR="$(mktemp -d)"
export PROJECT_ROOT
export ORCH_DIR="$TMPTEST_DIR/.orchestration"
export RESULTS_DIR="$ORCH_DIR/results"
export REACT_DIR="$ORCH_DIR/react"
export REACT_TRACE_DIR="$ORCH_DIR/react-traces"
export REACT_MAX_TURNS="3"
export REACT_QUALITY_THRESHOLD="0.7"
mkdir -p "$RESULTS_DIR"

cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT
```

Avoid emoji in test output. Keep it readable in plain terminals.

## Test cases

### Test 1: source guard has zero side effects
```bash
ALT_DIR="$TMPTEST_DIR/sourcecheck"
ORCH_DIR="$ALT_DIR/.orchestration" \
RESULTS_DIR="$ALT_DIR/.orchestration/results" \
REACT_DIR="$ALT_DIR/.orchestration/react" \
REACT_TRACE_DIR="$ALT_DIR/.orchestration/react-traces" \
bash -c "source '$LIB'; echo OK" >/dev/null
created_count=$(find "$ALT_DIR" -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "source: no dirs created on load" "$created_count" "0"
```

### Test 2: double source ok
```bash
double_source_exit=0
(source "$LIB" && source "$LIB" && echo ok) >/dev/null 2>&1 || double_source_exit=$?
assert_eq "source: double-source ok" "$double_source_exit" "0"
```

### Test 3: env vars honored
```bash
source "$LIB"
assert_eq "env: REACT_TRACE_DIR honored" "$REACT_TRACE_DIR" "$ORCH_DIR/react-traces"
```

### Test 4: missing trace returns valid empty JSON
```bash
trace=$(react_get_trace "missing-task")
turns=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('turns'))" "$trace")
assert_eq "trace: missing task has 0 turns" "$turns" "0"
```

### Test 5: observe empty output scores low
```bash
: > "$RESULTS_DIR/empty.out"
: > "$RESULTS_DIR/empty.log"
obs=$(react_observe "react-empty" "oc-medium" "$RESULTS_DIR/empty.out" "$RESULTS_DIR/empty.log")
has_output=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('has_output'))" "$obs")
assert_contains "observe: empty output is false" "$has_output" "False"
```

### Test 6: observe good output scores above threshold
```bash
python3 - <<'PY' > "$RESULTS_DIR/good.out"
print('This is a complete implementation report with concrete files, verification steps, and acceptance criteria. ' * 8)
PY
: > "$RESULTS_DIR/good.log"
obs=$(react_observe "react-good" "oc-medium" "$RESULTS_DIR/good.out" "$RESULTS_DIR/good.log")
score_ok=$(python3 -c "import json,sys; print('ok' if json.loads(sys.argv[1]).get('quality_score',0) >= 0.7 else 'fail')" "$obs")
assert_eq "observe: good output score >= 0.7" "$score_ok" "ok"
```

### Test 7: observe placeholder detects placeholder
```bash
printf 'TODO\n' > "$RESULTS_DIR/todo.out"
: > "$RESULTS_DIR/todo.log"
obs=$(react_observe "react-todo" "oc-medium" "$RESULTS_DIR/todo.out" "$RESULTS_DIR/todo.log")
placeholder=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('placeholder'))" "$obs")
assert_contains "observe: placeholder true" "$placeholder" "True"
```

### Test 8: think accepts high score
```bash
obs_good=$(react_observe "react-good" "oc-medium" "$RESULTS_DIR/good.out" "$RESULTS_DIR/good.log")
decision=$(react_think "$obs_good" "0.7")
action=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('decision'))" "$decision")
assert_eq "think: high score accepts" "$action" "accept"
```

### Test 9: think retries no output
```bash
obs_empty=$(react_observe "react-empty" "oc-medium" "$RESULTS_DIR/empty.out" "$RESULTS_DIR/empty.log")
decision=$(react_think "$obs_empty" "0.7")
action=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('decision'))" "$decision")
assert_eq "think: no output retries" "$action" "retry"
```

### Test 10: think redirects weak non-placeholder output
```bash
printf 'short but real output\n' > "$RESULTS_DIR/weak.out"
: > "$RESULTS_DIR/weak.log"
obs_weak=$(react_observe "react-weak" "oc-medium" "$RESULTS_DIR/weak.out" "$RESULTS_DIR/weak.log")
decision=$(react_think "$obs_weak" "0.95")
action=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('decision'))" "$decision")
assert_eq "think: weak real output redirects" "$action" "redirect"
```

### Test 11: record trace writes JSONL
```bash
react_record_trace "react-good" "1" "oc-medium" "$obs_good" "$decision" >/dev/null
assert_file_exists "trace: jsonl created" "$REACT_TRACE_DIR/react-good.react.jsonl"
```

### Test 12: get trace aggregates turns
```bash
trace=$(react_get_trace "react-good")
turns=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('turns'))" "$trace")
assert_eq "trace: one turn aggregated" "$turns" "1"
```

### Test 13: select next agent for redirect
```bash
redirect_json='{"decision":"redirect"}'
next_agent=$(react_select_next_agent "oc-medium" "oc-medium claude-review cc/claude-sonnet-4-6" "$redirect_json")
assert_eq "select: redirect picks next distinct agent" "$next_agent" "claude-review"
```

### Test 14: select current agent for retry
```bash
retry_json='{"decision":"retry"}'
next_agent=$(react_select_next_agent "oc-medium" "oc-medium claude-review" "$retry_json")
assert_eq "select: retry keeps current agent" "$next_agent" "oc-medium"
```

### Test 15: standalone trace command works
```bash
standalone=$(bash "$LIB" trace "react-good")
assert_contains "standalone: trace returns task id" "$standalone" "react-good"
```

### Test 16: dashboard react --json works
```bash
out_json=$(bash "$DASH" react --json 2>/dev/null || echo '{}')
valid=$(python3 -c "import json,sys; json.loads(sys.argv[1]); print('ok')" "$out_json" 2>/dev/null || echo fail)
assert_eq "dashboard: react --json valid" "$valid" "ok"
```

### Test 17: dashboard --task-id filters
```bash
out_json=$(bash "$DASH" react --json --task-id react-good 2>/dev/null || echo '{}')
contains=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('ok' if 'react-good' in str(d) else 'fail')" "$out_json" 2>/dev/null || echo fail)
assert_eq "dashboard: task-id filter includes react-good" "$contains" "ok"
```

### Test 18: dispatch sources react-loop
```bash
src_count=$(grep -c 'react-loop.sh' "$DISPATCH" 2>/dev/null || echo 0)
assert_eq "wire: dispatch sources react-loop" "$([ "$src_count" -ge 1 ] && echo ok || echo fail)" "ok"
```

### Test 19: dispatch references react_enabled_for_task
```bash
wire_count=$(grep -c 'react_enabled_for_task' "$DISPATCH" 2>/dev/null || echo 0)
assert_eq "wire: dispatch checks react_enabled_for_task" "$([ "$wire_count" -ge 1 ] && echo ok || echo fail)" "ok"
```

### Test 20: config has react_policy
```bash
policy_count=$(grep -c 'react_policy:' "$PROJECT_ROOT/config/models.yaml" 2>/dev/null || echo 0)
assert_eq "config: react_policy present" "$([ "$policy_count" -ge 1 ] && echo ok || echo fail)" "ok"
```

### Test 21: MCP registers get_react_trace
```bash
mcp_count=$(grep -c 'get_react_trace' "$SERVER" 2>/dev/null || echo 0)
assert_eq "mcp: get_react_trace referenced >=3x" "$([ "$mcp_count" -ge 3 ] && echo ok || echo fail)" "ok"
```

### Test 22: MCP server syntax valid
```bash
node_exit=0
node --check "$SERVER" >/dev/null 2>&1 || node_exit=$?
assert_eq "mcp: node syntax valid" "$node_exit" "0"
```

### Test 23: no jq in react-loop
```bash
jq_count=$(grep -c '\bjq\b' "$LIB" 2>/dev/null || echo 0)
assert_eq "deps: no jq" "$jq_count" "0"
```

### Test 24: no bc in react-loop
```bash
bc_count=$(grep -cE '\bbc(\b|[[:space:]])' "$LIB" 2>/dev/null || echo 0)
assert_eq "deps: no bc" "$bc_count" "0"
```

### Test 25: default disabled for simple task spec
```bash
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
assert_eq "enabled: simple task disabled by default" "$enabled" "false"
```

### Test 26: frontmatter react_mode true enables
```bash
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
assert_eq "enabled: frontmatter true enables" "$enabled" "true"
```

### Test 27: frontmatter react_mode false overrides heuristic
```bash
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
assert_eq "enabled: frontmatter false disables" "$enabled" "false"
```

## Final block

```bash
echo
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

## Verification commands

Run from project root:
```bash
bash bin/test-react-loop.sh
bash bin/test-learning-engine.sh
node --check mcp-server/server.mjs
```

Expected final line:
```text
ALL 27 TESTS: 27 PASS, 0 FAIL
```

If implementation naturally adds more assertions, update the expected count.

## Acceptance criteria

- `bash bin/test-react-loop.sh` passes all assertions
- Test suite uses only isolated temp state
- No real agent calls
- No network calls
- No jq/bc dependencies
- Dashboard and MCP registration are covered
- Dispatcher wire points are covered
