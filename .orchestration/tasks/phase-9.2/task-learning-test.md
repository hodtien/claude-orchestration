---
id: learning-test-001
agent: claude-review
timeout: 300
retries: 1
task_type: write_tests
depends_on: [learning-wire-001]
read_files: [lib/learning-engine.sh, bin/task-dispatch.sh, bin/test-task-decomposer.sh, bin/test-trace-query.sh, bin/test-budget-dashboard.sh, bin/_dashboard/learn.sh, mcp-server/server.mjs]
---

# Task: Learning-engine test suite

## Objective
Two deliverables:
1. `bin/test-learning-engine.sh` — 18+ assertion test suite covering all 6 functions in `lib/learning-engine.sh`, the MCP `get_routing_advice` tool, and the `orch-dashboard.sh learn` subcommand
2. Verify `learn_from_outcome` wire in `bin/task-dispatch.sh` actually appends a record to `LEARN_DB` after a fake task completion

This is Phase 9.2 testing. See `docs/PLAN_phase9.md` for full context.

## Context

Already implemented (by `learning-wire-001`):
- `lib/learning-engine.sh` — bug-fixed (no jq, no bc, correct ORCH_DIR, no mkdir at load)
- Wire in `bin/task-dispatch.sh` — `learn_from_outcome` after both status writers, `analyze_batch` after inbox notification
- `mcp-server/server.mjs` — new `get_routing_advice` tool (12th tool)
- `bin/_dashboard/learn.sh` — new dashboard subcommand

Patterns to follow EXACTLY (already proven in Phase 9.1):
- `bin/test-task-decomposer.sh` — 17-assertion structure with `PASS=0; FAIL=0` counters
- `bin/test-trace-query.sh` (36 tests) — env injection, isolated tmpdir, trap EXIT cleanup
- `bin/test-budget-dashboard.sh` (45 tests) — fixture isolation, env overrides for paths
- Same final summary line: `echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"`

## Deliverable: `bin/test-learning-engine.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

PASS=0; FAIL=0

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  ✅ $label"
    PASS=$((PASS+1))
  else
    echo "  ❌ $label — got: '$actual' expected: '$expected'"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  ✅ $label"
    PASS=$((PASS+1))
  else
    echo "  ❌ $label — '$needle' not found in output"
    FAIL=$((FAIL+1))
  fi
}

assert_not_empty() {
  local label="$1" value="$2"
  if [ -n "$value" ]; then
    echo "  ✅ $label"
    PASS=$((PASS+1))
  else
    echo "  ❌ $label — value was empty"
    FAIL=$((FAIL+1))
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    echo "  ✅ $label"
    PASS=$((PASS+1))
  else
    echo "  ❌ $label — file missing: $path"
    FAIL=$((FAIL+1))
  fi
}

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PROJECT_ROOT/lib/learning-engine.sh"
DASH="$PROJECT_ROOT/bin/orch-dashboard.sh"

# Env inject — isolated tmpdir per test run
export TMPTEST_DIR="$(mktemp -d)"
export ORCH_DIR="$TMPTEST_DIR/.orchestration"
export LEARN_DIR="$ORCH_DIR/learnings"
export LEARN_DB="$LEARN_DIR/learnings.jsonl"
export ROUTING_RULES="$LEARN_DIR/routing-rules.json"
export CONFIG_DIR="$ORCH_DIR/config"

cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT

echo "=== Learning-engine test suite ==="
echo "TMPTEST_DIR=$TMPTEST_DIR"
echo
```

### Test cases (minimum 18 assertions):

**Test 1: Source guard — sourcing has zero side effects**
```bash
ALT_DIR="$TMPTEST_DIR/sourcecheck"
ORCH_DIR="$ALT_DIR/.orchestration" \
LEARN_DIR="$ALT_DIR/.orchestration/learnings" \
LEARN_DB="$ALT_DIR/.orchestration/learnings/learnings.jsonl" \
ROUTING_RULES="$ALT_DIR/.orchestration/learnings/routing-rules.json" \
CONFIG_DIR="$ALT_DIR/.orchestration/config" \
bash -c "source '$LIB'; echo OK" >/dev/null
created_count=$(find "$ALT_DIR" -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "source: no dirs created on load" "$created_count" "0"
```

**Test 2: Source guard — module is idempotent (double-source ok)**
```bash
double_source_exit=0
(source "$LIB" && source "$LIB" && echo "ok") >/dev/null 2>&1 || double_source_exit=$?
assert_eq "source: double-source ok" "$double_source_exit" "0"
```

**Test 3: Env vars are overridable (test isolation)**
```bash
source "$LIB"
assert_eq "env: ORCH_DIR honored" "$ORCH_DIR" "$TMPTEST_DIR/.orchestration"
assert_eq "env: LEARN_DB honored" "$LEARN_DB" "$LEARN_DIR/learnings.jsonl"
```

**Test 4: init_routing_rules — creates rules file**
```bash
rm -rf "$LEARN_DIR"
source "$LIB"
init_routing_rules
assert_file_exists "init: routing-rules.json created" "$ROUTING_RULES"
```

**Test 5: init_routing_rules — file is valid JSON with rules array**
```bash
rules_ok=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('ok' if isinstance(d.get('rules'), list) else 'fail')" "$ROUTING_RULES" 2>/dev/null || echo "fail")
assert_eq "init: rules is JSON array" "$rules_ok" "ok"
```

**Test 6: learn_from_outcome — appends a record to LEARN_DB**
```bash
rm -f "$LEARN_DB"
source "$LIB"
learn_from_outcome "test-batch-1" "true" "oc-medium" "implement_feature" "120" "5000" "" >/dev/null
assert_file_exists "learn: LEARN_DB created" "$LEARN_DB"
line_count=$(wc -l < "$LEARN_DB" | tr -d ' ')
assert_eq "learn: 1 line written" "$line_count" "1"
```

**Test 7: learn_from_outcome — record is valid JSON with required fields**
```bash
rec=$(tail -n1 "$LEARN_DB")
agent=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('agent',''))" "$rec")
batch=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('batch_id',''))" "$rec")
success=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('success',''))" "$rec")
assert_eq "learn: record agent=oc-medium" "$agent" "oc-medium"
assert_eq "learn: record batch_id=test-batch-1" "$batch" "test-batch-1"
assert_contains "learn: success=true" "$success" "True"
```

**Test 8: learn_from_outcome — multiple appends accumulate**
```bash
source "$LIB"
learn_from_outcome "test-batch-1" "true" "claude-review" "code_review" "60" "3000" "" >/dev/null
learn_from_outcome "test-batch-1" "false" "oc-medium" "implement_feature" "300" "8000" "timeout" >/dev/null
total=$(wc -l < "$LEARN_DB" | tr -d ' ')
assert_eq "learn: 3 records total" "$total" "3"
```

**Test 9: learn_from_outcome — failure path does not crash**
```bash
crash_exit=0
(source "$LIB"; learn_from_outcome "" "" "" "" "" "" "" >/dev/null 2>&1) || crash_exit=$?
assert_eq "learn: empty args do not crash" "$crash_exit" "0"
```

**Test 10: get_agent_recommendation — uses default mapping when no rule exists**
```bash
rm -f "$ROUTING_RULES"
source "$LIB"
init_routing_rules
rec=$(get_agent_recommendation "code_review")
assert_not_empty "recommend: returns an agent for code_review" "$rec"
```

**Test 11: get_agent_recommendation — unknown task_type yields fallback**
```bash
source "$LIB"
rec=$(get_agent_recommendation "made_up_task_type_xyz" 2>/dev/null || echo "fallback")
assert_not_empty "recommend: fallback for unknown task_type" "$rec"
```

**Test 12: update_routing_for_success — upserts a rule**
```bash
rm -f "$ROUTING_RULES"
source "$LIB"
init_routing_rules
update_routing_for_success "implement_feature" "oc-medium" "10.5" >/dev/null
rule_count=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(len([r for r in d['rules'] if r.get('task_type')=='implement_feature']))" "$ROUTING_RULES")
assert_eq "update: 1 rule for implement_feature" "$rule_count" "1"
```

**Test 13: update_routing_for_success — cheaper cost replaces existing**
```bash
source "$LIB"
update_routing_for_success "implement_feature" "claude-review" "5.2" >/dev/null
best=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); r=[x for x in d['rules'] if x.get('task_type')=='implement_feature'][0]; print(r.get('best_agent'))" "$ROUTING_RULES")
assert_eq "update: cheaper agent wins" "$best" "claude-review"
```

**Test 14: update_routing_for_success — more expensive does NOT replace**
```bash
source "$LIB"
update_routing_for_success "implement_feature" "expensive-agent" "99.9" >/dev/null
best=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); r=[x for x in d['rules'] if x.get('task_type')=='implement_feature'][0]; print(r.get('best_agent'))" "$ROUTING_RULES")
assert_eq "update: expensive agent does not displace" "$best" "claude-review"
```

**Test 15: analyze_batch — writes batch analysis file**
```bash
source "$LIB"
out_path=$(analyze_batch "test-batch-1")
assert_not_empty "analyze: returns output path" "$out_path"
assert_file_exists "analyze: batch analysis file exists" "$out_path"
```

**Test 16: analyze_batch — analysis JSON has aggregate stats**
```bash
source "$LIB"
out_path=$(analyze_batch "test-batch-1")
total=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('total_tasks',0))" "$out_path")
# We appended 3 records for test-batch-1 in Test 6 + Test 8
assert_eq "analyze: total_tasks=3" "$total" "3"
```

**Test 17: analyze_batch — filters by batch_id (other batch yields 0)**
```bash
source "$LIB"
out_path=$(analyze_batch "nonexistent-batch")
total=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('total_tasks',0))" "$out_path" 2>/dev/null || echo "0")
assert_eq "analyze: unknown batch has 0 tasks" "$total" "0"
```

**Test 18: get_routing_advice — outputs non-empty advice for known task_type**
```bash
source "$LIB"
advice=$(get_routing_advice "implement_feature" 2>/dev/null || echo "")
assert_not_empty "advice: non-empty for implement_feature" "$advice"
```

**Test 19: get_routing_advice — empty task_type does not crash**
```bash
crash_exit=0
(source "$LIB"; get_routing_advice "" >/dev/null 2>&1) || crash_exit=$?
case "$crash_exit" in
  0|1) result="ok" ;;
  *)   result="fail" ;;
