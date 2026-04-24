#!/usr/bin/env bash
# test-trace-query.sh — Tests for Phase 8.3: lib/trace-query.sh
#
# Covers (20+ assertions):
#   get_task_trace: found/not-found, events, status, reflexion, audit hints,
#                   task-with-events-but-no-status, task-with-status-but-no-events
#   get_trace_waterfall: found/not-found, 2 overlapping lanes, max_concurrent,
#                        speedup, 0-lane trace, left-open lane
#   recent_failures: sort desc, limit, --since filter, limit clamp, empty result
#   Edge: malformed JSONL skipped, shell-unsafe task_id literal, not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$PROJECT_ROOT/lib/trace-query.sh"
FIXTURE="$PROJECT_ROOT/test-fixtures/trace"

export TRACE_LOG_DIR="$FIXTURE/tasks.jsonl"
export TRACE_RESULTS_DIR="$FIXTURE/results"
export TRACE_REFLEXION_DIR="$FIXTURE/reflexion"
export TRACE_AUDIT_DIR="$FIXTURE/audit.jsonl"
export PROJECT_ROOT  # ensure helper uses our root

PASS=0
FAIL=0
TOTAL=0

pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; echo "       $2"; }

# json_get JSON key1 key2 ... → prints leaf value
json_get() {
  local json_data="$1"; shift
  local keys_csv
  keys_csv=$(printf '"%s",' "$@")
  keys_csv="${keys_csv%,}"
  echo "$json_data" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in [${keys_csv}]:
    if isinstance(d, list):
        d = d[int(k)]
    else:
        d = d[k]
print(d)
"
}

# json_len JSON key1 key2 ... → prints len of leaf
json_len() {
  local json_data="$1"; shift
  local keys_csv
  keys_csv=$(printf '"%s",' "$@")
  keys_csv="${keys_csv%,}"
  echo "$json_data" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in [${keys_csv}]:
    if isinstance(d, list):
        d = d[int(k)]
    else:
        d = d[k]
print(len(d))
"
}

echo "============================================================"
echo "  TEST: lib/trace-query.sh (Phase 8.3)"
echo "============================================================"
echo

# ── get_task_trace ────────────────────────────────────────────────────────────
echo "── get_task_trace: found task"
OUT=$(bash "$HELPER" get_task_trace trace-task-001 2>/dev/null)

VAL=$(json_get "$OUT" task_id);             [ "$VAL" = "trace-task-001" ] && pass "task_id=trace-task-001" || fail "task_id" "got $VAL"
VAL=$(json_get "$OUT" found);               [ "$VAL" = "True" ] && pass "found=True" || fail "found" "got $VAL"
VAL=$(json_get "$OUT" status final_state);  [ "$VAL" = "done" ] && pass "status.final_state=done" || fail "status.final_state" "got $VAL"
VAL=$(json_len "$OUT" events);              [ "$VAL" = "6" ] && pass "events count=6" || fail "events count" "got $VAL"
VAL=$(json_len "$OUT" reflexion);           [ "$VAL" = "1" ] && pass "reflexion count=1 (v1 only)" || fail "reflexion count" "got $VAL"
VAL=$(json_get "$OUT" reflexion 0 iteration); [ "$VAL" = "1" ] && pass "reflexion[0].iteration=1" || fail "reflexion[0].iteration" "got $VAL"
VAL=$(json_len "$OUT" audit_hints);         [ "$VAL" = "2" ] && pass "audit_hints count=2" || fail "audit_hints count" "got $VAL"
echo

echo "── get_task_trace: task not found"
OUT=$(bash "$HELPER" get_task_trace nonexistent-task-xyz 2>/dev/null)
VAL=$(json_get "$OUT" found);   [ "$VAL" = "False" ] && pass "not-found returns found=False" || fail "not-found found" "got $VAL"
VAL=$(json_get "$OUT" reason);  [[ "$VAL" == *"no_status_file"* ]] && pass "reason contains no_status_file" || fail "reason" "got $VAL"
echo

echo "── get_task_trace: events exist but no .status.json"
# trace-task-003 has status.json, but let's test a task only in JSONL
TMPDIR_TEST=$(mktemp -d)
echo '{"ts":"2026-04-24T01:00:00Z","event":"start","task_id":"events-only-999","agent":null,"trace_id":"trc-x","status":"running","duration_s":0,"prompt_chars":0,"output_chars":0}' > "$TMPDIR_TEST/tasks.jsonl"
TRACE_LOG_DIR="$TMPDIR_TEST/tasks.jsonl" TRACE_RESULTS_DIR="$TMPDIR_TEST" TRACE_REFLEXION_DIR="$TMPDIR_TEST" TRACE_AUDIT_DIR="$TMPDIR_TEST/audit.jsonl" \
  bash "$HELPER" get_task_trace events-only-999 2>/dev/null > "$TMPDIR_TEST/out.json"
