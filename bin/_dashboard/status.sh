#!/usr/bin/env bash
# _dashboard/status.sh — Unified orchestration health overview
# Sourced by orch-dashboard.sh.
# Usage: status [--json]
#        overview [--json]   (alias)
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Default paths (overridable for tests)
ORCH_DIR="${ORCH_DIR:-$PROJECT_ROOT/.orchestration}"
RESULTS_DIR="${STATUS_RESULTS_DIR:-$ORCH_DIR/results}"
TASKS_DIR="${STATUS_TASKS_DIR:-$ORCH_DIR/tasks}"
AUDIT_FILE="${STATUS_AUDIT_FILE:-$ORCH_DIR/audit.jsonl}"
COST_LOG="${STATUS_COST_LOG:-$HOME/.claude/orchestration/cost-tracking.jsonl}"
BUDGET_YAML="${STATUS_BUDGET_YAML:-$PROJECT_ROOT/config/budget.yaml}"
LEARN_DIR="${STATUS_LEARN_DIR:-$ORCH_DIR/learnings}"
REACT_DIR="${STATUS_REACT_DIR:-$ORCH_DIR/react-traces}"
SESSION_DIR="${STATUS_SESSION_DIR:-$ORCH_DIR/session-context}"
DASHBOARD_SCRIPT="${STATUS_DASHBOARD_SCRIPT:-$PROJECT_ROOT/bin/orch-dashboard.sh}"
MCP_SERVER="${STATUS_MCP_SERVER:-$PROJECT_ROOT/mcp-server/server.mjs}"
BIN_DIR="${STATUS_BIN_DIR:-$PROJECT_ROOT/bin}"

OUTPUT_JSON=false
while [ $# -gt 0 ]; do
  case "$1" in
    --json) OUTPUT_JSON=true; shift ;;
    --help|-h)
      echo "Usage: status [--json]"
      return 0 2>/dev/null || exit 0 ;;
    *) shift ;;
  esac
done

python3 - \
  "$ORCH_DIR" "$RESULTS_DIR" "$TASKS_DIR" "$AUDIT_FILE" "$COST_LOG" \
  "$BUDGET_YAML" "$LEARN_DIR" "$REACT_DIR" "$SESSION_DIR" \
  "$DASHBOARD_SCRIPT" "$MCP_SERVER" "$BIN_DIR" "$OUTPUT_JSON" <<'PYEOF'
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone, timedelta

(orch_dir, results_dir, tasks_dir, audit_file, cost_log,
 budget_yaml, learn_dir, react_dir, session_dir,
 dashboard_script, mcp_server, bin_dir, output_json_str) = sys.argv[1:14]

output_json = output_json_str.lower() == "true"
now = datetime.now(timezone.utc)
generated_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")

EXPECTED_MCP_TOOLS = {
    "check_inbox", "check_batch_status", "list_batches", "quick_metrics",
    "get_project_health", "check_escalations", "get_task_trace",
    "get_trace_waterfall", "recent_failures", "get_token_budget",
    "decompose_preview", "get_routing_advice", "get_react_trace",
    "get_session_context",
}


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


def safe_listdir(path):
    try:
        return os.listdir(path)
    except (FileNotFoundError, NotADirectoryError, PermissionError, OSError):
        return []


def load_jsonl(path):
    records = []
    try:
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except (FileNotFoundError, OSError):
        pass
    return records


def count_batch_dirs(path):
    total = 0
    for entry in safe_listdir(path):
        if os.path.isdir(os.path.join(path, entry)):
            total += 1
    return total


def load_budget_config(path):
    budget_limit = 100000
    alert_threshold = 80
    try:
        with open(path) as handle:
            for line in handle:
                match = re.match(r'^\s*daily_token_limit:\s*(\d+)', line)
                if match:
                    budget_limit = int(match.group(1))
                match = re.match(r'^\s*alert_threshold_pct:\s*(\d+)', line)
                if match:
                    alert_threshold = int(match.group(1))
    except (FileNotFoundError, OSError):
        pass
    return budget_limit, alert_threshold


def count_dashboard_subcommands(path):
    subcommands = set()
    try:
        with open(path) as handle:
            in_case = False
            for line in handle:
                if re.match(r'^\s*case\s+"\$cmd"', line):
                    in_case = True
                    continue
                if in_case and re.match(r'^\s*esac\b', line):
                    break
                if not in_case:
                    continue
                match = re.match(r'^\s*([a-zA-Z][a-zA-Z0-9|_-]*)\)\s*source\s', line)
                if not match:
                    continue
                for token in match.group(1).split("|"):
                    subcommands.add(token)
    except (FileNotFoundError, OSError):
        return 0
    return len(subcommands)


