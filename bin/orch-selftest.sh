#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/.." && pwd))"

VERBOSE=0
LIST_ONLY=0
SELECTED_SUITE=""
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
ASSERT_MSG=""
SUITE_NAME_WIDTH=56
SETUP_OUTPUT=""
TMP_ROOT=""

SUITES=(
  "circuit-breaker"
  "agent-load"
  "agent-cost"
  "dag"
  "task-cancel"
  "task-schedule"
  "task-diff"
  "orch-health-beacon"
)

cleanup() {
  if [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
  return 0
}
trap cleanup EXIT

print_test_line() {
  local suite="$1" name="$2" result="$3"
  printf '[TEST] %s: %-*s %s\n' "$suite" "$SUITE_NAME_WIDTH" "$name" "$result"
}

run_test() {
  local suite="$1" name="$2"
  shift 2
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  ASSERT_MSG=""
  if "$@"; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    [ "$VERBOSE" -eq 1 ] && print_test_line "$suite" "$name" "PASS"
  else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    print_test_line "$suite" "$name" "FAIL"
    [ -n "$ASSERT_MSG" ] && printf '       %s\n' "$ASSERT_MSG"
  fi
  return 0
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [ "$expected" = "$actual" ]; then
    return 0
  fi
  ASSERT_MSG="$message (expected='$expected' actual='$actual')"
  return 1
}

assert_exit() {
  local expected_code="$1"
  shift
  local rc
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq "$expected_code" ]; then
    return 0
  fi
  ASSERT_MSG="exit code mismatch (expected=$expected_code actual=$rc)"
  return 1
}

record_setup_failure() {
  local suite="$1" name="$2" rc="$3" detail="${4:-}"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  FAILED_TESTS=$((FAILED_TESTS + 1))
  print_test_line "$suite" "$name" "FAIL"
  if [ -n "$detail" ]; then
    printf "       setup failed (expected='0' actual='%s'): %s\n" "$rc" "$detail"
  else
    printf "       setup failed (expected='0' actual='%s')\n" "$rc"
  fi
}

run_setup() {
  local suite="$1" name="$2" capture=0
  shift 2
  if [ "${1:-}" = "0" ] || [ "${1:-}" = "1" ]; then
    capture="$1"
    shift
  fi
  local rc output
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    output="$(printf '%s' "$output" | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')"
    record_setup_failure "$suite" "$name" "$rc" "$output"
    return 1
  fi
  [ "$capture" -eq 1 ] && SETUP_OUTPUT="$output"
  return 0
}

capture_setup_output() {
  run_setup "$1" "$2" 1 "${@:3}"
}

