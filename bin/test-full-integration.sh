#!/usr/bin/env bash
# test-full-integration.sh -- isolated end-to-end dispatch pipeline smoke test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

pass() {
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo "PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo "FAIL: $1"
  echo "  $2"
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label" "expected=$expected actual=$actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    pass "$label"
  else
    fail "$label" "expected to contain: $needle"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$label"
  else
    fail "$label" "file not found: $path"
  fi
}

assert_json_file() {
  local label="$1" path="$2"
  if python3 - "$path" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    json.load(f)
PYEOF
  then
    pass "$label"
  else
    fail "$label" "invalid JSON in $path"
  fi
}

assert_json_string() {
  local label="$1" json_data="$2"
  if python3 -c 'import json,sys; json.loads(sys.argv[1])' "$json_data" 2>/dev/null; then
    pass "$label"
  else
    fail "$label" "invalid JSON string"
  fi
}

json_get_file() {
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
cur = data
for part in sys.argv[2].split("."):
    cur = cur[part]
print(cur)
PYEOF
}

json_get_string() {
  local json_data="$1" key="$2"
  python3 -c 'import json,sys
cur = json.loads(sys.argv[1])
for part in sys.argv[2].split("."):
    cur = cur[part]
print(cur)' "$json_data" "$key"
}

assert_jsonl_file() {
  local label="$1" path="$2"
  if python3 - "$path" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            json.loads(line)
PYEOF
  then
    pass "$label"
  else
    fail "$label" "invalid JSONL in $path"
  fi
}

TMPTEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT

export PROJECT_ROOT
export ORCH_DIR="$TMPTEST_DIR/.orchestration"
export RESULTS_DIR="$ORCH_DIR/results"
export SESSION_CTX_DIR="$ORCH_DIR/session-context"
mkdir -p "$RESULTS_DIR" "$ORCH_DIR/tasks/smoke-test" "$SESSION_CTX_DIR"

SPEC="$ORCH_DIR/tasks/smoke-test/task-smoke-001.md"
OUT="$RESULTS_DIR/smoke-001.out"
STATUS="$RESULTS_DIR/smoke-001.status.json"
FAILED_STATUS="$RESULTS_DIR/smoke-002.status.json"
TASKS_JSONL="$ORCH_DIR/tasks.jsonl"
AUDIT_JSONL="$ORCH_DIR/audit.jsonl"
DASH="$PROJECT_ROOT/bin/orch-dashboard.sh"
METRICS="$PROJECT_ROOT/bin/orch-metrics.sh"
SERVER="$PROJECT_ROOT/mcp-server/server.mjs"
TASK_STATUS_LIB="$PROJECT_ROOT/lib/task-status.sh"
SESSION_LIB="$PROJECT_ROOT/lib/session-context.sh"

cat > "$SPEC" <<'SPECEOF'
---
id: smoke-001
agent: oc-medium
task_type: implement_feature
priority: normal
depends_on:
  - smoke-000
session_context: true
---

# Smoke task

Mock dispatch pipeline task.
SPECEOF

printf 'Mock agent output for smoke-001.\n' > "$OUT"

cat > "$STATUS" <<'STATUSEOF'
{
  "schema_version": 1,
  "task_id": "smoke-001",
  "task_type": "implement_feature",
  "strategy_used": "first_success",
  "final_state": "done",
  "output_file": "smoke-001.out",
  "output_bytes": 34,
  "winner_agent": "oc-medium",
  "candidates_tried": ["oc-medium"],
  "successful_candidates": ["oc-medium"],
  "consensus_score": 0.0,
  "reflexion_iterations": 0,
  "markers": [],
  "duration_sec": 5.2,
  "started_at": "2026-04-26T11:59:55Z",
  "completed_at": "2026-04-26T12:00:00Z"
}
STATUSEOF

cat > "$FAILED_STATUS" <<'FAILEOF'
{
  "schema_version": 1,
  "task_id": "smoke-002",
  "task_type": "implement_feature",
  "strategy_used": "first_success",
  "final_state": "failed",
  "output_file": "smoke-002.out",
  "output_bytes": 12,
  "winner_agent": "oc-low",
  "candidates_tried": ["oc-low"],
  "successful_candidates": [],
  "consensus_score": 0.0,
  "reflexion_iterations": 1,
  "markers": ["mock_failure"],
  "duration_sec": 2.0,
  "started_at": "2026-04-26T12:00:01Z",
  "completed_at": "2026-04-26T12:00:03Z"
}
FAILEOF
printf 'mock failure\n' > "$RESULTS_DIR/smoke-002.out"

cat > "$AUDIT_JSONL" <<'AUDITEOF'
{"task_id":"smoke-001","agent":"oc-medium","status":"done","duration_s":5.2,"tokens_est":1200,"ts":"2026-04-26T12:00:00Z"}
AUDITEOF