esac
assert_eq "advice: empty arg handled gracefully" "$result" "ok"
```

**Test 20: dashboard learn — runs without crash and reports record count**
```bash
out=$(bash "$DASH" learn 2>&1 || echo "DASH_FAIL")
assert_contains "dashboard: human output mentions records" "$out" "records"
```

**Test 21: dashboard learn --json — outputs valid JSON**
```bash
out_json=$(bash "$DASH" learn --json 2>/dev/null || echo "{}")
records=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('records',-1))" "$out_json" 2>/dev/null || echo "-1")
# We have 3 learning records from Test 8
assert_eq "dashboard --json: records=3" "$records" "3"
```

**Test 22: dashboard learn --task-type filter — narrows results**
```bash
out_json=$(bash "$DASH" learn --json --task-type code_review 2>/dev/null || echo "{}")
records=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('records',-1))" "$out_json" 2>/dev/null || echo "-1")
# Only 1 record had task_type=code_review (from Test 8)
assert_eq "dashboard --task-type: filters to code_review" "$records" "1"
```

**Test 23: MCP delegation — get_routing_advice helper invoked via PROJECT_ROOT spawn**
```bash
# Verify the lib responds to a parameterized call the same way the MCP helper does:
#   bash -c 'source LIB && get_routing_advice "$1"' -- task_type
delegated=$(bash -c "source '$LIB' && get_routing_advice \"\$1\"" -- "implement_feature" 2>/dev/null || echo "")
assert_not_empty "mcp delegation: spawned bash returns advice" "$delegated"
```

**Test 24: Standalone dispatch helper — `bash lib/learning-engine.sh recommend <task_type>` does not crash**
```bash
recommend_exit=0
bash "$LIB" recommend implement_feature >/dev/null 2>&1 || recommend_exit=$?
assert_eq "standalone: bash LIB recommend exits 0 or 1" "$([ "$recommend_exit" -le 1 ] && echo ok || echo fail)" "ok"
```

**Test 25: No `jq` invocation in learning-engine.sh**
```bash
jq_count=$(grep -c '\bjq\b' "$LIB" 2>/dev/null || echo "0")
assert_eq "no jq: 0 invocations in learning-engine.sh" "$jq_count" "0"
```

**Test 26: No `bc` invocation in learning-engine.sh**
```bash
bc_count=$(grep -cE '\bbc(\b|[[:space:]])' "$LIB" 2>/dev/null || echo "0")
assert_eq "no bc: 0 invocations in learning-engine.sh" "$bc_count" "0"
```

**Test 27: ORCH_DIR default points at project, not $HOME/.claude/orchestration**
```bash
unset ORCH_DIR LEARN_DIR LEARN_DB ROUTING_RULES CONFIG_DIR
default_orch=$(bash -c "source '$LIB'; echo \$ORCH_DIR")
case "$default_orch" in
  *"/.orchestration"*) result="ok" ;;
  *) result="fail (got: $default_orch)" ;;