suite_workspace() {
  local suite="$1" ws="$TMP_ROOT/$suite"
  run_setup "$suite" "workspace create dirs" 0 mkdir -p "$ws/bin" "$ws/.orchestration" || return 1
  run_setup "$suite" "workspace copy scripts" 0 cp \
    "$PROJECT_ROOT/bin/circuit-breaker.sh" \
    "$PROJECT_ROOT/bin/agent-load.sh" \
    "$PROJECT_ROOT/bin/agent-cost.sh" \
    "$PROJECT_ROOT/bin/task-dag.sh" \
    "$PROJECT_ROOT/bin/task-cancel.sh" \
    "$PROJECT_ROOT/bin/task-schedule.sh" \
    "$PROJECT_ROOT/bin/task-diff.sh" \
    "$PROJECT_ROOT/bin/orch-health-beacon.sh" \
    "$PROJECT_ROOT/bin/task-dispatch.sh" \
    "$ws/bin/" || return 1
  run_setup "$suite" "workspace chmod scripts" 0 chmod +x "$ws"/bin/*.sh || return 1
  run_setup "$suite" "workspace git init" 0 bash -c 'cd "$1" && git init -q' _ "$ws" || return 1
  printf '%s\n' "$ws"
}

suite_circuit_breaker() {
  local suite="circuit-breaker" ws agent
  ws="$(suite_workspace "$suite")" || return 0
  agent="copilot"

  run_test "$suite" "initial check exits 0" assert_exit 0 bash -c 'cd "$1" && ./bin/circuit-breaker.sh check "$2"' _ "$ws" "$agent"

  run_setup "$suite" "record-failure fixture x3" bash -c 'cd "$1" && for _ in 1 2 3; do ./bin/circuit-breaker.sh record-failure "$2" >/dev/null; done' _ "$ws" "$agent" || return 0
  run_test "$suite" "opens after 3 failures" assert_exit 1 bash -c 'cd "$1" && ./bin/circuit-breaker.sh check "$2"' _ "$ws" "$agent"

  run_setup "$suite" "force half-open fixture" bash -c 'cd "$1" && python3 -c '"'"'import json,time; from pathlib import Path; p=Path(".orchestration/circuit-breaker.json"); d=json.loads(p.read_text(encoding="utf-8")); e=d.get("copilot", {}); back=int(time.time())-301; e["last_probe"]=back; e["last_failure"]=back; e["state"]="OPEN"; d["copilot"]=e; p.write_text(json.dumps(d, indent=2, sort_keys=True)+"\n", encoding="utf-8")'"'"'' _ "$ws" || return 0
  run_test "$suite" "half-open after timeout" assert_exit 0 bash -c 'cd "$1" && ./bin/circuit-breaker.sh check "$2"' _ "$ws" "$agent"

  run_setup "$suite" "record-success fixture" bash -c 'cd "$1" && ./bin/circuit-breaker.sh record-success "$2" >/dev/null' _ "$ws" "$agent" || return 0
  run_test "$suite" "record-success closes" assert_exit 0 bash -c 'cd "$1" && ./bin/circuit-breaker.sh check "$2"' _ "$ws" "$agent"

  run_test "$suite" "reset command exits 0" assert_exit 0 bash -c 'cd "$1" && ./bin/circuit-breaker.sh reset "$2"' _ "$ws" "$agent"
}

suite_agent_load() {
  local suite="agent-load" ws status copilot gemini least tie
  ws="$(suite_workspace "$suite")" || return 0

  run_setup "$suite" "increment copilot x3 fixture" bash -c 'cd "$1" && for _ in 1 2 3; do ./bin/agent-load.sh increment copilot >/dev/null; done' _ "$ws" || return 0
  run_setup "$suite" "increment gemini fixture" bash -c 'cd "$1" && ./bin/agent-load.sh increment gemini >/dev/null' _ "$ws" || return 0

  capture_setup_output "$suite" "capture status fixture" bash -c 'cd "$1" && ./bin/agent-load.sh status' _ "$ws" || return 0
  status="$SETUP_OUTPUT"
  copilot="$(printf '%s\n' "$status" | awk '$1=="copilot"{print $2; exit}')"
  gemini="$(printf '%s\n' "$status" | awk '$1=="gemini"{print $2; exit}')"
  run_test "$suite" "status copilot=3" assert_eq "3" "$copilot" "copilot load"
  run_test "$suite" "status gemini=1" assert_eq "1" "$gemini" "gemini load"

  capture_setup_output "$suite" "capture least-loaded fixture" bash -c 'cd "$1" && ./bin/agent-load.sh least-loaded copilot gemini' _ "$ws" || return 0
  least="$SETUP_OUTPUT"
  run_test "$suite" "least-loaded is gemini" assert_eq "gemini" "$least" "least-loaded result"

  run_setup "$suite" "decrement copilot x3 fixture" bash -c 'cd "$1" && for _ in 1 2 3; do ./bin/agent-load.sh decrement copilot >/dev/null; done' _ "$ws" || return 0
  capture_setup_output "$suite" "capture decrement status fixture" bash -c 'cd "$1" && ./bin/agent-load.sh status' _ "$ws" || return 0
  status="$SETUP_OUTPUT"
  copilot="$(printf '%s\n' "$status" | awk '$1=="copilot"{print $2; exit}')"
  run_test "$suite" "decrement copilot to 0" assert_eq "0" "$copilot" "copilot decrement"

  capture_setup_output "$suite" "capture least-loaded after decrement fixture" bash -c 'cd "$1" && ./bin/agent-load.sh least-loaded copilot gemini' _ "$ws" || return 0
  least="$SETUP_OUTPUT"
  run_test "$suite" "least-loaded is copilot" assert_eq "copilot" "$least" "least-loaded after decrement"

  run_setup "$suite" "decrement gemini fixture" bash -c 'cd "$1" && ./bin/agent-load.sh decrement gemini >/dev/null' _ "$ws" || return 0
  capture_setup_output "$suite" "capture tie fixture" bash -c 'cd "$1" && ./bin/agent-load.sh least-loaded copilot gemini' _ "$ws" || return 0
  tie="$SETUP_OUTPUT"
  run_test "$suite" "tie breaks alphabetically" assert_eq "copilot" "$tie" "tie-breaking"
}

suite_agent_cost() {
  local suite="agent-cost" ws cheapest estimate
  ws="$(suite_workspace "$suite")" || return 0
  if ! run_setup "$suite" "write agent-cost fixtures" python3 - "$ws" <<'PY'; then
import json,sys
from pathlib import Path
ws=Path(sys.argv[1])
(ws/".orchestration/agents.json").write_text(json.dumps({"agents":{
  "copilot":{"cost_tier":2,"cost_per_1k_tokens":0.003,"capabilities":["code","review"]},
  "gemini":{"cost_tier":1,"cost_per_1k_tokens":0.0015,"capabilities":["analysis","code"]},
  "oracle":{"cost_tier":1,"cost_per_1k_tokens":0.002,"capabilities":["analysis"]}}},indent=2)+"\n",encoding="utf-8")
(ws/"bin/orch-health-beacon.sh").write_text("#!/usr/bin/env bash\nset -euo pipefail\n[ \"${1:-}\" = \"--check\" ] && exit 0\nexit 0\n",encoding="utf-8")
PY
    return 0
  fi
  run_setup "$suite" "chmod health beacon fixture" chmod +x "$ws/bin/orch-health-beacon.sh" || return 0

  capture_setup_output "$suite" "capture cheapest fixture" bash -c 'cd "$1" && ./bin/agent-cost.sh cheapest code' _ "$ws" || return 0
  cheapest="$SETUP_OUTPUT"
  run_test "$suite" "cheapest code agent" assert_eq "gemini" "$cheapest" "cheapest code agent"

  capture_setup_output "$suite" "capture estimate fixture" bash -c 'cd "$1" && ./bin/agent-cost.sh estimate gemini 1000' _ "$ws" || return 0
  estimate="$SETUP_OUTPUT"
  run_test "$suite" "estimate gemini 1000" assert_eq "0.001500" "$estimate" "cost estimate"
}

suite_dag() {
  local suite="dag" ws ascii json parallel cycle_output cycle_rc
  ws="$(suite_workspace "$suite")" || return 0
  run_setup "$suite" "create task dirs fixture" mkdir -p "$ws/.orchestration/tasks/basic" "$ws/.orchestration/tasks/cycle" || return 0

  if ! run_setup "$suite" "write dag fixtures" python3 - "$ws" <<'PY'
from pathlib import Path
root=Path(__import__('sys').argv[1]) / ".orchestration/tasks"
files={"basic/task-1.md":"---\nid: task-a\nagent: gemini\n---\n","basic/task-2.md":"---\nid: task-b\nagent: copilot\ndepends_on: [task-a]\n---\n","basic/task-3.md":"---\nid: task-c\nagent: copilot\ndepends_on: [task-a]\n---\n","basic/task-4.md":"---\nid: task-d\nagent: gemini\ndepends_on: [task-b, task-c]\n---\n","cycle/task-1.md":"---\nid: cyc-a\ndepends_on: [cyc-b]\n---\n","cycle/task-2.md":"---\nid: cyc-b\ndepends_on: [cyc-a]\n---\n"}
for rel,content in files.items():
    p=root/rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(content, encoding="utf-8")
PY
  then
    return 0
  fi

  capture_setup_output "$suite" "capture dag ascii fixture" bash -c 'cd "$1" && ./bin/task-dag.sh .orchestration/tasks/basic' _ "$ws" || return 0
  ascii="$SETUP_OUTPUT"
  run_test "$suite" "ascii has level 0 root" assert_eq "1" "$(printf '%s\n' "$ascii" | grep -Eq '^\s*\[0\] task-a' && echo 1 || echo 0)" "task-a level"
  run_test "$suite" "ascii has level 1 branches" assert_eq "1" "$(printf '%s\n' "$ascii" | grep -Eq '^\s*\[1\] task-b' && printf '%s\n' "$ascii" | grep -Eq '^\s*\[1\] task-c' && echo 1 || echo 0)" "task-b/task-c levels"
  run_test "$suite" "ascii has level 2 leaf" assert_eq "1" "$(printf '%s\n' "$ascii" | grep -Eq '^\s*\[2\] task-d' && echo 1 || echo 0)" "task-d level"

  capture_setup_output "$suite" "capture dag json fixture" bash -c 'cd "$1" && ./bin/task-dag.sh .orchestration/tasks/basic --json' _ "$ws" || return 0
  json="$SETUP_OUTPUT"
  parallel="$(printf '%s\n' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["summary"]["parallel_groups"])')"
  run_test "$suite" "json parallel_groups=3" assert_eq "3" "$parallel" "parallel groups"

  set +e
  cycle_output="$(cd "$ws" && ./bin/task-dag.sh .orchestration/tasks/cycle 2>&1)"
  cycle_rc=$?
  set -e
  run_test "$suite" "cyclic batch exits 0" assert_eq "0" "$cycle_rc" "cycle exit code"
  run_test "$suite" "cyclic warning emitted" assert_eq "1" "$(printf '%s\n' "$cycle_output" | grep -Eq 'WARNING: cycle detected' && echo 1 || echo 0)" "cycle warning"
}

suite_task_cancel() {
  local suite="task-cancel" ws status
  ws="$(suite_workspace "$suite")" || return 0

  capture_setup_output "$suite" "capture initial status fixture" bash -c 'cd "$1" && ./bin/task-cancel.sh status' _ "$ws" || return 0
  status="$SETUP_OUTPUT"
  run_test "$suite" "status prints header" assert_eq "1" "$(printf '%s\n' "$status" | grep -Eq '^Running tasks:' && echo 1 || echo 0)" "status header"
  run_test "$suite" "status shows none" assert_eq "1" "$(printf '%s\n' "$status" | grep -Eq '^  \(none\)$' && echo 1 || echo 0)" "status none"

  run_setup "$suite" "create stale pid fixture" bash -c 'mkdir -p "$1/.orchestration/pids" && printf "999999\n" > "$1/.orchestration/pids/stale.pid"' _ "$ws" || return 0
  run_test "$suite" "stale pid cancel exits 1" assert_exit 1 bash -c 'cd "$1" && ./bin/task-cancel.sh stale' _ "$ws"
  run_test "$suite" "stale pid file removed" assert_eq "0" "$([ -f "$ws/.orchestration/pids/stale.pid" ] && echo 1 || echo 0)" "stale pid removal"

  capture_setup_output "$suite" "capture status after stale cancel fixture" bash -c 'cd "$1" && ./bin/task-cancel.sh status' _ "$ws" || return 0
  status="$SETUP_OUTPUT"
  run_test "$suite" "status remains none after stale pid" assert_eq "1" "$(printf '%s\n' "$status" | grep -Eq '^  \(none\)$' && echo 1 || echo 0)" "status after stale pid"
}

suite_task_schedule() {
  local suite="task-schedule" ws list_out dry_out next_out dispatched
  ws="$(suite_workspace "$suite")" || return 0
  run_setup "$suite" "create scheduled dir fixture" mkdir -p "$ws/.orchestration/scheduled-tasks" || return 0
  if ! run_setup "$suite" "write scheduled task fixtures" python3 - "$ws" <<'PY'; then
from pathlib import Path
root=Path(__import__('sys').argv[1]) / ".orchestration/scheduled-tasks"
(root/"due.schedule.md").write_text("""---
id: due-task
schedule: "0 9 * * *"
schedule_tz: "UTC"
enabled: true
last_run: "2000-01-01T00:00:00Z"
next_run: "2000-01-01T09:00:00Z"
agent: "gemini"
---

Run due task
""", encoding="utf-8")
(root/"cron.schedule.md").write_text("""---
id: cron-check
schedule: "0 9 * * *"
schedule_tz: "UTC"
enabled: true
last_run: "2026-04-21T08:00:00Z"
agent: "gemini"
---

Check cron next
""", encoding="utf-8")
PY
    return 0
  fi

  capture_setup_output "$suite" "capture schedule list fixture" bash -c 'cd "$1" && ./bin/task-schedule.sh list' _ "$ws" || return 0
  list_out="$SETUP_OUTPUT"
  run_test "$suite" "list marks due task" assert_eq "1" "$(printf '%s\n' "$list_out" | awk -F'\t' '$1=="due-task" && /DUE/{found=1} END{print found+0}')" "due marker"

  capture_setup_output "$suite" "capture run-due dry-run fixture" bash -c 'cd "$1" && ./bin/task-schedule.sh run-due --dry-run' _ "$ws" || return 0
  dry_out="$SETUP_OUTPUT"
  dispatched="$(printf '%s\n' "$dry_out" | sed -n 's/.*dispatched=\([0-9][0-9]*\).*/\1/p' | head -n1)"
  run_test "$suite" "run-due dry-run dispatched=1" assert_eq "1" "$dispatched" "dry-run dispatch count"

  capture_setup_output "$suite" "capture cron next fixture" bash -c 'cd "$1" && ./bin/task-schedule.sh next cron-check | tr -d "\r"' _ "$ws" || return 0
  next_out="$SETUP_OUTPUT"
  run_test "$suite" "cron_next UTC calculation" assert_eq "2026-04-21T09:00:00Z" "$next_out" "cron next"
}