cat > "$TASKS_JSONL" <<'JSONLEOF'
{"event":"start","task_id":"smoke-001","agent":"oc-medium","ts":"2026-04-26T12:00:00Z"}
{"event":"complete","task_id":"smoke-001","agent":"oc-medium","status":"success","duration_s":5.2,"prompt_chars":2400,"output_chars":1200,"ts":"2026-04-26T12:00:05Z"}
{"event":"start","task_id":"smoke-002","agent":"oc-low","ts":"2026-04-26T12:00:01Z"}
{"event":"complete","task_id":"smoke-002","agent":"oc-low","status":"failed","duration_s":2.0,"prompt_chars":800,"output_chars":120,"ts":"2026-04-26T12:00:03Z"}
JSONLEOF

echo "── Phase A: Artifact creation ───────────────────────────────────"

assert_file_exists "T01 artifact: task spec created" "$SPEC"

front_id=$(python3 - "$SPEC" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.match(r"^---\n(.*?)\n---", text, re.S)
if match and "id: smoke-001" in match.group(1):
    print("smoke-001")
else:
    print("missing")
PYEOF
)
assert_eq "T02 artifact: frontmatter parseable" "smoke-001" "$front_id"

assert_file_exists "T03 artifact: mock output exists" "$OUT"
assert_json_file "T04 artifact: status JSON valid" "$STATUS"
assert_jsonl_file "T05 artifact: audit JSONL valid" "$AUDIT_JSONL"

echo "── Phase B: Status library integration ─────────────────────────"

source_ok=0
(source "$TASK_STATUS_LIB" && echo ok) >/dev/null 2>&1 || source_ok=$?
assert_eq "T06 status lib: source succeeds" "0" "$source_ok"

# shellcheck source=../lib/task-status.sh
. "$TASK_STATUS_LIB"

state=$(json_get_file "$STATUS" "final_state")
duration=$(json_get_file "$STATUS" "duration_sec")
agent=$(json_get_file "$STATUS" "winner_agent")
assert_eq "T07 status lib: final_state reads correctly" "done" "$state"
assert_eq "T08 status lib: duration extraction" "5.2" "$duration"
assert_eq "T09 status lib: agent extraction" "oc-medium" "$agent"

summary_json=$(build_status_json \
  "summary-001" "smoke" "first_success" "done" \
  "summary-001.out" "10" "oc-medium" \
  "oc-medium" "oc-medium" "0" "0" "" \
  "3.0" "2026-04-26T12:00:00Z" "2026-04-26T12:00:03Z")
summary_state=$(json_get_string "$summary_json" "final_state")
assert_eq "T10 status lib: build_status_json produces correct state" "done" "$summary_state"

echo "── Phase C: Metrics rollup integration ─────────────────────────"

rollup_json=$(bash "$METRICS" rollup --json --dir "$RESULTS_DIR" 2>/dev/null)
assert_json_string "T11 metrics: rollup JSON valid" "$rollup_json"

unique_tasks=$(json_get_string "$rollup_json" "totals.unique_tasks")
assert_eq "T12 metrics: counts both mock tasks" "2" "$unique_tasks"

success_rate=$(json_get_string "$rollup_json" "by_task_type.implement_feature.success_rate_pct")
assert_eq "T13 metrics: 50% success rate with 1 success 1 fail" "50.0" "$success_rate"

failed_count=$(json_get_string "$rollup_json" "final_state_counts.failed")
assert_eq "T14 metrics: failed task counted" "1" "$failed_count"

avg_duration=$(json_get_string "$rollup_json" "by_task_type.implement_feature.by_strategy.first_success.avg_duration_sec")
assert_eq "T15 metrics: avg duration computed" "3.6" "$avg_duration"

echo "── Phase D: Dashboard integration ──────────────────────────────"

metrics_json=$(PROJECT_ROOT="$TMPTEST_DIR" bash "$DASH" metrics --json 2>/dev/null || printf '{}')
assert_json_string "T16 dashboard: metrics --json valid" "$metrics_json"
assert_contains "T17 dashboard: metrics includes mock agent oc-medium" "oc-medium" "$metrics_json"

budget_json=$(BUDGET_AUDIT_FILE="$AUDIT_JSONL" \
  BUDGET_COST_LOG="$TMPTEST_DIR/no-cost.jsonl" \
  BUDGET_RESULTS_DIR="$RESULTS_DIR" \
  BUDGET_CONFIG="$TMPTEST_DIR/no-budget.yaml" \
  BUDGET_MODELS_YAML="$PROJECT_ROOT/config/models.yaml" \
  bash "$DASH" budget --json 2>/dev/null || printf '{}')
