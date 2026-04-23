#!/usr/bin/env bash
# scheduled-run.sh — Execute Single Scheduled Task
# Validates conditions and runs a scheduled batch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

usage() {
    cat <<EOF
Usage: $0 <scheduled-task-name> [options]

Options:
  --dry-run    Validate but don't execute
  --force      Ignore conditions

Examples:
  $0 hourly-smoke-test
  $0 daily-build --dry-run
EOF
    exit 0
}

DRY_RUN=false
FORCE=false
TASK_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --force) FORCE=true; shift ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) TASK_NAME="$1"; shift ;;
    esac
done

if [[ -z "$TASK_NAME" ]]; then
    usage
fi

# Find config
CONFIG_FILE="$ORCH_DIR/scheduled/${TASK_NAME}.scheduled"
if [[ ! -f "$CONFIG_FILE" ]]; then
    CONFIG_FILE="$PROJECT_ROOT/.orchestration/scheduled/${TASK_NAME}.scheduled"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[scheduled-run] ERROR: config not found: $TASK_NAME" >&2
    exit 1
fi

echo "[scheduled-run] Loading: $TASK_NAME"

# Parse config
batch=$(grep '^batch:' "$CONFIG_FILE" | cut -d: -f2- | tr -d ' ')
enabled=$(grep '^enabled:' "$CONFIG_FILE" | cut -d: -f2- | tr -d ' ')
priority=$(grep '^priority:' "$CONFIG_FILE" | cut -d: -f2- | tr -d ' ')
timeout=$(grep '^timeout_batch:' "$CONFIG_FILE" | cut -d: -f2- | tr -d ' ' || echo "3600")
on_failure=$(grep '^on_failure:' "$CONFIG_FILE" | cut -d: -f2- | tr -d ' ')

# Check enabled
if [[ "$enabled" != "true" ]]; then
    echo "[scheduled-run] SKIP: task is disabled"
    exit 0
fi

# Pre-warm agents
prewarm_agents() {
    echo "[scheduled-run] Pre-warming agents..."
    for agent in copilot gemini; do
        if "$SCRIPT_DIR/orch-health-beacon.sh" 2>/dev/null | grep -q "^$agent.*DOWN"; then
            echo "[scheduled-run] Skipping prewarm for DOWN agent: $agent"
            continue
        fi
        echo "[scheduled-run] Agent $agent is ready"
    done
}

# Run with timeout
run_batch() {
    local batch_path="$PROJECT_ROOT/.orchestration/tasks/$batch/"
    local start_time
    start_time=$(date +%s)

    echo "[scheduled-run] Starting batch: $batch"
    echo "[scheduled-run] Timeout: ${timeout}s"

    if $DRY_RUN; then
        echo "[scheduled-run] DRY RUN: would execute $batch"
        echo "[scheduled-run] Batch path: $batch_path"
        return 0
    fi

    # Run with timeout
    local result
    result=$(timeout "$timeout" "$SCRIPT_DIR/task-dispatch.sh" "$batch_path" 2>&1) || {
        echo "[scheduled-run] ERROR: batch timed out after ${timeout}s" >&2
        return 1
    }

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo "[scheduled-run] Completed in ${duration}s"
    echo "$result"

    return 0
}

# Execute
echo "[scheduled-run] $(date)"
echo "[scheduled-run] Batch: $batch"

prewarm_agents
run_batch

echo "[scheduled-run] Done: $TASK_NAME"