suite_task_diff() {
  local suite="task-diff" ws
  ws="$(suite_workspace "$suite")" || return 0
  run_setup "$suite" "create task-diff fixture dirs" mkdir -p "$ws/.orchestration/results" "$ws/fixtures" || return 0
  run_setup "$suite" "write task-diff fixtures" bash -c 'cd "$1" && printf "alpha\nbeta\n" > .orchestration/results/batch-001-task-a.v1.out && printf "alpha\ngamma\ndelta\n" > .orchestration/results/batch-001-task-a.out && printf "no revisions\n" > .orchestration/results/batch-001-task-b.out && printf "line1\nline2\n" > fixtures/a.txt && printf "line1\nline3\n" > fixtures/b.txt' _ "$ws" || return 0
  run_test "$suite" "batch summary mode" assert_exit 0 bash -c 'cd "$1" && out="$(./bin/task-diff.sh --batch batch-001)" && printf "%s\n" "$out" | grep -Fq "Result Diffs Summary (batch: batch-001)" && printf "%s\n" "$out" | grep -Fq "batch-001-task-a: +2 lines, -1 lines  (revised)" && printf "%s\n" "$out" | grep -Fq "batch-001-task-b: no revisions"' _ "$ws"
  run_test "$suite" "file diff mode" assert_exit 0 bash -c 'cd "$1" && out="$(./bin/task-diff.sh fixtures/a.txt fixtures/b.txt)" && printf "%s\n" "$out" | grep -Fq "Diff: fixtures/a.txt vs fixtures/b.txt" && printf "%s\n" "$out" | grep -Fq "Changes: +1 lines added, -1 lines removed"' _ "$ws"
  run_test "$suite" "missing batch handling" assert_exit 0 bash -c 'cd "$1" && ./bin/task-diff.sh --batch missing-batch | grep -Fq "no matching tasks"' _ "$ws"
}