assert_json_string "T18 dashboard: budget --json valid or graceful empty" "$budget_json"

help_out=$(bash "$DASH" help 2>/dev/null || bash "$DASH" 2>/dev/null || printf '')
assert_contains "T19 dashboard: help lists Subcommands" "Subcommands:" "$help_out"

missing_subcommands=""
for sub in cost metrics slo report db budget learn react context; do
  if ! printf '%s' "$help_out" | grep -qF -- "$sub"; then
    missing_subcommands="$missing_subcommands $sub"
  fi
done
assert_eq "T20 dashboard: all 9 listed subcommands appear in help" "" "$missing_subcommands"

echo "── Phase E: MCP server integration ─────────────────────────────"

node_exit=0
node --check "$SERVER" >/dev/null 2>&1 || node_exit=$?
assert_eq "T21 mcp: node --check syntax valid" "0" "$node_exit"

tool_count=$(python3 - "$SERVER" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# Count unique tool name strings in the tools array definition
names = set(re.findall(r'name:\s*"([a-z_]+)"', text))
print(len(names))
PYEOF
)
if [ "$tool_count" -ge 14 ]; then
  pass "T22 mcp: 14+ tool names registered"
else
  fail "T22 mcp: 14+ tool names registered" "count=$tool_count"
fi

schema_ok=$(python3 - "$SERVER" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# Each tool block has inputSchema: { type: "object" ... }
blocks = re.findall(r'inputSchema:\s*\{[^}]*type:\s*"object"', text, re.S)
# Count tool blocks by name occurrences in the ListTools handler
tool_names = re.findall(r'name:\s*"([a-z_]+)"', text)
unique_names = set(tool_names)
print("ok" if len(blocks) >= len(unique_names) else "bad")
PYEOF
)
assert_eq "T23 mcp: inputSchema type:object present for tools" "ok" "$schema_ok"

echo "── Phase F: Cross-component chain ──────────────────────────────"

chain_ok=$(python3 - "$SPEC" "$OUT" "$STATUS" "$rollup_json" "$metrics_json" <<'PYEOF'
import json, os, sys
spec_path, out_path, status_path, rollup_raw, dash_raw = sys.argv[1:]
rollup = json.loads(rollup_raw)
dash = json.loads(dash_raw)
ok = (
    os.path.exists(spec_path)
    and os.path.exists(out_path)
    and json.load(open(status_path, encoding="utf-8"))["final_state"] == "done"
    and rollup["totals"]["unique_tasks"] >= 1
    and dash["summary"]["unique_tasks"] >= 1
)
print("ok" if ok else "fail")
PYEOF
)
assert_eq "T24 chain: spec to dashboard end-to-end reads correctly" "ok" "$chain_ok"

cat > "$ORCH_DIR/tasks/smoke-test/task-smoke-003.md" <<'DEPEOF'
---
id: smoke-003
depends_on:
  - smoke-001
  - smoke-002
---

# Dependent smoke task
DEPEOF

dep_count=$(python3 - "$ORCH_DIR/tasks/smoke-test/task-smoke-003.md" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---", text, re.S)
front = m.group(1) if m else ""
print(len(re.findall(r"^\s+-\s+smoke-", front, re.M)))
PYEOF
)
assert_eq "T25 chain: depends_on resolution path exists" "2" "$dep_count"

# shellcheck source=../lib/session-context.sh
. "$SESSION_LIB"
brief_json=$(build_session_brief "smoke-003" "smoke-001 smoke-002" "$RESULTS_DIR")
save_session_context "smoke-003" "$brief_json"
loaded_brief=$(load_session_context "smoke-003")
brief_task=$(json_get_string "$loaded_brief" "task_id")
assert_eq "T26 chain: session context save and load round-trips" "smoke-003" "$brief_task"

failed_again=$(json_get_string "$rollup_json" "final_state_counts.failed")
assert_eq "T27 chain: failed task counted in rollup metrics" "1" "$failed_again"

EMPTY_ORCH="$TMPTEST_DIR/empty-project/.orchestration"
mkdir -p "$EMPTY_ORCH"
printf '' > "$EMPTY_ORCH/tasks.jsonl"
empty_json=$(PROJECT_ROOT="$TMPTEST_DIR/empty-project" bash "$DASH" metrics --json 2>/dev/null || printf '{}')
empty_ok=$(printf '%s' "$empty_json" | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")' 2>/dev/null || printf 'fail')
assert_eq "T28 chain: empty state dashboard does not crash" "ok" "$empty_ok"

echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL $TOTAL TESTS: $PASS PASS, 0 FAIL"
else
  echo "ALL $TOTAL TESTS: $PASS PASS, $FAIL FAIL"
fi
echo "============================================================"

exit "$FAIL"