esac
assert_eq "default: ORCH_DIR ends in /.orchestration" "$result" "ok"
# Restore env for subsequent tests
export ORCH_DIR="$TMPTEST_DIR/.orchestration"
export LEARN_DIR="$ORCH_DIR/learnings"
export LEARN_DB="$LEARN_DIR/learnings.jsonl"
export ROUTING_RULES="$LEARN_DIR/routing-rules.json"
export CONFIG_DIR="$ORCH_DIR/config"
```

**Test 28: dispatch wire — task-dispatch.sh sources learning-engine.sh without error**
```bash
src_check=$(grep -c 'learning-engine.sh' "$PROJECT_ROOT/bin/task-dispatch.sh" 2>/dev/null || echo "0")
assert_eq "wire: task-dispatch.sh references learning-engine.sh" \
  "$([ "$src_check" -ge 1 ] && echo ok || echo fail)" "ok"
```

**Test 29: dispatch wire — analyze_batch hook present before notify_event**
```bash
analyze_line=$(grep -n 'analyze_batch' "$PROJECT_ROOT/bin/task-dispatch.sh" | head -1 | cut -d: -f1)
notify_line=$(grep -n 'notify_event "batch_complete"' "$PROJECT_ROOT/bin/task-dispatch.sh" | head -1 | cut -d: -f1)
if [ -n "$analyze_line" ] && [ -n "$notify_line" ] && [ "$analyze_line" -lt "$notify_line" ]; then
  result="ok"
else
  result="fail (analyze=$analyze_line notify=$notify_line)"
fi
assert_eq "wire: analyze_batch precedes notify_event" "$result" "ok"
```

**Test 30: MCP server registers get_routing_advice tool**
```bash
mcp_tool=$(grep -c 'get_routing_advice' "$PROJECT_ROOT/mcp-server/server.mjs" 2>/dev/null || echo "0")
assert_eq "mcp: get_routing_advice referenced ≥3x" \
  "$([ "$mcp_tool" -ge 3 ] && echo ok || echo fail)" "ok"
```

### Final block:
```bash
echo
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

## Constraints
- Tests must be standalone: `bash bin/test-learning-engine.sh` → all pass
- Use `export ORCH_DIR/LEARN_DIR/LEARN_DB/ROUTING_RULES/CONFIG_DIR` to fully isolate from real `.orchestration/`
- Clean up tmpdir on exit (trap EXIT) — no leftover state
- No network calls, no real agent dispatch, no real MCP server boot — only direct lib invocation + bash subprocesses
- Tests must pass on bash 3.2 (macOS) and bash 5+ (Linux)
- Python3 stdlib only for JSON parsing — NO jq, NO yq, NO pip packages
- Tests 6→8→16/17/21/22 chain by design — all rely on records appended in earlier tests within the same TMPTEST_DIR
- 0 test assertions should require a real LLM call
- Make the script executable: `chmod +x bin/test-learning-engine.sh`

## Verification
```bash
# Run from project root
bash bin/test-learning-engine.sh

# Expected output last line:
# ALL 30 TESTS: 30 PASS, 0 FAIL
```
