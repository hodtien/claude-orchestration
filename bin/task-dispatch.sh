#!/usr/bin/env bash
# task-dispatch.sh — Async task dispatcher
# Reads task spec files, dispatches to agents, writes results + inbox notification.
# Runs WITHOUT Claude — user triggers directly from terminal.
#
# Usage:
#   task-dispatch.sh <batch-dir>             # dispatch all tasks (always retries skipped/failed)
#   task-dispatch.sh <batch-dir> --parallel  # parallel dispatch (always retries skipped/failed)
#   task-dispatch.sh <batch-dir> --status    # show batch status only
#
# Batch dir: <project>/.orchestration/tasks/<batch-id>/
# Results:   <project>/.orchestration/results/<task-id>.out
# Inbox:     <project>/.orchestration/inbox/<batch-id>.done.md
#
# Task spec format: YAML frontmatter (--- delimited) + Markdown body as prompt.
# Required frontmatter: id, agent. Optional: retries, context_from, depends_on.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEALTH_BEACON_SH="$SCRIPT_DIR/orch-health-beacon.sh"
# shellcheck source=./notify-lib.sh
[ -f "$SCRIPT_DIR/notify-lib.sh" ] && . "$SCRIPT_DIR/notify-lib.sh" || notify_event() { return 0; }
# shellcheck source=./lib/triage-tiers.sh
[ -f "$SCRIPT_DIR/../lib/triage-tiers.sh" ] && . "$SCRIPT_DIR/../lib/triage-tiers.sh" || true
# shellcheck source=../lib/intent-verifier.sh
[ -f "$SCRIPT_DIR/../lib/intent-verifier.sh" ] && . "$SCRIPT_DIR/../lib/intent-verifier.sh" || verify_spec() { echo "{}"; return 0; }
# shellcheck source=../lib/cost-tracker.sh
[ -f "$SCRIPT_DIR/../lib/cost-tracker.sh" ] && . "$SCRIPT_DIR/../lib/cost-tracker.sh" || cost_record() { return 0; }
# shellcheck source=../lib/agent-failover.sh
[ -f "$SCRIPT_DIR/../lib/agent-failover.sh" ] && . "$SCRIPT_DIR/../lib/agent-failover.sh" || failover_find_available() { return 1; }
# shellcheck source=../lib/quality-gate.sh
if [ -f "$SCRIPT_DIR/../lib/quality-gate.sh" ]; then
  . "$SCRIPT_DIR/../lib/quality-gate.sh"
else
  check_quality_gate() { echo "pass"; }
  trigger_reflexion() { return 0; }
fi
# shellcheck source=../lib/context-compressor.sh
[ -f "$SCRIPT_DIR/../lib/context-compressor.sh" ] && . "$SCRIPT_DIR/../lib/context-compressor.sh" || compress_session() { return 0; }
# shellcheck source=../lib/consensus-vote.sh
[ -f "$SCRIPT_DIR/../lib/consensus-vote.sh" ] && . "$SCRIPT_DIR/../lib/consensus-vote.sh" || true
BATCH_DIR="${1:?Usage: task-dispatch.sh <batch-dir> [--parallel|--status]}"
MODE="${2:---sequential}"
# Always retry skipped/failed tasks — no flag needed
FORCE_RETRY=true
# Strip legacy --retry-skipped flag if passed (backwards compat)
[[ "$MODE" == "--retry-skipped" ]] && MODE="--sequential"
[[ "${3:-}" == "--retry-skipped" ]] && true