def check_mcp_inventory(path):
    names = set()
    try:
        with open(path) as handle:
            for line in handle:
                match = re.search(r'name:\s*"([^"]+)"', line)
                if match:
                    names.add(match.group(1))
    except (FileNotFoundError, OSError):
        return 0, [], []

    tool_names = set()
    for name in names:
        if name != "orch-notify":
            tool_names.add(name)

    missing = sorted(EXPECTED_MCP_TOOLS - tool_names)
    unexpected = sorted(tool_names - EXPECTED_MCP_TOOLS)
    return len(tool_names), missing, unexpected


def count_test_suites(path):
    total = 0
    for entry in safe_listdir(path):
        if entry.startswith("test-") and entry.endswith(".sh"):
            total += 1
    return total


# Batch pipeline
batch_pipeline_total_batches = count_batch_dirs(tasks_dir)
status_files = []
if os.path.isdir(results_dir):
    status_files = glob.glob(os.path.join(results_dir, "*.status.json"))
batch_pipeline_total_tasks = len(status_files)

audit_records = load_jsonl(audit_file)
completed = 0
failed = 0
recent_failures_24h = 0
cutoff_24h = now - timedelta(hours=24)
for record in audit_records:
    event = record.get("event", "")
    if event in ("task_completed", "task_succeeded", "complete"):
        completed += 1
    elif event in ("task_failed", "task_failure", "failure", "task_error"):
        failed += 1
        timestamp = parse_ts(record.get("timestamp", ""))
        if timestamp and timestamp >= cutoff_24h:
            recent_failures_24h += 1

if completed + failed > 0:
    batch_pipeline_success_rate_pct = round(completed / float(completed + failed) * 100, 1)
else:
    batch_pipeline_success_rate_pct = 0.0 if batch_pipeline_total_tasks == 0 else 100.0

# Token budget
budget_limit, alert_threshold = load_budget_config(budget_yaml)
cost_records = load_jsonl(cost_log)
has_cost_log = bool(cost_records)

token_budget_burned_actual = 0
earliest_timestamp = None
for record in cost_records:
    timestamp = parse_ts(record.get("timestamp", ""))
    if not timestamp or timestamp < cutoff_24h:
        continue
    token_budget_burned_actual += int(record.get("tokens_input") or 0) + int(record.get("tokens_output") or 0)
    if earliest_timestamp is None or timestamp < earliest_timestamp:
        earliest_timestamp = timestamp

token_budget_burned_estimated = 0
if not has_cost_log:
    for record in audit_records:
        if record.get("event") != "tier_assigned":
            continue
        timestamp = parse_ts(record.get("timestamp", ""))
        if not timestamp or timestamp < cutoff_24h:
            continue
        token_budget_burned_estimated += int(record.get("tokens_estimated") or 0)
        if earliest_timestamp is None or timestamp < earliest_timestamp:
            earliest_timestamp = timestamp

token_budget_burned = token_budget_burned_actual if has_cost_log else token_budget_burned_estimated
token_budget_pct = round(token_budget_burned / float(budget_limit) * 100, 1) if budget_limit > 0 else 0.0

if earliest_timestamp:
    hours_elapsed = max((now - earliest_timestamp).total_seconds() / 3600.0, 0.1)
else:
    hours_elapsed = 24.0
token_budget_burn_rate_per_hr = int(round(token_budget_burned / hours_elapsed)) if hours_elapsed > 0 else 0

if token_budget_pct >= 100:
    token_budget_alert = "over_budget"
elif token_budget_pct >= alert_threshold:
    token_budget_alert = "warning"
else:
    token_budget_alert = "none"

# Learning engine
learning_records = []
if os.path.isdir(learn_dir):
    for entry in safe_listdir(learn_dir):
        if entry.endswith(".jsonl"):
            learning_records.extend(load_jsonl(os.path.join(learn_dir, entry)))

learning_task_types = set()
for record in learning_records:
    task_type = record.get("task_type")
    if task_type:
        learning_task_types.add(task_type)

# ReAct traces
react_traces_total = 0
react_traces_active = 0
if os.path.isdir(react_dir):
    for entry in safe_listdir(react_dir):
        if not entry.endswith(".jsonl"):
            continue
        react_traces_total += 1
        trace_path = os.path.join(react_dir, entry)
        try:
            last_status = None
            with open(trace_path) as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        payload = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if "status" in payload:
                        last_status = payload["status"]
            if last_status not in ("completed", "done", "failed"):
                react_traces_active += 1
        except (FileNotFoundError, OSError):
            continue