suite_orch_health_beacon() {
  local suite="orch-health-beacon" ws
  ws="$(suite_workspace "$suite")" || return 0
  run_setup "$suite" "create health beacon fixture dir" mkdir -p "$ws/.orchestration" || return 0
  if ! run_setup "$suite" "write health beacon jsonl fixtures" python3 - "$ws" <<'PY'; then
import datetime as dt, json, sys
from pathlib import Path
ws=Path(sys.argv[1]); now=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"); rows=[]
rows += [{"event":"complete","agent":"healthy-agent","status":"success","duration_s":0.3,"ts":now}] * 10
rows += [{"event":"complete","agent":"degraded-agent","status":"success","duration_s":0.4,"ts":now}] * 9 + [{"event":"complete","agent":"degraded-agent","status":"failed","duration_s":0.4,"ts":now}]
rows += [{"event":"complete","agent":"down-agent","status":"failed","duration_s":0.5,"ts":now}] * 3 + [{"event":"complete","agent":"down-agent","status":"success","duration_s":0.5,"ts":now},{"event":"start","agent":"healthy-agent","status":"ok","ts":now}]
(ws/".orchestration/tasks.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
PY
    return 0
  fi
  run_test "$suite" "json classifications" assert_exit 0 bash -c 'cd "$1" && ./bin/orch-health-beacon.sh --json --window 3600 | python3 -c '"'"'import json,sys; a=json.load(sys.stdin)["agents"]; sys.exit(0 if (a["healthy-agent"]["status"],a["degraded-agent"]["status"],a["down-agent"]["status"])==("HEALTHY","DEGRADED","DOWN") else 1)'"'"'' _ "$ws"
  run_test "$suite" "check healthy exits 0" assert_exit 0 bash -c 'cd "$1" && ./bin/orch-health-beacon.sh --check healthy-agent --window 3600' _ "$ws"
  run_test "$suite" "check degraded exits 1" assert_exit 1 bash -c 'cd "$1" && ./bin/orch-health-beacon.sh --check degraded-agent --window 3600' _ "$ws"
  run_test "$suite" "check down exits 2" assert_exit 2 bash -c 'cd "$1" && ./bin/orch-health-beacon.sh --check down-agent --window 3600' _ "$ws"
  run_test "$suite" "check missing agent exits 2" assert_exit 2 bash -c 'cd "$1" && ./bin/orch-health-beacon.sh --check unknown-agent --window 3600' _ "$ws"
}

run_suite() {
  case "$1" in
    circuit-breaker) suite_circuit_breaker ;; agent-load) suite_agent_load ;; agent-cost) suite_agent_cost ;;
    dag) suite_dag ;; task-cancel) suite_task_cancel ;; task-schedule) suite_task_schedule ;;
    task-diff) suite_task_diff ;; orch-health-beacon) suite_orch_health_beacon ;;
    *) echo "Unknown suite: $1" >&2; exit 2 ;;
  esac
}