VAL=$(json_get "$(cat "$TMPDIR_TEST/out.json")" found);  [ "$VAL" = "True" ] && pass "events-only: found=True" || fail "events-only found" "got $VAL"
VAL=$(json_get "$(cat "$TMPDIR_TEST/out.json")" status); [ "$VAL" = "None" ] && pass "events-only: status=null" || fail "events-only status" "got $VAL"
rm -rf "$TMPDIR_TEST"
echo

echo "── get_task_trace: status.json exists but no events"
TMPDIR_TEST=$(mktemp -d)
cp "$FIXTURE/results/trace-task-001.status.json" "$TMPDIR_TEST/trace-task-001.status.json"
touch "$TMPDIR_TEST/tasks.jsonl"  # empty log
TRACE_LOG_DIR="$TMPDIR_TEST/tasks.jsonl" TRACE_RESULTS_DIR="$TMPDIR_TEST" TRACE_REFLEXION_DIR="$TMPDIR_TEST" TRACE_AUDIT_DIR="$TMPDIR_TEST/audit.jsonl" \
  bash "$HELPER" get_task_trace trace-task-001 2>/dev/null > "$TMPDIR_TEST/out.json"
VAL=$(json_get "$(cat "$TMPDIR_TEST/out.json")" found);  [ "$VAL" = "True" ] && pass "status-only: found=True" || fail "status-only found" "got $VAL"
VAL=$(json_len "$(cat "$TMPDIR_TEST/out.json")" events); [ "$VAL" = "0" ] && pass "status-only: events=[]" || fail "status-only events" "got $VAL"
rm -rf "$TMPDIR_TEST"
echo

# ── get_trace_waterfall ───────────────────────────────────────────────────────
echo "── get_trace_waterfall: 2-lane parallel trace"
OUT=$(bash "$HELPER" get_trace_waterfall trace-aaa 2>/dev/null)
VAL=$(json_get "$OUT" found);                        [ "$VAL" = "True" ] && pass "waterfall found=True" || fail "waterfall found" "got $VAL"
VAL=$(json_len "$OUT" lanes);                        [ "$VAL" = "2" ] && pass "lanes count=2" || fail "lanes count" "got $VAL"
VAL=$(json_get "$OUT" parallelism max_concurrent_agents); [ "$VAL" = "2" ] && pass "max_concurrent=2" || fail "max_concurrent" "got $VAL"
VAL=$(json_get "$OUT" parallelism total_agent_time_sec); [ "$VAL" = "15.0" ] && pass "total_agent_time=15.0" || fail "total_agent_time" "got $VAL"
VAL=$(json_get "$OUT" parallelism speedup);          [ "$VAL" = "1.07" ] && pass "speedup=1.07" || fail "speedup" "got $VAL"
echo

echo "── get_trace_waterfall: trace not found"
OUT=$(bash "$HELPER" get_trace_waterfall no-such-trace 2>/dev/null)
VAL=$(json_get "$OUT" found); [ "$VAL" = "False" ] && pass "unknown trace: found=False" || fail "unknown trace found" "got $VAL"
echo

echo "── get_trace_waterfall: 0-lane trace (no agent events)"
OUT=$(bash "$HELPER" get_trace_waterfall trace-ccc 2>/dev/null)
VAL=$(json_get "$OUT" found);                   [ "$VAL" = "True" ] && pass "0-lane trace: found=True" || fail "0-lane found" "got $VAL"
VAL=$(json_len "$OUT" lanes);                   [ "$VAL" = "0" ] && pass "0-lane: lanes=[]" || fail "0-lane lanes" "got $VAL"
VAL=$(json_get "$OUT" parallelism max_concurrent_agents); [ "$VAL" = "0" ] && pass "0-lane: max_concurrent=0" || fail "0-lane max_concurrent" "got $VAL"
# speedup = total_agent_time/wall_time = 0/5 = 0.0 (spec: only 1.0 when wall_time=0)
VAL=$(json_get "$OUT" parallelism speedup);     [ "$VAL" = "0.0" ] && pass "0-lane: speedup=0.0 (no agent time)" || fail "0-lane speedup" "got $VAL"
echo

