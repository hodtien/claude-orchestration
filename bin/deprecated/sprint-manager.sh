#!/usr/bin/env bash
# sprint-manager.sh — Sprint Execution Manager
# Manage concurrent batch execution with resource awareness.

set -euo pipefail

# Find the lib directory relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ORCH_DIR="$PROJECT_ROOT"
QUEUE_LIB="$ORCH_DIR/lib/sprint-queue.sh"
STATE_DIR="$ORCH_DIR/sprint-state"

mkdir -p "$STATE_DIR"

# Source queue library
source "$QUEUE_LIB"

# Config
MAX_CONCURRENT="${MAX_CONCURRENT_BATCHES:-3}"
MAX_AGENTS="${MAX_CONCURRENT_AGENTS:-5}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# Track running sprints
PID_FILE="$STATE_DIR/running-sprints.pid"

# Start sprint manager
start_sprint_manager() {
    local dispatch_script="$ORCH_DIR/bin/task-dispatch.sh"

    echo "Sprint Manager started (max $MAX_CONCURRENT concurrent)"
    echo "PID: $$"

    while true; do
        # Check if we can start more sprints
        local active_count
        active_count=$(queue_get_active | grep -c . 2>/dev/null || echo "0")

        if [[ "$active_count" -lt "$MAX_CONCURRENT" ]]; then
            # Get next ready batch
            local batch_id
            batch_id=$(queue_get_ready 2>/dev/null || echo "")

            if [[ -n "$batch_id" ]] && [[ "$batch_id" != "No ready batches" ]]; then
                echo "Starting sprint: $batch_id"

                # Start sprint in background
                if [[ -f "$dispatch_script" ]]; then
                    "$dispatch_script" ".orchestration/tasks/$batch_id" 2>&1 | \
                        tee "$STATE_DIR/${batch_id}.log" &
                    local pid=$!

                    # Track PID
                    echo "$batch_id:$pid" >> "$PID_FILE"

                    # Mark as active
                    queue_start "$batch_id"

                    echo "  PID: $pid"
                fi
            fi
        fi

        # Check for completed sprints
        check_completed_sprints

        # Check for failed sprints
        check_failed_sprints

        sleep "$POLL_INTERVAL"
    done
}

# Check for completed sprints
check_completed_sprints() {
    local now
    now=$(date +%s)

    while IFS=: read -r batch_id pid; do
        if [[ -z "$batch_id" ]]; then
            continue
        fi

        # Check if process is still running
        if ! kill -0 "$pid" 2>/dev/null; then
            # Check result file
            local result_file="$STATE_DIR/${batch_id}.result"
            local log_file="$STATE_DIR/${batch_id}.log"

            if [[ -f "$result_file" ]]; then
                local success
                success=$(jq -r '.success' "$result_file" 2>/dev/null || echo "false")

                if [[ "$success" == "true" ]]; then
                    echo "Sprint completed: $batch_id"
                    queue_complete "$batch_id"
                else
                    echo "Sprint failed: $batch_id"
                    local reason
                    reason=$(jq -r '.error // "unknown"' "$result_file" 2>/dev/null || echo "unknown")
                    queue_fail "$batch_id" "$reason"
                fi

                # Clean up
                rm -f "$result_file" "$log_file"
                sed -i '' "/^$batch_id:/d" "$PID_FILE" 2>/dev/null || true
            fi
        fi
    done < "$PID_FILE" 2>/dev/null
}

# Check for failed sprints
check_failed_sprints() {
    local timeout_file="$STATE_DIR/timeouts.json"

    if [[ ! -f "$timeout_file" ]]; then
        return
    fi

    local now
    now=$(date +%s)

    while IFS= read -r batch_id; do
        if [[ -z "$batch_id" ]]; then
            continue
        fi

        local timeout
        timeout=$(jq --arg bid "$batch_id" '.[$bid]' "$timeout_file" 2>/dev/null || echo "0")
        local started
        started=$(jq --arg bid "$batch_id" '.started[$bid]' "$timeout_file" 2>/dev/null || echo "0")

        if [[ "$timeout" -gt 0 ]] && [[ "$started" -gt 0 ]]; then
            local elapsed=$((now - started))
            if [[ "$elapsed" -gt "$timeout" ]]; then
                echo "Sprint timeout: $batch_id (elapsed: ${elapsed}s, timeout: ${timeout}s)"

                # Kill the process
                local pid
                pid=$(grep "^$batch_id:" "$PID_FILE" 2>/dev/null | cut -d: -f2)
                if [[ -n "$pid" ]]; then
                    kill "$pid" 2>/dev/null || true
                fi

                queue_fail "$batch_id" "timeout"
                sed -i '' "/^$batch_id:/d" "$PID_FILE" 2>/dev/null || true
            fi
        fi
    done < <(jq -r 'keys[]' "$timeout_file" 2>/dev/null)
}

# Get sprint status
sprint_status() {
    echo "Sprint Manager Status"
    echo "===================="
    echo ""

    # Queue stats
    queue_get_stats | jq '.'
    echo ""

    # Active sprints
    echo "Active sprints:"
    local active
    active=$(queue_get_active)
    if [[ -n "$active" ]]; then
        echo "$active" | while read -r batch_id; do
            local pid
            pid=$(grep "^$batch_id:" "$PID_FILE" 2>/dev/null | cut -d: -f2 || echo "?")
            local log="$STATE_DIR/${batch_id}.log"
            local last_line=""
            if [[ -f "$log" ]]; then
                last_line=$(tail -1 "$log" 2>/dev/null || echo "")
            fi
            echo "  - $batch_id (PID: $pid)"
            [[ -n "$last_line" ]] && echo "    Last: $last_line"
        done
    else
        echo "  (none)"
    fi
}

# Stop sprint manager
stop_sprint_manager() {
    local pid
    pid=$(pgrep -f "sprint-manager.sh start" | head -1 || echo "")

    if [[ -n "$pid" ]]; then
        echo "Stopping sprint manager (PID: $pid)"
        kill "$pid" 2>/dev/null || true
        echo "Stopped"
    else
        echo "Sprint manager not running"
    fi
}

# Main
case "${1:-}" in
    start)      start_sprint_manager ;;
    status)     sprint_status ;;
    stop)       stop_sprint_manager ;;
    *)
        cat <<EOF
Usage: $0 start|status|stop

Commands:
  start   Start sprint manager (background)
  status  Show sprint status
  stop    Stop sprint manager

Environment:
  MAX_CONCURRENT_BATCHES  Max concurrent sprints (default: 3)
  MAX_CONCURRENT_AGENTS   Max agents per sprint (default: 5)
  POLL_INTERVAL           Poll interval in seconds (default: 5)
EOF
        exit 1
        ;;
esac