for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=1 ;;
    --list) LIST_ONLY=1 ;;
    -h|--help) echo "Usage: orch-selftest.sh [--list] [--verbose] [suite]" >&2; exit 0 ;;
    --*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *)
      if [ -n "$SELECTED_SUITE" ]; then
        echo "Only one suite may be specified" >&2
        exit 2
      fi
      SELECTED_SUITE="$arg"
      ;;
  esac
done

if [ "$LIST_ONLY" -eq 1 ]; then
  printf '%s\n' "${SUITES[@]}"
  exit 0
fi
[ -z "$SELECTED_SUITE" ] || case " ${SUITES[*]} " in *" $SELECTED_SUITE "*) ;; *) echo "Unknown suite: $SELECTED_SUITE" >&2; exit 2 ;; esac

TMP_ROOT="$(mktemp -d "$PROJECT_ROOT/.orch-selftest.XXXXXX")"

start_time="$(date +%s)"
if [ -n "$SELECTED_SUITE" ]; then
  run_suite "$SELECTED_SUITE"
else
  for suite in "${SUITES[@]}"; do
    run_suite "$suite"
  done
fi

end_time="$(date +%s)"
duration=$((end_time - start_time))
divider="$(printf '%*s' 72 '' | tr ' ' '─')"
printf '%s\n' "$divider"
printf 'Results: %d/%d passed (%d failed) in %ss\n' "$PASSED_TESTS" "$TOTAL_TESTS" "$FAILED_TESTS" "$duration"

[ "$FAILED_TESTS" -eq 0 ]