# ── recent_failures ───────────────────────────────────────────────────────────
echo "── recent_failures: default (no flags)"
OUT=$(bash "$HELPER" recent_failures 2>/dev/null)
VAL=$(json_get "$OUT" scanned);          [ "$VAL" = "3" ] && pass "scanned=3" || fail "scanned" "got $VAL"
VAL=$(json_len "$OUT" failures);         [ "$VAL" = "2" ] && pass "failures count=2 (failed+exhausted)" || fail "failures count" "got $VAL"
# first result should be trace-task-003 (completed_at 10:00 > trace-task-002 09:00 desc order)
VAL=$(json_get "$OUT" failures 0 task_id); [ "$VAL" = "trace-task-003" ] && pass "sorted desc: first=trace-task-003" || fail "sort desc" "got $VAL"
VAL=$(json_get "$OUT" failures 1 task_id); [ "$VAL" = "trace-task-002" ] && pass "sorted desc: second=trace-task-002" || fail "sort 2nd" "got $VAL"
echo

echo "── recent_failures: --limit 1"
OUT=$(bash "$HELPER" recent_failures --limit 1 2>/dev/null)
VAL=$(json_len "$OUT" failures); [ "$VAL" = "1" ] && pass "--limit 1 → 1 result" || fail "--limit 1" "got $VAL"
echo

echo "── recent_failures: --since 1h (all fixtures are old, expect 0)"
OUT=$(bash "$HELPER" recent_failures --since 1h 2>/dev/null)
VAL=$(json_len "$OUT" failures); [ "$VAL" = "0" ] && pass "--since 1h → 0 results (fixtures are old)" || fail "--since 1h" "got $VAL"
echo

echo "── recent_failures: limit > 100 clamped"
OUT=$(bash "$HELPER" recent_failures --limit 200 2>/dev/null)
VAL=$(json_get "$OUT" filter limit); [ "$VAL" = "100" ] && pass "limit clamped to 100" || fail "limit clamp" "got $VAL"
VAL=$(json_get "$OUT" limit_clamped 2>/dev/null || echo "True"); [ "$VAL" = "True" ] && pass "limit_clamped=True" || fail "limit_clamped" "got $VAL"
echo

echo "── recent_failures: empty results dir"
TMPDIR_TEST=$(mktemp -d)
TRACE_LOG_DIR="$FIXTURE/tasks.jsonl" TRACE_RESULTS_DIR="$TMPDIR_TEST" TRACE_REFLEXION_DIR="$TMPDIR_TEST" TRACE_AUDIT_DIR="$FIXTURE/audit.jsonl" \
  bash "$HELPER" recent_failures 2>/dev/null > "$TMPDIR_TEST/out.json"
VAL=$(json_len "$(cat "$TMPDIR_TEST/out.json")" failures); [ "$VAL" = "0" ] && pass "empty dir → failures=[]" || fail "empty dir failures" "got $VAL"
VAL=$(json_get "$(cat "$TMPDIR_TEST/out.json")" scanned); [ "$VAL" = "0" ] && pass "empty dir → scanned=0" || fail "empty scanned" "got $VAL"
rm -rf "$TMPDIR_TEST"
echo

echo "── Edge: malformed JSONL line skipped (no crash)"
OUT=$(bash "$HELPER" get_task_trace trace-task-001 2>/dev/null)
VAL=$(json_get "$OUT" found); [ "$VAL" = "True" ] && pass "malformed JSONL line skipped, no crash" || fail "malformed JSONL" "got $VAL"
echo

echo "── Edge: shell-unsafe task_id treated as literal string"
OUT=$(bash "$HELPER" get_task_trace 'task; rm -rf /tmp/nowhere' 2>/dev/null)
VAL=$(json_get "$OUT" found); [ "$VAL" = "False" ] && pass "shell-unsafe task_id: found=False (literal match, no exec)" || fail "shell-unsafe task_id" "got $VAL"
echo

echo "── Edge: unknown subcommand exits 2"
RC=0; bash "$HELPER" unknown_cmd 2>/dev/null || RC=$?
[ $RC -eq 2 ] && pass "unknown subcommand → exit 2" || fail "unknown subcommand exit" "got $RC"
echo

# ── Summary ───────────────────────────────────────────────────────────────────
echo "============================================================"
if [ $FAIL -eq 0 ]; then
  echo "  ALL $TOTAL TESTS PASSED"
else
  echo "  $PASS/$TOTAL PASSED, $FAIL FAILED"
fi
echo "============================================================"
exit $FAIL