# Session context
session_context_total_briefs = 0
chain_lengths = []
if os.path.isdir(session_dir):
    for entry in safe_listdir(session_dir):
        if not entry.endswith(".session.json"):
            continue
        session_context_total_briefs += 1
        session_path = os.path.join(session_dir, entry)
        try:
            with open(session_path) as handle:
                payload = json.load(handle)
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            continue

        chain_length = payload.get("chain_length")
        if isinstance(chain_length, (int, float)):
            chain_lengths.append(float(chain_length))
            continue

        fallback_chain = payload.get("depends_on") or payload.get("chain") or []
        if isinstance(fallback_chain, list):
            chain_lengths.append(float(len(fallback_chain)))

session_context_avg_chain_length = round(sum(chain_lengths) / len(chain_lengths), 1) if chain_lengths else 0.0

# Dashboard modules and MCP inventory
dashboard_modules_registered = count_dashboard_subcommands(dashboard_script)
dashboard_modules_mcp_tools, mcp_missing, mcp_unexpected = check_mcp_inventory(mcp_server)

# Verification
verification_test_suites_discovered = count_test_suites(bin_dir)

result = {
    "generated_at": generated_at,
    "batch_pipeline": {
        "total_batches": batch_pipeline_total_batches,
        "total_tasks": batch_pipeline_total_tasks,
        "success_rate_pct": batch_pipeline_success_rate_pct,
        "recent_failures_24h": recent_failures_24h,
    },
    "token_budget": {
        "burned": token_budget_burned,
        "limit": budget_limit,
        "pct": token_budget_pct,
        "burn_rate_per_hr": token_budget_burn_rate_per_hr,
        "alert": token_budget_alert,
    },
    "learning_engine": {
        "total_records": len(learning_records),
        "task_types": len(learning_task_types),
    },
    "react_traces": {
        "total": react_traces_total,
        "active": react_traces_active,
    },
    "session_context": {
        "total_briefs": session_context_total_briefs,
        "avg_chain_length": session_context_avg_chain_length,
    },
    "dashboard_modules": {
        "registered": dashboard_modules_registered,
        "mcp_tools": dashboard_modules_mcp_tools,
        "mcp_missing": mcp_missing,
        "mcp_unexpected": mcp_unexpected,
    },
    "verification": {
        "test_suites_discovered": verification_test_suites_discovered,
    },
}

if output_json:
    print(json.dumps(result, indent=2))
    sys.exit(0)

print("=== Orchestration Health Status ===")
print("Generated: %s" % generated_at)
print()

batch_pipeline = result["batch_pipeline"]
print("--- Batch Pipeline ---")
print("Total batches:     %s" % batch_pipeline["total_batches"])
print("Total tasks:       %s" % batch_pipeline["total_tasks"])
print("Success rate:      %s%%" % batch_pipeline["success_rate_pct"])
print("Recent failures:   %s (last 24h)" % batch_pipeline["recent_failures_24h"])
print()

token_budget = result["token_budget"]
print("--- Token Budget ---")
print("Burned:            %s / %s (%s%%)" % (
    format(token_budget["burned"], ","),
    format(token_budget["limit"], ","),
    token_budget["pct"],
))
print("Burn rate:         %s tokens/hr" % format(token_budget["burn_rate_per_hr"], ","))
print("Alert:             %s" % token_budget["alert"])
print()

learning_engine = result["learning_engine"]
print("--- Learning Engine ---")
print("Total records:     %s" % learning_engine["total_records"])
print("Task types:        %s" % learning_engine["task_types"])
print()

react_traces = result["react_traces"]
print("--- ReAct Traces ---")
print("Total traces:      %s" % react_traces["total"])
print("Active:            %s" % react_traces["active"])
print()

session_context = result["session_context"]
print("--- Session Context ---")
print("Total briefs:      %s" % session_context["total_briefs"])
print("Avg chain length:  %s" % session_context["avg_chain_length"])
print()

dashboard_modules = result["dashboard_modules"]
print("--- Dashboard Modules ---")
print("Registered:        %s subcommands" % dashboard_modules["registered"])
print("MCP Tools:         %s registered" % dashboard_modules["mcp_tools"])
if dashboard_modules["mcp_missing"]:
    print("  Missing:         %s" % ", ".join(dashboard_modules["mcp_missing"]))
if dashboard_modules["mcp_unexpected"]:
    print("  Unexpected:      %s" % ", ".join(dashboard_modules["mcp_unexpected"]))
print()

verification = result["verification"]
print("--- Verification ---")
print("Test suites:       %s discovered" % verification["test_suites_discovered"])
PYEOF