# Resolve absolute path
if [[ ! "$BATCH_DIR" = /* ]]; then
  BATCH_DIR="$(pwd)/$BATCH_DIR"
fi

if [ ! -d "$BATCH_DIR" ]; then
  echo "[dispatch] batch dir not found: $BATCH_DIR" >&2
  exit 1
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ORCH_DIR="$PROJECT_ROOT/.orchestration"
RESULTS_DIR="$ORCH_DIR/results"
TASKS_DIR="$ORCH_DIR/tasks"
INBOX_DIR="$ORCH_DIR/inbox"
DLQ_DIR="$ORCH_DIR/dlq"
PIDS_DIR="$ORCH_DIR/pids"
LOG_FILE="$ORCH_DIR/tasks.jsonl"
mkdir -p "$RESULTS_DIR" "$INBOX_DIR" "$PIDS_DIR" "$TASKS_DIR"

BATCH_ID="$(basename "$BATCH_DIR")"
BATCH_CONF="$BATCH_DIR/batch.conf"

SHUTDOWN_IN_PROGRESS=false

log_shutdown_requested() {
  local signal="$1"
  python3 - "$signal" "$BATCH_ID" <<'PYEOF'
import datetime, json, sys
_, signal, batch_id = sys.argv
print(json.dumps({
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "event": "shutdown_requested",
    "signal": signal,
    "batch_id": batch_id,
}))
PYEOF
}

log_shutdown_complete() {
  local cancelled_csv="${1:-}"
  python3 - "$cancelled_csv" "$BATCH_ID" <<'PYEOF'
import datetime, json, sys
_, cancelled_csv, batch_id = sys.argv
cancelled_tasks = [item for item in cancelled_csv.split(",") if item]
print(json.dumps({
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "event": "shutdown_complete",
    "batch_id": batch_id,
    "cancelled_tasks": cancelled_tasks,
}))
PYEOF
}

handle_shutdown() {
  local signal="$1"
  local exit_code=143
  [ "$signal" = "SIGINT" ] && exit_code=130
  [ "$SHUTDOWN_IN_PROGRESS" = "true" ] && exit "$exit_code"
  SHUTDOWN_IN_PROGRESS=true

  trap - TERM INT
  set +e

  log_shutdown_requested "$signal" >> "$LOG_FILE"

  local -a cancelled_tasks=()
  local pid_file task_id pid waited pid_cmd in_batch spec batch_tid
  shopt -s nullglob
  for pid_file in "$PIDS_DIR"/*.pid; do
    [ -f "$pid_file" ] || continue
    task_id="$(basename "$pid_file" .pid)"
    if [ "${TASK_FILES+x}" = "x" ]; then
      in_batch=false
      for spec in "${TASK_FILES[@]}"; do
        batch_tid=$(parse_front "$spec" "id" "unknown")
        if [ "$batch_tid" = "$task_id" ]; then
          in_batch=true
          break
        fi
      done
      [ "$in_batch" = "true" ] || continue
    fi
    pid="$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      pid_cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      [[ "$pid_cmd" == *"agent.sh"* && "$pid_cmd" == *"$task_id"* ]] || { rm -f "$pid_file"; continue; }
      kill -TERM "$pid" 2>/dev/null || true
      waited=0
      while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
    : > "$RESULTS_DIR/${task_id}.cancelled"
    rm -f "$pid_file"
    cancelled_tasks+=("$task_id")
  done
  shopt -u nullglob

  local cancelled_csv=""
  if [ ${#cancelled_tasks[@]} -gt 0 ]; then
    cancelled_csv=$(IFS=,; echo "${cancelled_tasks[*]}")
  fi
  log_shutdown_complete "$cancelled_csv" >> "$LOG_FILE"

  exit "$exit_code"
}

trap 'handle_shutdown SIGTERM' TERM
trap 'handle_shutdown SIGINT' INT

FAILURE_MODE="skip-failed"
MAX_FAILURES=0
NOTIFY_ON_FAILURE=false
batch_failure_count=0
batch_abort=false
declare -a FAILED_TASK_SPECS=()

# Generate Trace ID: <batch-id>-<timestamp>-<random4chars>
TS_TAG=$(date +%Y%m%d-%H%M%S)
RND_TAG="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 4 || true)"
[ -n "$RND_TAG" ] || RND_TAG="rand"
export ORCH_TRACE_ID="${BATCH_ID}-${TS_TAG}-${RND_TAG}"
echo "[dispatch] trace_id=$ORCH_TRACE_ID"

# ── frontmatter parser (Python-based, robust) ────────────────────────────────
# Uses Python to parse YAML frontmatter reliably — handles quoted values,
# inline comments, multi-word values, and lists.

# Parse a single YAML frontmatter key. Returns default if key missing.
# Usage: parse_front <file> <key> [default]
parse_front() {
  local file="$1" key="$2" default="${3:-}"
  python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
m = re.match(r'^---\s*\n(.*?)\n---', text, re.DOTALL)
if not m:
    print(sys.argv[3], end='')
    sys.exit(0)
for line in m.group(1).splitlines():
    line = line.strip()
    if line.startswith(sys.argv[2] + ':'):
        val = line[len(sys.argv[2])+1:].strip()
        # Remove inline comments (but not inside quotes)
        if val and val[0] not in ('\"', \"'\", '['):
            val = re.sub(r'\s+#.*$', '', val)
        # Strip surrounding quotes
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ('\"', \"'\"):
            val = val[1:-1]
        print(val, end='')
        sys.exit(0)
print(sys.argv[3], end='')
" "$file" "$key" "$default"
}

# Extract prompt body (everything after second ---)
parse_body() {
  local file="$1"
  python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
m = re.match(r'^---\s*\n.*?\n---\s*\n?(.*)\Z', text, re.DOTALL)
if m:
    print(m.group(1).rstrip())
" "$file"
}

# Parse YAML list: context_from: [task-a, task-b] → "task-a task-b"
# Also handles bare values: context_from: task-a → "task-a"
parse_list() {
  local file="$1" key="$2"
  python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
m = re.match(r'^---\s*\n(.*?)\n---', text, re.DOTALL)
if not m:
    sys.exit(0)
for line in m.group(1).splitlines():
    line = line.strip()
    if line.startswith(sys.argv[2] + ':'):
        val = line[len(sys.argv[2])+1:].strip()
        # Strip inline comments for unquoted values
        if val and val[0] not in ('\"', \"'\"):
            val = re.sub(r'\s+#.*$', '', val).strip()
        # Handle [item1, item2] list syntax
        if val.startswith('[') and val.endswith(']'):
            items = val[1:-1].split(',')
        else:
            items = val.split(',')
        cleaned = [i.strip().strip('\"').strip(\"'\") for i in items if i.strip()]
        print(' '.join(cleaned), end='')
        sys.exit(0)
" "$file" "$key"
}

# ── consensus helpers (Phase 7.1b) ───────────────────────────────────────────
MODELS_YAML="${PROJECT_ROOT}/config/models.yaml"

is_consensus_type() {
 local task_type="$1"
 local enabled
 enabled=$(yq -r ".task_mapping.${task_type}.consensus // false" \
   "$MODELS_YAML" 2>/dev/null)
 [[ "$enabled" == "true" ]]
}

get_pick_strategy() {
 yq -r ".parallel_policy.pick_strategy // \"first_success\"" \
   "$MODELS_YAML" 2>/dev/null
}

get_parallel_candidates() {
 local task_type="$1" max_parallel
 max_parallel=$(yq -r ".parallel_policy.max_parallel // 3" "$MODELS_YAML")
 yq -r ".task_mapping.${task_type}.parallel[]" "$MODELS_YAML" 2>/dev/null \
   | head -n "$max_parallel"
}

escape_agent_filename() {
 local agent="$1"
 # Replace / only — dashes and dots are valid filename chars, keep them
 echo "${agent//\//_}"
}

load_batch_conf() {
  local conf_file="$1"
  local parsed_lines
  [ -f "$conf_file" ] || return 0

  parsed_lines="$(python3 - "$conf_file" <<'PYEOF'
import re
import sys

_, conf_path = sys.argv
allowed = {"failure_mode", "max_failures", "notify_on_failure"}
parsed = {}

with open(conf_path, "r", encoding="utf-8", errors="replace") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        if key not in allowed:
            continue
        value = value.strip()
        if value and value[0] not in ("'", '"'):
            value = re.sub(r"\s+#.*$", "", value).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1].strip()
        parsed[key] = value

for key in ("failure_mode", "max_failures", "notify_on_failure", "budget_tokens"):
    if key in parsed:
        print(f"{key}={parsed[key]}")
PYEOF
)"

  BUDGET_TOKENS=0
  while IFS='=' read -r key value; do
    [ -z "${key:-}" ] && continue
    case "$key" in
      failure_mode) FAILURE_MODE="$value" ;;
      max_failures) MAX_FAILURES="$value" ;;
      notify_on_failure) NOTIFY_ON_FAILURE="$value" ;;
      budget_tokens) BUDGET_TOKENS="$value" ;;
    esac
  done <<EOF
$parsed_lines
EOF

  case "$FAILURE_MODE" in
    fail-fast|skip-failed|retry-failed) ;;
    *) FAILURE_MODE="skip-failed" ;;
  esac

  if ! [[ "$MAX_FAILURES" =~ ^[0-9]+$ ]]; then
    MAX_FAILURES=0
  fi

  NOTIFY_ON_FAILURE=$(printf '%s' "$NOTIFY_ON_FAILURE" | tr '[:upper:]' '[:lower:]')
  case "$NOTIFY_ON_FAILURE" in
    true|1|yes|on) NOTIFY_ON_FAILURE=true ;;
    *) NOTIFY_ON_FAILURE=false ;;
  esac
}

is_failed_spec() {
  local spec="$1"
  local failed_spec
  for failed_spec in "${FAILED_TASK_SPECS[@]:-}"; do
    [ -z "$failed_spec" ] && continue
    [ "$failed_spec" = "$spec" ] && return 0
  done
  return 1
}

record_failed_spec() {
  local spec="$1"
  is_failed_spec "$spec" && return 0
  FAILED_TASK_SPECS+=("$spec")
}

handle_task_failure() {
  local tid="$1" spec="$2"
  batch_failure_count=$((batch_failure_count + 1))
  record_failed_spec "$spec"

  [ "$NOTIFY_ON_FAILURE" = "true" ] && \
    echo "[dispatch] NOTICE: task failure recorded for $tid (count=$batch_failure_count)"

  if [ "$MAX_FAILURES" -gt 0 ] && [ "$batch_failure_count" -ge "$MAX_FAILURES" ]; then
    echo "[dispatch] MAX FAILURES ($MAX_FAILURES) REACHED — aborting"
    batch_abort=true
    return 0
  fi

  case "$FAILURE_MODE" in
    fail-fast)
      echo "[dispatch] FAIL-FAST: $tid failed — aborting remaining tasks"
      batch_abort=true
      ;;
    skip-failed)
      echo "[dispatch] SKIP: $tid failed — continuing with remaining tasks"
      ;;
  esac
}

mark_remaining_skipped() {
  local spec tid
  for spec in "${TASK_FILES[@]}"; do
    tid=$(parse_front "$spec" "id" "unknown")
    if [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ]; then
      continue
    fi
    [ -f "$RESULTS_DIR/${tid}.skipped" ] && continue
    [ -f "$RESULTS_DIR/${tid}.skipped.abort" ] && continue
    is_failed_spec "$spec" && continue
    : > "$RESULTS_DIR/${tid}.skipped.abort"
  done
}

# ── status display ────────────────────────────────────────────────────────────
show_status() {
  echo "=== Batch: $BATCH_ID ==="
  local total=0 done_count=0 failed=0 pending=0
  for spec in "$BATCH_DIR"/task-*.md; do
    [ -f "$spec" ] || continue
    total=$((total + 1))
    local tid
    tid=$(parse_front "$spec" "id" "unknown")
    local agent
    agent=$(parse_front "$spec" "agent" "?")
    if [ -f "$RESULTS_DIR/${tid}.out" ]; then
      local size
      size=$(wc -c < "$RESULTS_DIR/${tid}.out" | tr -d ' ')
      if [ "$size" -gt 50 ]; then
        echo "  ✅ $tid ($agent) — ${size} bytes"
        done_count=$((done_count + 1))
      else
        echo "  ❌ $tid ($agent) — ${size} bytes (likely failed)"
        failed=$((failed + 1))
      fi
    else
      echo "  ⏳ $tid ($agent) — pending"
      pending=$((pending + 1))
    fi
  done
  echo "--- Total: $total | Done: $done_count | Failed: $failed | Pending: $pending ---"
}

if [ "$MODE" = "--status" ]; then
  show_status
  exit 0
fi

load_batch_conf "$BATCH_CONF"
echo "[dispatch] failure_mode=$FAILURE_MODE max_failures=$MAX_FAILURES notify_on_failure=$NOTIFY_ON_FAILURE"

# ── collect and sort tasks by priority ─────────────────────────────────────────
declare -a TASK_FILES_HIGH=()
declare -a TASK_FILES_NORMAL=()
declare -a TASK_FILES_LOW=()

for spec in "$BATCH_DIR"/task-*.md; do
  [ -f "$spec" ] || continue
  prio=$(parse_front "$spec" "priority" "normal")
  case "$prio" in
    high)   TASK_FILES_HIGH+=("$spec") ;;
    low)    TASK_FILES_LOW+=("$spec") ;;
    *)      TASK_FILES_NORMAL+=("$spec") ;;
  esac
done

# Merge: high first, then normal, then low (safe empty-array expansion for set -u)
declare -a TASK_FILES=(
  ${TASK_FILES_HIGH[@]+"${TASK_FILES_HIGH[@]}"}
  ${TASK_FILES_NORMAL[@]+"${TASK_FILES_NORMAL[@]}"}
  ${TASK_FILES_LOW[@]+"${TASK_FILES_LOW[@]}"}
)

if [ ${#TASK_FILES[@]} -eq 0 ]; then
  echo "[dispatch] no task-*.md files found in $BATCH_DIR" >&2
  exit 1
fi

# ── deadline check ────────────────────────────────────────────────────────────
for spec in "${TASK_FILES[@]}"; do
  dl=$(parse_front "$spec" "deadline" "")
  if [ -n "$dl" ]; then
    dl_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$dl" +%s 2>/dev/null || date -d "$dl" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    if [ "$dl_epoch" -gt 0 ] && [ "$now_epoch" -gt "$dl_epoch" ]; then
      tid=$(parse_front "$spec" "id" "?")
      echo "[dispatch] ⚠️  OVERDUE: $tid deadline was $dl"
    fi
  fi
done

echo "[dispatch] batch=$BATCH_ID tasks=${#TASK_FILES[@]} mode=$MODE priority_order=[${#TASK_FILES_HIGH[@]}H/${#TASK_FILES_NORMAL[@]}N/${#TASK_FILES_LOW[@]}L]"

# Clear per-run skip markers for current batch tasks.
for spec in "${TASK_FILES[@]}"; do
  tid=$(parse_front "$spec" "id" "unknown")
  rm -f "$RESULTS_DIR/${tid}.skipped"
  rm -f "$RESULTS_DIR/${tid}.skipped.abort"
done

# ── circular dependency detection (DFS) ──────────────────────────────────
# Detects cycles in depends_on graph BEFORE dispatching. Exits with error if found.
check_cycles() {
  python3 - "${TASK_FILES[@]}" <<'PYEOF'
import sys, re

# Build adjacency list: task_id -> [dependency_ids]
graph = {}
for filepath in sys.argv[1:]:
    with open(filepath) as f:
        text = f.read()
    m = re.match(r'^---\s*\n(.*?)\n---', text, re.DOTALL)
    tid, deps = "unknown", []
    if m:
        for line in m.group(1).splitlines():
            line = line.strip()
            if line.startswith('id:'):
                tid = line[3:].strip().strip('"').strip("'")
            elif line.startswith('depends_on:'):
                val = line[11:].strip()
                if val.startswith('[') and val.endswith(']'):
                    val = val[1:-1]
                deps = [i.strip().strip('"').strip("'") for i in val.split(',') if i.strip()]
    graph[tid] = deps

# DFS: WHITE=unvisited, GRAY=in-stack, BLACK=done
WHITE, GRAY, BLACK = 0, 1, 2
color = {t: WHITE for t in graph}

def dfs(node, path):
    color[node] = GRAY
    for dep in graph.get(node, []):
        if dep not in color:
            continue  # dependency outside this batch
        if color[dep] == GRAY:
            cycle = path + [node, dep]
            idx = cycle.index(dep)
            print(f"CYCLE: {' -> '.join(cycle[idx:])}", file=sys.stderr)
            return True
        if color[dep] == WHITE and dfs(dep, path + [node]):
            return True
    color[node] = BLACK
    return False

found = any(dfs(t, []) for t in graph if color[t] == WHITE)
sys.exit(1 if found else 0)
PYEOF
}

if ! check_cycles; then
  echo "[dispatch] FATAL: circular dependency detected in batch $BATCH_ID — aborting" >&2
  exit 1
fi

# ── dependency resolver ───────────────────────────────────────────────────────
# Returns 0 if all dependencies are satisfied (result files exist and non-empty)
deps_satisfied() {
  local spec="$1"
  local deps
  deps=$(parse_list "$spec" "depends_on")
  for dep in $deps; do
    [ -z "$dep" ] && continue
    if [ ! -f "$RESULTS_DIR/${dep}.out" ] || [ ! -s "$RESULTS_DIR/${dep}.out" ]; then
      return 1
    fi
  done
  return 0
}

# ── health gate ────────────────────────────────────────────────────────────────
check_agent_health() {
  local tid="$1" agent="$2" allow_force_retry="${3:-true}"
  # --retry-skipped bypasses health gate to force previously-skipped tasks to run
  if [ "$allow_force_retry" = "true" ] && [ "$FORCE_RETRY" = "true" ]; then
    return 0
  fi
  [ -f "$HEALTH_BEACON_SH" ] || return 0

  local health_rc=0
  if "$HEALTH_BEACON_SH" --check "$agent" >/dev/null 2>&1; then
    health_rc=0
  else
    health_rc=$?
  fi

  case "$health_rc" in
    0) return 0 ;;
    1)
      echo "[dispatch] WARN: agent $agent is DEGRADED"
      return 0
      ;;
    2)
      echo "[dispatch] SKIP $tid — agent $agent is DOWN"
      return 2
      ;;
    *)
      return 0
      ;;
  esac
}

# ── SLO breach notification ───────────────────────────────────────────────────
check_slo_breach() {
  local tid="$1" agent="$2" duration="$3" status="$4" spec="$5"
  local slo
  slo=$(parse_front "$spec" "slo_duration_s" "0" 2>/dev/null || echo 0)
  [[ "$slo" =~ ^[0-9]+$ ]] || return 0
  [ "$slo" -le 0 ] && return 0
  [ "$duration" -le "$slo" ] && return 0
  local ratio
  ratio=$(python3 -c "print(round($duration/$slo,2))" 2>/dev/null || echo "0")
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'batch_id':sys.argv[1],'task_id':sys.argv[2],'agent':sys.argv[3],'slo_duration_s':int(sys.argv[4]),'actual_duration_s':int(sys.argv[5]),'breach_ratio':float(sys.argv[6]),'status':sys.argv[7]}))" \
    "${BATCH_ID:-}" "$tid" "$agent" "$slo" "$duration" "$ratio" "$status" 2>/dev/null || echo '{}')
  notify_event "slo_breach" "$payload"
}

# ── structured completion report ───────────────────────────────────────────────
# Generates a JSON report from task spec + output metadata
generate_report() {
  local spec="$1" tid="$2" status="$3" out_size="$4" duration_s="$5" runtime_agent="${6:-}"
  local agent priority deadline output_format
  agent="$runtime_agent"
  [ -n "$agent" ] || agent=$(parse_front "$spec" "agent" "unknown")
  priority=$(parse_front "$spec" "priority" "normal")
  deadline=$(parse_front "$spec" "deadline" "")
  output_format=$(parse_front "$spec" "output_format" "markdown")

  # Count output lines and extract first heading as summary
  local summary="" out_lines=0
  if [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ]; then
    out_lines=$(wc -l < "$RESULTS_DIR/${tid}.out" | tr -d ' ')
    summary=$(grep -m1 '^#\|^[A-Z]' "$RESULTS_DIR/${tid}.out" | head -c 200 || echo "")
  fi

  # Check for revisions
  local rev_count=0
  for rf in "$RESULTS_DIR/${tid}".v*.out; do
    [ -f "$rf" ] && rev_count=$((rev_count + 1))
  done

  python3 - "$tid" "$agent" "$status" "$out_size" "$out_lines" "$priority" "$deadline" "$output_format" "$summary" "$rev_count" "$duration_s" <<'PYEOF' > "$RESULTS_DIR/${tid}.report.json"
import sys, json, datetime
_, tid, agent, status, out_size, out_lines, priority, deadline, output_format, summary, rev_count, duration_s = sys.argv
print(json.dumps({
    "type": "task_completion_report",
    "task_id": tid,
    "agent": agent,
    "status": status,
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "priority": priority,
    "deadline": deadline or None,
    "output_format": output_format,
    "duration_s": int(duration_s),
    "deliverables": {
        "output_file": f"results/{tid}.out",
        "output_bytes": int(out_size),
        "output_lines": int(out_lines),
        "summary": summary,
    },
    "revisions": int(rev_count),
    "next_suggested_tasks": [],
}, indent=2))
PYEOF

  # State sync to memory-bank
  python3 - "$tid" "$status" "$agent" "$duration_s" "$summary" <<'PYEOF'
import sys, json, os, datetime
_, tid, status, agent, duration_s, summary = sys.argv
storage_dir = os.environ.get("STORAGE_DIR", os.path.expanduser("~/.memory-bank-storage"))
task_path = os.path.join(storage_dir, "tasks", f"{tid}.json")
if os.path.exists(task_path):
    try:
        with open(task_path, "r") as f:
            data = json.load(f)

        mb_status = "done" if status == "success" else "blocked" if status == "failed" else "in_progress"
        data["status"] = mb_status
        data["assigned_to"] = agent

        if "_meta" not in data:
            data["_meta"] = {}
        data["_meta"]["updated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        tmp_path = task_path + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp_path, task_path)
    except Exception:
        pass
PYEOF
}

move_to_dlq() {
  local spec="$1" tid="$2" agent="$3" retries="$4"
  local dlq_spec="$DLQ_DIR/${tid}.spec.md"
  local dlq_error="$DLQ_DIR/${tid}.error.log"
  local dlq_meta="$DLQ_DIR/${tid}.meta.json"
  local task_log="$RESULTS_DIR/${tid}.log"

  if ! [[ "$tid" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[dispatch] invalid task id for DLQ: $tid" >&2
    return 1
  fi

  mkdir -p "$DLQ_DIR"
  cp "$spec" "$dlq_spec"
  if [ -f "$task_log" ]; then
    cp "$task_log" "$dlq_error"
  else
    : > "$dlq_error"
  fi

  python3 - "$tid" "$BATCH_ID" "$agent" "$retries" "$spec" "$dlq_error" <<'PYEOF' > "$dlq_meta"
import datetime
import json
import sys

_, task_id, batch_id, agent, retries_raw, original_spec, error_log = sys.argv
try:
    retries = int(retries_raw)
except ValueError:
    retries = 0

error_summary = ""
with open(error_log, "r", encoding="utf-8", errors="replace") as f:
    error_summary = f.read(200)

print(json.dumps({
    "task_id": task_id,
    "batch_id": batch_id,
    "agent": agent,
    "failed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "attempt_count": retries + 1,
    "error_summary": error_summary,
    "original_spec": original_spec,
}, indent=2))
PYEOF

  echo "[dispatch] → DLQ: $tid moved to .orchestration/dlq/"
}

# ── reviewer pipeline ────────────────────────────────────────────────────────
# After main agent completes, run reviewer (e.g. copilot) to apply + review output.
# Writes to: results/<tid>.review.out
run_reviewer() {
  local spec="$1" tid="$2"
  local reviewer reviewer_timeout
  reviewer=$(parse_front "$spec" "reviewer" "")
  reviewer_timeout=$(parse_front "$spec" "timeout" "120")
  [ -z "$reviewer" ] && return 0
  check_agent_health "$tid" "$reviewer" || return 0

  local main_out="$RESULTS_DIR/${tid}.out"
  if [ ! -f "$main_out" ] || [ ! -s "$main_out" ]; then
    echo "[dispatch] skip reviewer for $tid — no output to review"
    return 0
  fi

  local original_task
  original_task=$(parse_body "$spec")

  # Build review+apply prompt for copilot
  local review_prompt
  review_prompt="You are a senior code reviewer applying and reviewing AI-generated code.

ORIGINAL TASK:
${original_task}

GENERATED IMPLEMENTATION:
$(cat "$main_out")

Your job:
1. Apply ALL code changes shown above to the relevant files in this project directory.
   Use --allow-all. Write the files exactly as specified.
2. If the implementation references a file path — write to that path.
   If no path is specified — infer the correct file from context.
3. After applying, review for: correctness, edge cases, code style, security.
4. Report back: which files were changed, what was applied, any issues or improvements made.

Apply the changes now."

  echo "[dispatch] running reviewer $reviewer for $tid"
  if "$SCRIPT_DIR/agent.sh" "$reviewer" "${tid}-review" "$review_prompt" "$reviewer_timeout" "1" \
      > "$RESULTS_DIR/${tid}.review.out" 2>> "$RESULTS_DIR/${tid}.log"; then
    local review_size
    review_size=$(wc -c < "$RESULTS_DIR/${tid}.review.out" | tr -d ' ')
    echo "[dispatch] ✅ review+apply complete for $tid (${review_size} bytes)"
  else
    echo "[dispatch] ⚠️  reviewer failed for $tid — check ${tid}.log"
  fi
}

# ── consensus fan-out dispatch (Phase 7.1b) ───────────────────────────────────
dispatch_task_consensus() {
 local spec="$1"
 local task_type="$2"

 local tid candidates_dir candidate_agent pid_map
 local -A pid_to_agent
 local -A agent_exit
 local -A agent_output
 local -A agent_duration

 local start_ts end_ts elapsed pid exit_code out_size safe_name
 local successful_count=0 winner_output winner_agent=""

 tid=$(parse_front "$spec" "id" "unknown")
 candidates_dir="$RESULTS_DIR/${tid}.candidates"
 mkdir -p "$candidates_dir"

 # Build list of parallel candidates (capped at max_parallel)
 local -a candidates_list=()
 while IFS= read -r candidate_agent; do
   [ -n "$candidate_agent" ] && candidates_list+=("$candidate_agent")
 done < <(get_parallel_candidates "$task_type")

 if [ ${#candidates_list[@]} -eq 0 ]; then
   echo "[consensus] WARN: no parallel candidates for $task_type — falling back to first_success" >&2
   return 1
 fi

 # Cache timeout once — used in launch loop and wait logic
 local timeout_per_model
 timeout_per_model=$(yq -r ".parallel_policy.timeout_per_model_sec // 120" "$MODELS_YAML" 2>/dev/null)

 echo "[consensus] $tid → fan-out to ${#candidates_list[@]} candidates: ${candidates_list[*]}"

 # Launch all candidates in background
 local -a pids=()
 for candidate_agent in "${candidates_list[@]}"; do
   safe_name=$(escape_agent_filename "$candidate_agent")
   local out_file="$candidates_dir/${safe_name}.out"
   local err_file="$candidates_dir/${safe_name}.err"

   # Source the prompt
   local prompt
   prompt=$(parse_body "$spec")

   # agent_cmd supports AGENT_SH_MOCK override for testing
   local agent_cmd="${AGENT_SH_MOCK:-$SCRIPT_DIR/agent.sh}"

   echo "[consensus] launch $candidate_agent for $tid (timeout=${timeout_per_model}s)"

   # Wrap in subshell so we can capture exit code reliably
   (
     "$agent_cmd" "$candidate_agent" "$tid" "$prompt" "$timeout_per_model" "1" \
       > "$out_file" 2>> "$err_file"
     echo $? > "$out_file.exit"
   ) &
   local job_pid=$!
   pids+=("$job_pid")
   pid_to_agent["$job_pid"]="$candidate_agent"
   echo "$job_pid" > "$PIDS_DIR/${tid}-${candidate_agent//\//_}.pid"
 done

 # Wait for all with deadline timeout
 start_ts=$(date +%s)
 local deadline=$((start_ts + timeout_per_model))
 local -a active_pids=("${pids[@]}")
 local remaining=${#active_pids[@]}

 while [ "$remaining" -gt 0 ]; do
   local wait_pid ret
   wait_pid=$(wait -n 2>/dev/null)
   ret=$?
   if [ "$ret" -eq 0 ] || [ "$ret" -eq 1 ]; then
     :
   elif [ "$ret" -eq 127 ]; then
     # wait -n not available — fall back to polling
     for wp in "${active_pids[@]}"; do
       [ -z "$wp" ] && continue
       if kill -0 "$wp" 2>/dev/null; then
         sleep 0.5
         continue
       fi
     done
     break
   fi

   # Check deadline and kill remaining if expired
   local now
   now=$(date +%s)
   if [ "$now" -ge "$deadline" ]; then
     for wp in "${active_pids[@]}"; do
       [ -z "$wp" ] && continue
       if kill -0 "$wp" 2>/dev/null; then
         kill "$wp" 2>/dev/null || true
       fi
     done
     break
   fi

   # Remove completed jobs from active set
   local -a new_active=()
   for wp in "${active_pids[@]}"; do
     [ -z "$wp" ] && continue
     if kill -0 "$wp" 2>/dev/null; then
       new_active+=("$wp")
     fi
   done
   active_pids=("${new_active[@]}")
   remaining=${#active_pids[@]}
 done

 # Collect remaining (deadline-killed or slow) jobs
 for wp in "${active_pids[@]}"; do
   [ -z "$wp" ] && continue
   if kill -0 "$wp" 2>/dev/null; then
     local waited=0
     while kill -0 "$wp" 2>/dev/null && [ "$waited" -lt 10 ]; do
       sleep 1
       waited=$((waited + 1))
     done
     if kill -0 "$wp" 2>/dev/null; then
       kill -TERM "$wp" 2>/dev/null || true
       sleep 1
       kill -KILL "$wp" 2>/dev/null || true
     fi
   fi
   wait "$wp" 2>/dev/null || true
 done

 # Collect results — gather stats for all candidates
 local -a candidate_rows=()
 for candidate_agent in "${candidates_list[@]}"; do
   safe_name=$(escape_agent_filename "$candidate_agent")
   local out_file="$candidates_dir/${safe_name}.out"
   local err_file="$candidates_dir/${safe_name}.err"

   # Read exit code from the .exit file written by the subshell wrapper
   exit_code=0
   if [ -f "$out_file.exit" ]; then
     exit_code=$(cat "$out_file.exit" 2>/dev/null || echo 0)
     [ -z "$exit_code" ] && exit_code=0
   fi

   out_size=0
   if [ -f "$out_file" ] && [ -s "$out_file" ]; then
     out_size=$(wc -c < "$out_file" | tr -d ' ')
   fi

   # Duration estimation
   local duration_s=0
   if [ -f "$err_file" ]; then
     local first_line
     first_line=$(head -1 "$err_file" 2>/dev/null || echo "")
     if echo "$first_line" | grep -qE '[0-9]+(\.[0-9]+)?s$'; then
       duration_s=$(echo "$first_line" | sed 's/[^0-9.]//g' || echo "0")
     fi
   fi

   # Record per-candidate data
   agent_output["$candidate_agent"]="$(cat "$out_file" 2>/dev/null || echo "")"
   agent_exit["$candidate_agent"]="$exit_code"
   agent_duration["$candidate_agent"]="${duration_s:-0}"

   # Build candidate row for consensus.json
   local chars_val="$out_size"
   local exit_val="$exit_code"
   local dur_val="${duration_s:-0}"
   candidate_rows+=("{\"agent\":\"$candidate_agent\",\"chars\":$chars_val,\"exit_code\":$exit_val,\"duration_s\":$dur_val}")

   echo "[consensus] $candidate_agent → exit=$exit_code chars=$out_size"

   rm -f "$PIDS_DIR/${tid}-${candidate_agent//\//_}.pid"
 done

 # Count successful candidates (exit 0 AND non-empty output)
 local -a successful_candidates=()
 for candidate_agent in "${candidates_list[@]}"; do
   local ec="${agent_exit[$candidate_agent]}"
   local out="${agent_output[$candidate_agent]}"
   if [ "$ec" -eq 0 ] && [ -n "$out" ]; then
     successful_candidates+=("$candidate_agent")
     successful_count=$((successful_count + 1))
   fi
 done

 echo "[consensus] $tid → $successful_count/${#candidates_list[@]} successful"

 # Failure mode: no candidates succeeded → reflexion if iterations remain
 if [ "$successful_count" -eq 0 ]; then
   local iter
   iter=$(consensus_iteration_count "$tid")
   if [ "$iter" -lt 2 ]; then
     echo "[consensus] $tid → FAIL (no survivors), triggering reflexion v$((iter+1))"
     trigger_reflexion "$tid" "no_survivors" "all candidates failed"
     redispatch_consensus "$spec" "$task_type" "$((iter+1))"
     return $?
   else
     echo "[consensus] $tid → EXHAUSTED after 2 reflexion attempts"
     : > "$RESULTS_DIR/${tid}.failed"
     write_consensus_json_exhausted "$tid" "$task_type" 0 0.0
     return 1
   fi
 fi

 # Single candidate success: verbatim copy (no merge needed)
 if [ "$successful_count" -eq 1 ]; then
   winner_agent="${successful_candidates[0]}"
   winner_output="${agent_output[$winner_agent]}"
   echo "[consensus] $tid → single winner: $winner_agent (${#winner_output} chars)"

   printf '%s' "$winner_output" > "$RESULTS_DIR/${tid}.out"

   # Encode arrays as JSON strings for safe Python arg passing
   local _candidates_json _rows_json
   _candidates_json=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" \
     "${candidates_list[@]}" 2>/dev/null || echo "[]")
   _rows_json=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" \
     "${candidate_rows[@]}" 2>/dev/null || echo "[]")

   # Write consensus.json for single-winner case — score 0.0 (no pairwise comparison)
   python3 - "$tid" "$task_type" "$successful_count" "$winner_agent" \
     "$_candidates_json" "$_rows_json" "0.0" <<'PYEOF' > "$RESULTS_DIR/${tid}.consensus.json"
import sys, json, datetime
_, tid, task_type, successful_count, winner_agent, candidates_json, rows_json, consensus_score_str = sys.argv
consensus_score = float(consensus_score_str)
candidates = json.loads(candidates_json) if candidates_json else []
rows = []
for r in json.loads(rows_json) if rows_json else []:
    try:
        rows.append(json.loads(r))
    except Exception:
        rows.append(r)
print(json.dumps({
    "task_id": tid,
    "task_type": task_type,
    "candidates": candidates,
    "candidates_detail": rows,
    "successful_count": int(successful_count),
    "winner_agent": winner_agent,
    "consensus_score": consensus_score,
    "strategy_used": "consensus",
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, indent=2))
PYEOF

   return 0
 fi

 # Multiple candidates: invoke consensus_merge
 echo "[consensus] $tid → $successful_count candidates → consensus_merge"

 # Read sim_threshold from models.yaml and export for consensus_merge
 local sim_threshold
 sim_threshold=$(yq -r ".parallel_policy.sim_threshold // 0.3" "$MODELS_YAML" 2>/dev/null)
 export SIM_THRESHOLD="$sim_threshold"
 echo "[consensus] $tid → SIM_THRESHOLD=$SIM_THRESHOLD"

 # Build candidates JSON for consensus_merge
 local candidates_json="["
 local first=true
 for cand in "${successful_candidates[@]}"; do
   local out escaped_out
   out="${agent_output[$cand]}"
   # Escape double-quotes and newlines for JSON
   escaped_out=$(printf '%s' "$out" | python3 -c "
import sys, json
print(json.dumps(sys.stdin.read()))
" 2>/dev/null || echo '\"\"')
   if [ "$first" = "true" ]; then
     candidates_json="${candidates_json}{\"agent_id\":\"$cand\",\"output\":${escaped_out},\"confidence\":1.0}"
     first=false
   else
     candidates_json="${candidates_json},{\"agent_id\":\"$cand\",\"output\":${escaped_out},\"confidence\":1.0}"
   fi
 done
 candidates_json="${candidates_json}]"

 # Call consensus_merge (from consensus-vote.sh)
 local merge_result
 merge_result=$(consensus_merge "$candidates_json" 2>/dev/null || printf '0.0\n')
 local computed_score merged_output
 computed_score=$(echo "$merge_result" | head -n 1)
 merged_output=$(echo "$merge_result" | tail -n +2)

 if [ -z "$merged_output" ]; then
   # Fallback: first successful candidate
   echo "[consensus] WARN: consensus_merge returned empty — using first successful" >&2
   winner_agent="${successful_candidates[0]}"
   merged_output="${agent_output[$winner_agent]}"
 else
   winner_agent="merged"
 fi

 # Reflexion trigger: 2+ candidates but total disagreement (score=0)
 if [ "$successful_count" -ge 2 ] && [ "$computed_score" = "0.000" ]; then
   local iter
   iter=$(consensus_iteration_count "$tid")
   if [ "$iter" -lt 2 ]; then
     echo "[consensus] $tid → FAIL (disagreement, score=0), triggering reflexion v$((iter+1))"
     trigger_reflexion "$tid" "disagreement" "candidates produced no overlapping vocabulary"
     redispatch_consensus "$spec" "$task_type" "$((iter+1))"
     return $?
   else
     echo "[consensus] $tid → EXHAUSTED after 2 attempts, best effort"
     # Best-effort: write the longest candidate from the last round so
     # downstream consumers have output to work with. The `.exhausted`
     # marker signals "consensus not reached" — consumers should check
     # the marker to decide whether to trust the output or escalate.
     printf '%s' "$merged_output" > "$RESULTS_DIR/${tid}.out"
     : > "$RESULTS_DIR/${tid}.exhausted"
     write_consensus_json_exhausted "$tid" "$task_type" "$successful_count" "$computed_score"
     return 0
   fi
 fi

 printf '%s' "$merged_output" > "$RESULTS_DIR/${tid}.out"

  # Encode arrays as JSON strings for safe Python arg passing
  local _candidates_json2 _rows_json2
  _candidates_json2=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" \
    "${candidates_list[@]}" 2>/dev/null || echo "[]")
  _rows_json2=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" \
    "${candidate_rows[@]}" 2>/dev/null || echo "[]")

  # Write consensus.json — use computed_score from consensus_merge
  python3 - "$tid" "$task_type" "$successful_count" "$winner_agent" \
    "$_candidates_json2" "$_rows_json2" "$computed_score" <<'PYEOF' > "$RESULTS_DIR/${tid}.consensus.json"
import sys, json, datetime
_, tid, task_type, successful_count, winner_agent, candidates_json, rows_json, consensus_score_str = sys.argv
consensus_score = float(consensus_score_str)
candidates = json.loads(candidates_json) if candidates_json else []
rows = []
for r in json.loads(rows_json) if rows_json else []:
    try:
        rows.append(json.loads(r))
    except Exception:
        rows.append(r)
print(json.dumps({
    "task_id": tid,
    "task_type": task_type,
    "candidates": candidates,
    "candidates_detail": rows,
    "successful_count": int(successful_count),
    "winner_agent": winner_agent,
    "consensus_score": consensus_score,
    "strategy_used": "consensus",
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, indent=2))
PYEOF

 local result_size
 result_size=$(wc -c < "$RESULTS_DIR/${tid}.out" | tr -d ' ')
 echo "[consensus] $tid → DONE (merged output: ${result_size} bytes, winner=$winner_agent)"

 return 0
}

# ── reflexion helpers for consensus loop (Phase 7.1d) ──────────────────────────

# Count existing vN.reflexion.json files for a task
consensus_iteration_count() {
 local tid="$1"
 find "$REFLEXION_DIR" -name "${tid}.v*.reflexion.json" 2>/dev/null | wc -l | tr -d ' '
}

# Build a re-dispatch prompt with peer outputs as context
build_revision_prompt() {
 local tid="$1" original_body="$2" iteration="$3"
 local candidates_dir="$RESULTS_DIR/${tid}.candidates"

 local prompt="CONSENSUS REVISION (attempt $iteration of 2):"
 prompt+=$'\n'"Previous candidates disagreed. Review peer outputs below and produce"
 prompt+=$'\n'"a reconciled answer that addresses the common ground."
 prompt+=$'\n\n'

 for f in "$candidates_dir"/*.out; do
   [ -f "$f" ] || continue
   local agent_name head
   agent_name=$(basename "$f" .out)
   head=$(head -c 2000 "$f")
   prompt+="--- Peer output: $agent_name ---"$'\n'
   prompt+="$head"$'\n\n'
 done

 prompt+="--- Original task ---"$'\n'
 prompt+="$original_body"
 echo "$prompt"
}

# Write exhausted consensus JSON
write_consensus_json_exhausted() {
 local tid="$1" task_type="$2" count="$3" score="$4"
 python3 - "$tid" "$task_type" "$count" "$score" <<'PYEOF' > "$RESULTS_DIR/${tid}.consensus.json"
import sys, json, datetime
_, tid, task_type, count, score = sys.argv
print(json.dumps({
  "task_id": tid,
  "task_type": task_type,
  "successful_count": int(count),
  "consensus_score": float(score),
  "strategy_used": "consensus_exhausted",
  "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, indent=2))
PYEOF
}

# Re-dispatch with enriched prompt
redispatch_consensus() {
 local spec="$1" task_type="$2" iteration="$3"
 local tid body revision_prompt revision_spec
 tid=$(parse_front "$spec" "id" "unknown")
 body=$(parse_body "$spec")

 revision_prompt=$(build_revision_prompt "$tid" "$body" "$iteration")

 revision_spec="$TASKS_DIR/${tid}.v${iteration}.revision.md"
 {
   echo "---"
   echo "id: $tid"
   echo "task_type: $task_type"
   echo "iteration: $iteration"
   echo "---"
   echo "$revision_prompt"
 } > "$revision_spec"

 echo "[consensus] re-dispatch $tid iteration $iteration"
 dispatch_task_consensus "$revision_spec" "$task_type"
}

# ── dispatch one task (router — Phase 7.1b) ────────────────────────────────────
dispatch_task() {
 local spec="$1"
 local agent_override="${2:-}"
 local task_type pick_strategy

 task_type=$(parse_front "$spec" "task_type" "")
 pick_strategy=$(get_pick_strategy)

 if [[ "$pick_strategy" == "consensus" ]] && [[ -n "$task_type" ]] && is_consensus_type "$task_type"; then
   dispatch_task_consensus "$spec" "$task_type"
 else
   dispatch_task_first_success "$spec" "$agent_override"
 fi
}

# ── dispatch one task (first_success path — renamed from original dispatch_task)
dispatch_task_first_success() {
  local spec="$1"
  local agent_override="${2:-}"
  local tid agent timeout retries prompt task_type prefer_cheap original_agent
  local actual_duration=0 task_start task_end task_rc=1 agent_pid=0 pid_file cancelled_marker
  local agents_front agent_candidates has_agents_list=false candidate_agent failover_position=0
  local circuit_breaker_sh health_rc=0

  tid=$(parse_front "$spec" "id" "unknown")
  pid_file="$PIDS_DIR/${tid}.pid"
  cancelled_marker="$RESULTS_DIR/${tid}.cancelled"
  agent=$(parse_front "$spec" "agent" "gemini")
  agents_front=$(parse_list "$spec" "agents")
  if [ -n "$agents_front" ]; then
    has_agents_list=true
    agent_candidates="$agents_front"
  else
    agent_candidates="$agent"
  fi
  if [ -n "$agent_override" ]; then
    if [ "$has_agents_list" = "true" ]; then
      local reordered_candidates="$agent_override"
      local chain_agent
      for chain_agent in $agents_front; do
        [ -z "$chain_agent" ] && continue
        [ "$chain_agent" = "$agent_override" ] && continue
        reordered_candidates="$reordered_candidates $chain_agent"
      done
      agent_candidates="$reordered_candidates"
    else
      agent_candidates="$agent_override"
    fi
  fi
  agent=$(printf '%s\n' "$agent_candidates" | awk '{print $1}')
  task_type=$(parse_front "$spec" "task_type" "")
  prefer_cheap=$(parse_front "$spec" "prefer_cheap" "false")
  prefer_cheap=$(printf '%s' "$prefer_cheap" | tr '[:upper:]' '[:lower:]')
  timeout=$(parse_front "$spec" "timeout" "120")
  retries=$(parse_front "$spec" "retries" "1")

  # ── Budget-Tiered Task Triage ─────────────────────────────────────────────
  if [ -x "$SCRIPT_DIR/classify-tokens.sh" ]; then
    local tier_output tokens_est intent_class task_tier routing_decision
    tier_output=$("$SCRIPT_DIR/classify-tokens.sh" "$spec" 2>/dev/null || true)
    if [ -n "$tier_output" ]; then
      task_tier=$(echo "$tier_output" | awk -F= '$1=="tier" {print $2}')
      tokens_est=$(echo "$tier_output" | awk -F= '$1=="tokens_estimated" {print $2}')
      intent_class=$(echo "$tier_output" | awk -F= '$1=="intent_clarity" {print $2}')
      routing_decision=$(echo "$tier_output" | awk -F= '$1=="reasoning" {print $2}')

      if [ -n "$task_tier" ]; then
        echo "[dispatch] event=tier_classification tid=$tid tier=$task_tier tokens=$tokens_est intent=$intent_class routing=$routing_decision"
        triage_log "$tid" "$task_tier" "$tokens_est" "$intent_class" "$routing_decision"

        # Override timeout based on tier if not explicitly set in task spec
        if [ -z "$(parse_front "$spec" "timeout" "")" ]; then
          local tier_timeout
          tier_timeout=$(triage_get_timeout "$task_tier")
          timeout="$tier_timeout"
        fi
      fi
    fi
  fi

  # ── capability check ───────────────────────────────────────────────────────
  local agents_json="$PROJECT_ROOT/.orchestration/agents.json"
  if [ -f "$agents_json" ]; then
    local check_agent
    for check_agent in $agent_candidates; do
      [ -z "$check_agent" ] && continue
      if ! "$SCRIPT_DIR/orch-agents.sh" --check "$check_agent" 2>/dev/null; then
        echo "[dispatch] ⚠️  WARN: unknown agent '$check_agent' — not in agents.json"
      fi
    done

    if [ -n "$task_type" ]; then
      local suggested
      suggested=$("$SCRIPT_DIR/orch-agents.sh" --suggest "$task_type" 2>/dev/null)
      if [ -n "$suggested" ] && [ "$suggested" != "$agent" ]; then
        echo "[dispatch] 💡 TIP: task_type '$task_type' is better suited for agent '$suggested' (current: $agent)"
      fi
    fi
  fi

  if [ "$prefer_cheap" = "true" ] && [ -n "$task_type" ] && [ "$has_agents_list" = "false" ] && [ -z "$agent_override" ]; then
    local cheapest_agent
    cheapest_agent=$("$SCRIPT_DIR/agent-cost.sh" cheapest "$task_type" 2>/dev/null || true)
    if [ -n "$cheapest_agent" ]; then
      original_agent="$agent"
      agent="$cheapest_agent"
      agent_candidates="$agent"
      echo "[dispatch] event=cost_routing original_agent=$original_agent selected_agent=$agent reason=prefer_cheap"
    fi
  fi

  # Skip if already completed
  if [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ] && [ ! -f "$cancelled_marker" ]; then
    echo "[dispatch] skip $tid — already has result"
    rm -f "$pid_file"
    return 0
  fi

  # Check dependencies
  if ! deps_satisfied "$spec"; then
    echo "[dispatch] skip $tid — dependencies not yet satisfied"
    rm -f "$pid_file"
    return 1
  fi

  # Build prompt from body
  prompt=$(parse_body "$spec")
  circuit_breaker_sh="$SCRIPT_DIR/circuit-breaker.sh"

  # Inject cached context (project-overview, file-tree, architecture, tech-stack)
  local cache_keys
  cache_keys=$(parse_list "$spec" "context_cache")
  if [ -n "$cache_keys" ]; then
    local cache_dir="$PROJECT_ROOT/.orchestration/context-cache"
    local cache_block=""
    for ck in $cache_keys; do
      [ -z "$ck" ] && continue
      local cache_file="$cache_dir/${ck}.md"
      if [ -f "$cache_file" ]; then
        cache_block="${cache_block}$(cat "$cache_file")
"
      else
        echo "[dispatch] ⚠️  cache miss: $ck (run: context-cache.sh generate $ck)" >&2
      fi
    done
    if [ -n "$cache_block" ]; then
      prompt="${cache_block}
---

${prompt}"
    fi
  fi

  # Inject context from prior tasks
  local ctx_tasks ctx_block=""
  # Auto-Context-Resolver: merge context_from AND depends_on
  local explicit_ctx deps_ctx
  explicit_ctx=$(parse_list "$spec" "context_from")
  deps_ctx=$(parse_list "$spec" "depends_on")
  # Dedup and merge
  ctx_tasks=$(echo -e "${explicit_ctx}\n${deps_ctx}" | tr ' ' '\n' | sort -u | grep -v '^$')

  # ctx_block already initialized at line 888 (ctx_tasks ctx_block="") — always defined for compression check below
  if [ -n "$ctx_tasks" ]; then
    for ctx_id in $ctx_tasks; do
      [ -z "$ctx_id" ] && continue
      local ctx_file="$RESULTS_DIR/${ctx_id}.out"
      if [ -f "$ctx_file" ]; then
        # Context Distillation check: if output contains a compressed context section, extract it.
        # Otherwise use the full output.
        local compressed
        compressed=$(awk '/---COMPRESSED-CONTEXT---/{flag=1; next} /---END-COMPRESSED-CONTEXT---/{flag=0} flag' "$ctx_file" 2>/dev/null)

        if [ -n "$compressed" ]; then
          ctx_block="${ctx_block}--- Context from ${ctx_id} (Compressed) ---
${compressed}
--- End context ---

"
        else
          # Fallback to full output if no compression section
          ctx_block="${ctx_block}--- Context from ${ctx_id} ---
$(cat "$ctx_file")
--- End context ---

"
        fi
      fi
    done
    if [ -n "$ctx_block" ]; then
      prompt="${ctx_block}${prompt}"
    fi
  fi

  # ── Context compression check (Phase 6.3) ──────────────────────────────────
  # If context_budget_threshold is set and prior artifacts > 50k tokens, compress
  if declare -f compress_session > /dev/null 2>&1; then
    local ctx_size
    ctx_size=$(echo "$ctx_block" | wc -c 2>/dev/null || echo "0")
    local ctx_tokens=$((ctx_size / 4))
    local threshold_tokens
    threshold_tokens="${CONTEXT_BUDGET_THRESHOLD:-50000}"
    if [ "$ctx_tokens" -gt "$threshold_tokens" ]; then
      echo "[dispatch] 📦 context-compressor: $ctx_tokens tokens (>${threshold_tokens}) → compressing"
      local session_id="dispatch-${BATCH_ID}-${tid}"
      mkdir -p "$ORCH_DIR/context-cache/$session_id"
      echo "$ctx_block" > "$ORCH_DIR/context-cache/$session_id/prompt.ctx"
      local compressed_dir
      compressed_dir=$(compress_session "$session_id" 70 2>/dev/null || echo "")
      if [ -n "$compressed_dir" ] && [ -d "$compressed_dir" ]; then
        local compressed_prompt
        compressed_prompt=$(cat "$compressed_dir/prompt.ctx" 2>/dev/null || echo "$ctx_block")
        # Update ctx_block so downstream uses compressed content
        ctx_block="$compressed_prompt"
        # Update local prompt too (built from ctx_block earlier)
        prompt="${ctx_block}$(parse_body "$spec")"
        # Compression ratio: compressed_size / original_size
        #   1.0 = no compression (100% remained), 0.5 = compressed to 50%, 0.0 = empty
        #   Acceptance criteria uses this ratio as-is (no need to invert)
        local ratio
        ratio=$(echo "scale=2; $(echo "$compressed_prompt" | wc -c) / $ctx_size" | bc 2>/dev/null || echo "1.0")
        echo "[dispatch] 📦 context compressed: ratio=${ratio} (${ctx_size}B → $(echo "$compressed_prompt" | wc -c)B)"
      fi
    fi
  fi

  # Intent Fork detection — check for ambiguity markers
  fork_mode=$(parse_front "$spec" "fork_mode" "disabled")
  if [ "$fork_mode" = "auto" ] && [ -x "$SCRIPT_DIR/task-fork.sh" ]; then
    fork_result=$("$SCRIPT_DIR/task-fork.sh" "$spec" 2>/dev/null || echo "")
    if [ -n "$fork_result" ]; then
      echo "[dispatch] 🔱 Intent fork triggered: $fork_result"
      echo "$fork_result" > "$RESULTS_DIR/${tid}.fork.out"
    fi
  fi

  echo "[dispatch] running $tid → $agent_candidates (retries=$retries)"

  # Set parent task ID for tracing (first context_from task)
  if [ -n "$ctx_tasks" ]; then
    export ORCH_PARENT_TASK_ID=$(echo "$ctx_tasks" | awk '{print $1}')
  fi

  # Dispatch via agent.sh, capture output to result file
  if [ -f "$RESULTS_DIR/${tid}.out" ]; then
    local rev_lock="$RESULTS_DIR/.${tid}.revlock"
    local rev_n=1 rf n snapshot_rc=0 lock_wait=0 lock_ok=false
    while true; do
      if mkdir "$rev_lock" 2>/dev/null; then
        lock_ok=true
        break
      fi
      lock_wait=$((lock_wait + 1))
      if [ "$lock_wait" -ge 200 ]; then
        local now mtime
        now=$(date +%s)
        mtime=$(stat -f %m "$rev_lock" 2>/dev/null || stat -c %Y "$rev_lock" 2>/dev/null || echo 0)
        if [ $((now - mtime)) -gt 300 ]; then
          rmdir "$rev_lock" 2>/dev/null || true
          lock_wait=0
          continue
        fi
        echo "[dispatch] ⚠️  could not acquire revision lock for $tid; skipping snapshot"
        break
      fi
      sleep 0.05
    done
    if [ "$lock_ok" = "true" ]; then
      {
        for rf in "$RESULTS_DIR/${tid}".v*.out; do
          [ -f "$rf" ] || continue
          n="${rf##*.v}"
          n="${n%.out}"
          [[ "$n" =~ ^[0-9]+$ ]] || continue
          [ "$n" -lt "$rev_n" ] || rev_n=$((n + 1))
        done
        cp "$RESULTS_DIR/${tid}.out" "$RESULTS_DIR/${tid}.v${rev_n}.out"
      } || snapshot_rc=$?
      rmdir "$rev_lock" 2>/dev/null || true
      if [ "$snapshot_rc" -ne 0 ]; then
        rm -f "$pid_file"
        return "$snapshot_rc"
      fi
    fi
  fi
  dispatch_log_failover_event() {
    local event="$1" failover_agent="$2" position="$3" outcome="${4:-}" reason="${5:-}"
    python3 - "$event" "$failover_agent" "$position" "$outcome" "$reason" "$tid" "$BATCH_ID" <<'PYEOF' >> "$LOG_FILE"
import datetime
import json
import os
import sys

_, event, agent, position_raw, outcome, reason, task_id, batch_id = sys.argv
entry = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "event": event,
    "task_id": task_id,
    "batch_id": batch_id,
    "trace_id": os.environ.get("ORCH_TRACE_ID"),
    "agent": agent,
    "position": int(position_raw),
}
if outcome:
    entry["outcome"] = outcome
if reason:
    entry["reason"] = reason
print(json.dumps(entry))
PYEOF
  }

  : > "$RESULTS_DIR/${tid}.log"
  for candidate_agent in $agent_candidates; do
    [ -z "$candidate_agent" ] && continue
    failover_position=$((failover_position + 1))
    agent="$candidate_agent"

    if [ -x "$circuit_breaker_sh" ]; then
      if ! "$circuit_breaker_sh" check "$agent"; then
        echo "[dispatch] failover skip $tid → $agent (circuit open)"
        dispatch_log_failover_event "failover_skip" "$agent" "$failover_position" "" "circuit_open"
        continue
      fi
    fi

    if check_agent_health "$tid" "$agent" "false"; then
      health_rc=0
    else
      health_rc=$?
    fi
    if [ "$health_rc" -eq 2 ]; then
      echo "[dispatch] failover skip $tid → $agent (agent down)"
      if [ -x "$circuit_breaker_sh" ]; then
        "$circuit_breaker_sh" record-failure "$agent" >/dev/null 2>&1 || true
      fi
      dispatch_log_failover_event "failover_attempt" "$agent" "$failover_position" "failure" "agent_down"
      continue
    fi

    task_start=$(date +%s)
    rm -f "$cancelled_marker"
    "$SCRIPT_DIR/agent.sh" "$agent" "$tid" "$prompt" "$timeout" "$retries" \
      > "$RESULTS_DIR/${tid}.out" 2>> "$RESULTS_DIR/${tid}.log" &
    agent_pid=$!
    printf '%s\n' "$agent_pid" > "$pid_file"
    if wait "$agent_pid"; then
      task_rc=0
    else
      task_rc=$?
    fi
    task_end=$(date +%s)
    actual_duration=$(( task_end - task_start ))
    rm -f "$pid_file"

    if [ "$task_rc" -eq 0 ]; then
      if [ -x "$circuit_breaker_sh" ]; then
        "$circuit_breaker_sh" record-success "$agent" >/dev/null 2>&1 || true
      fi
      dispatch_log_failover_event "failover_attempt" "$agent" "$failover_position" "success"
      unset ORCH_PARENT_TASK_ID

      rm -f "$RESULTS_DIR/${tid}.skipped"
      local out_size
      out_size=$(wc -c < "$RESULTS_DIR/${tid}.out" | tr -d ' ')
      echo "[dispatch] ✅ $tid complete (${out_size} bytes, ${actual_duration}s)"

      # Run reviewer pipeline (copilot applies + reviews output)
      run_reviewer "$spec" "$tid"

      # ── Quality gate check (Phase 7.3 / 6.2 reflexion trigger) ──────────────────
      local task_status="success"
      if declare -f check_quality_gate > /dev/null 2>&1; then
        local gate_result
        gate_result=$(check_quality_gate "$RESULTS_DIR/${tid}.out" "$RESULTS_DIR/${tid}.log" "$tid" 2>/dev/null || echo "pass")
        if [ "$gate_result" != "pass" ]; then
          echo "[dispatch] 🔄 Quality gate FAILED for $tid → triggering reflexion (6.2)"
          task_status="needs_revision"
          # Trigger revision: create reflexion entry and mark for retry
          if declare -f trigger_reflexion > /dev/null 2>&1; then
            trigger_reflexion "$tid" "$RESULTS_DIR/${tid}.out" "$gate_result" 2>/dev/null || true
          fi
        fi
      fi

      # Generate structured completion report (status reflects quality gate result)
      generate_report "$spec" "$tid" "$task_status" "$out_size" "$actual_duration" "$agent"
      # SLO breach check — pass correct status
      check_slo_breach "$tid" "$agent" "$actual_duration" "$task_status" "$spec"
      check_budget

      # Track cost (prompt_chars + output_chars estimate, 4 chars/token)
      if declare -f cost_record > /dev/null 2>&1; then
        local prompt_chars output_chars
        prompt_chars=$(wc -c < "$RESULTS_DIR/${tid}.log" 2>/dev/null | tr -d ' ' || echo "0")
        output_chars=$(wc -c < "$RESULTS_DIR/${tid}.out" 2>/dev/null | tr -d ' ' || echo "0")
        cost_record "$agent" "$BATCH_ID" "$tid" \
          "$(( prompt_chars / 4 ))" "$(( output_chars / 4 ))" "0" "$actual_duration" \
          2>/dev/null || true
      fi

      return 0
    fi

    if [ -x "$circuit_breaker_sh" ]; then
      "$circuit_breaker_sh" record-failure "$agent" >/dev/null 2>&1 || true
    fi
    dispatch_log_failover_event "failover_attempt" "$agent" "$failover_position" "failure"
    echo "[dispatch] ❌ $tid attempt failed on $agent (${actual_duration}s)"

    # Agent failover: try picking a fallback model before giving up
    if declare -f failover_find_available > /dev/null 2>&1; then
      local failover_chain next_agent
      failover_chain=$(failover_get_chain "$spec" 2>/dev/null || echo "")
      next_agent=$(failover_find_available "$failover_chain" "$agent" 2>/dev/null || echo "")
      if [ -n "$next_agent" ]; then
        echo "[dispatch] ↻ Failover: retrying $tid with $next_agent" >&2
        failover_log_swap "$tid" "$agent" "$next_agent" "agent_failover"
        agent_candidates="$next_agent $agent_candidates"
      fi
    fi
  done

  rm -f "$pid_file"
  unset ORCH_PARENT_TASK_ID
  echo "[dispatch] ❌ $tid failed (${actual_duration}s)"
  # task_failed notification (gated by notify_on_failure)
  if [ "${NOTIFY_ON_FAILURE:-false}" = "true" ]; then
    _err_tail=$(tail -c 500 "$RESULTS_DIR/${tid}.log" 2>/dev/null || echo "")
    _tf_payload=$(python3 -c "import json,sys; print(json.dumps({'batch_id':sys.argv[1],'task_id':sys.argv[2],'agent':sys.argv[3],'retries':int(sys.argv[4]),'duration_s':int(sys.argv[5]),'dlq_path':f'.orchestration/dlq/{sys.argv[2]}.spec.md','error_tail':sys.argv[6]}))" \
      "${BATCH_ID:-}" "$tid" "$agent" "${retries:-0}" "${actual_duration:-0}" "$_err_tail" 2>/dev/null || echo '{}')
    notify_event "task_failed" "$_tf_payload"
  fi
  if ! move_to_dlq "$spec" "$tid" "$agent" "$retries"; then
    echo "[dispatch] ⚠️  failed to write DLQ artifacts for $tid" >&2
  fi

  # Self-Healing DAG
  if [ "$FAILURE_MODE" != "fail-fast" ] && [ -x "$SCRIPT_DIR/task-selfheal.sh" ]; then
    selfheal_result=$("$SCRIPT_DIR/task-selfheal.sh" "$tid" "$BATCH_ID" "$BATCH_DIR" 2>/dev/null || echo "abort")
    case "$selfheal_result" in
      retry-modified) echo "[dispatch] 🔄 Self-healing: retry-modified" ;;
      skip-dependents) echo "[dispatch] 🔄 Self-healing: skipped dependents" ;;
      abort) echo "[dispatch] 🔄 Self-healing: aborting"; batch_abort=true ;;
      *) echo "[dispatch] 🔄 Self-healing: $selfheal_result" ;;
    esac
  fi

  # Auto-escalation report for PM workflow
  cat > "$INBOX_DIR/escalation-${tid}.md" <<EOF
# Escalation: ${tid}

- Batch: ${BATCH_ID}
- Agent: ${agent}
- Retries exhausted: ${retries}
- Duration: ${actual_duration}s
- Error log: .orchestration/dlq/${tid}.error.log
- Spec snapshot: .orchestration/dlq/${tid}.spec.md

## Suggested PM Action
1. Review error log for hard failure reason.
2. Refine task prompt/spec (constraints, context, expected output).
3. Re-dispatch via task-revise.sh or task-dispatch.sh --retry-skipped.
EOF

  generate_report "$spec" "$tid" "failed" "0" "$actual_duration" "$agent"
  # SLO breach check on failure path too
  check_slo_breach "$tid" "$agent" "$actual_duration" "failed" "$spec"
  check_budget
  return 1
}

# ── budget tracking ─────────────────────────────────────────────────────────────
check_budget() {
  if [ "${BUDGET_TOKENS:-0}" -le 0 ]; then
    return 0
  fi

  local total_chars
  total_chars=$(python3 -c '
import json, sys
log_file, batch_id = sys.argv[1], sys.argv[2]
total = 0
try:
    with open(log_file, "r") as f:
        for line in f:
            if not line.strip(): continue
            try:
                row = json.loads(line)
                if row.get("batch_id") == batch_id and row.get("event") == "complete":
                    total += int(row.get("prompt_chars", 0)) + int(row.get("output_chars", 0))
            except: pass
except: pass
print(total)
  ' "$LOG_FILE" "$BATCH_ID")

  local used_tokens=$(( total_chars / 4 ))
  if [ "$used_tokens" -ge "$BUDGET_TOKENS" ]; then
    echo "[dispatch] 💸 BUDGET EXCEEDED — batch halted (used: ${used_tokens} / budget: ${BUDGET_TOKENS} tokens)"
    # Kill all running PIDs
    for p in "$PIDS_DIR"/*.pid; do
      [ -f "$p" ] || continue
      pid=$(cat "$p" 2>/dev/null || true)
      [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
    done

    # Write escalation
    cat > "$INBOX_DIR/escalation-${BATCH_ID}-budget.md" <<EOF
# Escalation: Budget Exceeded for Batch ${BATCH_ID}

- Budget limit: ${BUDGET_TOKENS} tokens
- Used: ${used_tokens} tokens

## Suggested PM Action
1. Review task retries or runaway loops.
2. Increase budget_tokens in batch.conf if necessary.
3. Re-dispatch via task-dispatch.sh to resume.
EOF
    exit 3
  fi
}

# ── sequential dispatch ───────────────────────────────────────────────────────
dispatch_sequential() {
  local success=0 fail=0 skip=0
  # Multiple passes to handle dependencies
  local max_passes=3
  local pass=0

  # ── Intent verification pass: skip specs that fail gate ────────────────────
  local verified_specs=()
  for spec in "${TASK_FILES[@]}"; do
    local tid
    tid=$(parse_front "$spec" "id" "unknown")
    local v_output v_rec
    v_output=$(verify_spec "$spec" 2>/dev/null || echo "{}")
    v_rec=$(echo "$v_output" | jq -r '.recommendation // "proceed"' 2>/dev/null || echo "proceed")
    if [ "$v_rec" = "block" ]; then
      echo "[dispatch] ⚠ intent verification BLOCKED $tid — skipping" >&2
      echo "$tid" >> "$DLQ_DIR/_failed_intent.txt"
      mkdir -p "$RESULTS_DIR"
      printf "Intent verification failed: %s\n" "$(echo "$v_output" | jq -r '.checks // []' 2>/dev/null | head -c 200)" > "$RESULTS_DIR/${tid}.skipped"
    else
      verified_specs+=("$spec")
    fi
  done

  while [ $pass -lt $max_passes ]; do
    local progress=false
    for spec in "${verified_specs[@]}"; do
      local tid
      tid=$(parse_front "$spec" "id" "unknown")

      # Already done
      if [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ]; then
        continue
      fi
      [ -f "$RESULTS_DIR/${tid}.skipped" ] && continue
      [ -f "$RESULTS_DIR/${tid}.skipped.abort" ] && continue
      is_failed_spec "$spec" && continue

      if deps_satisfied "$spec"; then
        if dispatch_task "$spec"; then
          success=$((success + 1))
          progress=true
        else
          rc=$?
          if [ "$rc" -eq 2 ]; then
            skip=$((skip + 1))
          else
            fail=$((fail + 1))
            handle_task_failure "$tid" "$spec"
            if [ "$batch_abort" = "true" ]; then
              mark_remaining_skipped
              break 2
            fi
          fi
        fi
      fi
    done
    $progress || break
    pass=$((pass + 1))
  done

  if [ "$FAILURE_MODE" = "retry-failed" ] && [ "$batch_abort" = "false" ]; then
    local retry_specs=()
    local failed_spec
    for failed_spec in "${FAILED_TASK_SPECS[@]:-}"; do
      [ -z "$failed_spec" ] && continue
      local failed_tid
      failed_tid=$(parse_front "$failed_spec" "id" "unknown")
      if [ -f "$RESULTS_DIR/${failed_tid}.out" ] && [ -s "$RESULTS_DIR/${failed_tid}.out" ]; then
        continue
      fi
      [ -f "$RESULTS_DIR/${failed_tid}.skipped" ] && continue
      [ -f "$RESULTS_DIR/${failed_tid}.skipped.abort" ] && continue
      retry_specs+=("$failed_spec")
    done

    if [ ${#retry_specs[@]} -gt 0 ]; then
      echo "[dispatch] RETRY PASS: re-running ${#retry_specs[@]} failed tasks"
      for spec in "${retry_specs[@]}"; do
        local retry_tid
        retry_tid=$(parse_front "$spec" "id" "unknown")
        if dispatch_task "$spec"; then
          success=$((success + 1))
        else
          rc=$?
          if [ "$rc" -eq 2 ]; then
            skip=$((skip + 1))
          else
            fail=$((fail + 1))
            handle_task_failure "$retry_tid" "$spec"
            if [ "$batch_abort" = "true" ]; then
              mark_remaining_skipped
              break
            fi
          fi
        fi
      done
    fi
  fi
  echo "[dispatch] sequential done — success=$success failed=$fail skipped=$skip"
}

# ── parallel dispatch ─────────────────────────────────────────────────────────
resolve_parallel_agent() {
  local spec="$1" spec_agent route chosen_agent
  spec_agent=$(parse_front "$spec" "agent" "gemini")
  route=$(parse_front "$spec" "route" "")
  if [ "$route" = "auto" ]; then
    chosen_agent=$("$SCRIPT_DIR/agent-load.sh" least-loaded copilot gemini 2>/dev/null || true)
    [ -n "$chosen_agent" ] || chosen_agent="$spec_agent"
    echo "$chosen_agent"
  else
    echo "$spec_agent"
  fi
}

dispatch_parallel() {
  local pids=()
  local pid_agents=()
  local chosen_agent job_pid
  local supports_wait_n=false
  if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 3 ]; }; then
    supports_wait_n=true
  fi

  # First pass: dispatch tasks with no unmet dependencies
  for spec in "${TASK_FILES[@]}"; do
    if deps_satisfied "$spec"; then
      chosen_agent=$(resolve_parallel_agent "$spec")
      dispatch_task "$spec" "$chosen_agent" &
      job_pid=$!
      pids+=("$job_pid")
      pid_agents+=("$chosen_agent")
      "$SCRIPT_DIR/agent-load.sh" increment "$chosen_agent" >/dev/null 2>&1 &
    fi
  done

  # Reap one job at a time so shutdown traps can interrupt blocked waits.
  if [ ${#pids[@]} -gt 0 ]; then
    if [ "$supports_wait_n" = "true" ]; then
      local remaining=${#pids[@]}
      while [ "$remaining" -gt 0 ]; do
        if wait -n 2>/dev/null; then
          :
        else
          local wait_rc=$?
          [ "$wait_rc" -eq 127 ] && break
        fi
        remaining=$((remaining - 1))
      done
    else
      for job_pid in "${pids[@]}"; do
        wait "$job_pid" 2>/dev/null || true
      done
    fi
  fi
  local pid_agent
  for pid_agent in "${pid_agents[@]}"; do
    [ -n "$pid_agent" ] && "$SCRIPT_DIR/agent-load.sh" decrement "$pid_agent" >/dev/null 2>&1 &
  done

  # Second pass: dispatch tasks whose deps are now satisfied (sequential)
  for spec in "${TASK_FILES[@]}"; do
    local tid
    tid=$(parse_front "$spec" "id" "unknown")
    [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ] && continue
    [ -f "$RESULTS_DIR/${tid}.skipped" ] && continue
    if deps_satisfied "$spec"; then
      chosen_agent=$(resolve_parallel_agent "$spec")
      dispatch_task "$spec" "$chosen_agent" || true
    fi
  done

  # Count results from files (single source of truth)
  local success=0 fail=0 skip=0
  for spec in "${TASK_FILES[@]}"; do
    local tid
    tid=$(parse_front "$spec" "id" "unknown")
    if [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ]; then
      success=$((success + 1))
    elif [ -f "$RESULTS_DIR/${tid}.skipped" ]; then
      skip=$((skip + 1))
    else
      fail=$((fail + 1))
    fi
  done

  echo "[dispatch] parallel done — success=$success failed=$fail skipped=$skip"
}

# ── run ───────────────────────────────────────────────────────────────────────
start_time=$(date +%s)

if [ "$MODE" = "--parallel" ] && { [ "$FAILURE_MODE" != "skip-failed" ] || [ "$MAX_FAILURES" -gt 0 ]; }; then
  echo "[dispatch] switching to sequential mode for failure recovery policy"
  MODE="--sequential"
fi

case "$MODE" in
  --parallel) dispatch_parallel ;;
  *)          dispatch_sequential ;;
esac

duration=$(( $(date +%s) - start_time ))

total_tasks=${#TASK_FILES[@]}
success_count=0
failed_count=0
skipped_count=0
cancelled_count=0
for spec in "${TASK_FILES[@]}"; do
  tid=$(parse_front "$spec" "id" "unknown")
  if [ -f "$RESULTS_DIR/${tid}.cancelled" ]; then
    cancelled_count=$((cancelled_count + 1))
  elif [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ]; then
    success_count=$((success_count + 1))
  elif [ -f "$RESULTS_DIR/${tid}.skipped" ] || [ -f "$RESULTS_DIR/${tid}.skipped.abort" ]; then
    skipped_count=$((skipped_count + 1))
  else
    failed_count=$((failed_count + 1))
  fi
done

partial_success=false
if [ "$success_count" -eq "$total_tasks" ]; then
  result_summary="SUCCESS"
elif [ "$success_count" -eq 0 ]; then
  result_summary="FAILED"
else
  result_summary="PARTIAL — ${success_count}/${total_tasks} tasks succeeded"
  partial_success=true
fi

# ── inbox notification ────────────────────────────────────────────────────────
# Write a summary for Claude to pick up on next session

{
  echo "# Batch Complete: $BATCH_ID"
  echo ""
  echo "**Dispatched**: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "**Duration**: ${duration}s"
  echo "**Project**: $PROJECT_ROOT"
  echo "**Failure Mode**: $FAILURE_MODE"
  echo "**Result**: $result_summary"
  echo "**partial_success**: $partial_success"
  echo "**cancelled_tasks**: $cancelled_count"
  echo ""
  echo "## Results"
  echo ""
  for spec in "${TASK_FILES[@]}"; do
    tid=$(parse_front "$spec" "id" "unknown")
    agent=$(parse_front "$spec" "agent" "?")
    if [ -f "$RESULTS_DIR/${tid}.report.json" ]; then
      report_agent=$(python3 - "$RESULTS_DIR/${tid}.report.json" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(data.get("agent", ""))
except Exception:
    pass
PYEOF
)
      [ -n "$report_agent" ] && agent="$report_agent"
    fi
    reviewer=$(parse_front "$spec" "reviewer" "")
    if [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ]; then
      size=$(wc -c < "$RESULTS_DIR/${tid}.out" | tr -d ' ')
      echo "- ✅ **$tid** ($agent) — ${size} bytes → \`results/${tid}.out\`"
      # Show spawn worker results
      for wout in "$RESULTS_DIR/${tid}"-*.out; do
        [[ "$wout" == *"-review.out" ]] && continue
        [ -f "$wout" ] || continue
        wname=$(basename "${wout%.out}")
        wsz=$(wc -c < "$wout" | tr -d ' ')
        if [ "$wsz" -gt 50 ]; then
          echo "  - 🔀 worker **${wname#${tid}-}** — ${wsz} bytes → \`results/$(basename "$wout")\`"
        else
          echo "  - ⚠️  worker **${wname#${tid}-}** — empty or failed"
        fi
      done
      # Show review
      if [ -f "$RESULTS_DIR/${tid}.review.out" ] && [ -s "$RESULTS_DIR/${tid}.review.out" ]; then
        rsize=$(wc -c < "$RESULTS_DIR/${tid}.review.out" | tr -d ' ')
        review_label="${reviewer:-review_agent}"
        echo "  - 🔍 reviewed by **$review_label** — ${rsize} bytes → \`results/${tid}.review.out\`"
      elif [ -n "$reviewer" ]; then
        echo "  - ⚠️  reviewer ($reviewer) failed or no output"
      fi
    elif [ -f "$RESULTS_DIR/${tid}.skipped.abort" ]; then
      echo "- ⏭️ **$tid** ($agent) — skipped (batch aborted)"
    elif [ -f "$RESULTS_DIR/${tid}.skipped" ]; then
      echo "- ⏭️ **$tid** ($agent) — skipped (agent DOWN)"
    else
      echo "- ❌ **$tid** ($agent) — failed or empty"
    fi
  done
  echo ""
  echo "## Next Steps"
  echo "Ask Claude to review: \`Review batch $BATCH_ID results\`"
} > "$INBOX_DIR/${BATCH_ID}.done.md"

echo ""
echo "[dispatch] ✉️  Inbox notification written: .orchestration/inbox/${BATCH_ID}.done.md"
echo "[dispatch] Total time: ${duration}s"

# Batch-level notifications
_bc_result="SUCCESS"
[ "${success_count:-0}" -eq 0 ] && _bc_result="FAILED"
[ "${partial_success:-false}" = "true" ] && _bc_result="PARTIAL"
_bc_payload=$(python3 -c "
import json,sys
print(json.dumps({'batch_id':sys.argv[1],'total_tasks':int(sys.argv[2]),'success_count':int(sys.argv[3]),'failed_count':int(sys.argv[4]),'skipped_count':int(sys.argv[5]),'cancelled_count':int(sys.argv[6]),'duration_s':int(sys.argv[7]),'failure_mode':sys.argv[8],'result':sys.argv[9],'inbox_file':f'.orchestration/inbox/{sys.argv[1]}.done.md'}))" \
  "${BATCH_ID:-}" "${total_tasks:-0}" "${success_count:-0}" "${failed_count:-0}" \
  "${skipped_count:-0}" "${cancelled_count:-0}" "${duration:-0}" \
  "${FAILURE_MODE:-skip-failed}" "$_bc_result" 2>/dev/null || echo '{}')
notify_event "batch_complete" "$_bc_payload"
if [ "${partial_success:-false}" = "true" ] && [ "${NOTIFY_ON_FAILURE:-false}" = "true" ]; then
  notify_event "batch_partial_failure" "$_bc_payload"
fi

if [ "$batch_abort" = "true" ]; then
  exit 1
fi

show_status

# Self-Improvement Loop: generate retrospective
if [ -x "$SCRIPT_DIR/orch-retrospective.sh" ]; then
  "$SCRIPT_DIR/orch-retrospective.sh" "$BATCH_ID" "$duration" \
    "$success_count" "$failed_count" 2>/dev/null || true
fi
