#!/usr/bin/env bash
# parallel-run.sh — Parallel Batch Launcher
# Run multiple batches in parallel with resource management.

set -euo pipefail

# Find the lib directory relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ORCH_DIR="$PROJECT_ROOT"
QUEUE_LIB="$ORCH_DIR/lib/sprint-queue.sh"

# Source queue library
source "$QUEUE_LIB"

# Config
MAX_CONCURRENT="${MAX_CONCURRENT_BATCHES:-3}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
DISPATCH_SCRIPT="$ORCH_DIR/bin/task-dispatch.sh"

usage() {
    cat <<EOF
Usage: parallel-run.sh [options] <batch1> [batch2] ...

Run multiple batches in parallel with queue management.

Options:
  --max N           Max concurrent batches (default: 3)
  --priority N      Priority (1=critical, 2=high, 3=normal, 4=low)
  --wait-for BATCH  Wait for this batch to complete first
  --poll SECS       Poll interval in seconds (default: 5)
  -h, --help        Show this help

Examples:
  ./parallel-run.sh batch1 batch2 batch3
  ./parallel-run.sh --max 5 batch1 batch2
  ./parallel-run.sh batch1 --wait-for batch0
EOF
    exit 0
}

# Parse arguments
PRIORITY=3
WAIT_FOR=""
BATCHES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max)
            MAX_CONCURRENT="$2"
            shift 2
            ;;
        --priority)
            PRIORITY="$2"
            shift 2
            ;;
        --wait-for)
            WAIT_FOR="$2"
            shift 2
            ;;
        --poll)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            BATCHES+=("$1")
            shift
            ;;
    esac
done

if [[ ${#BATCHES[@]} -eq 0 ]]; then
    echo "Error: at least one batch required" >&2
    exit 1
fi

# Wait for dependency if specified
if [[ -n "$WAIT_FOR" ]]; then
    echo "Waiting for $WAIT_FOR to complete..."
    while true; do
        local completed
        completed=$(jq -r '.completed[] | .batch_id' "$QUEUE_STATE" 2>/dev/null || echo "")

        if echo "$completed" | grep -q "^${WAIT_FOR}$"; then
            echo "  $WAIT_FOR completed, proceeding"
            break
        fi

        sleep "$POLL_INTERVAL"
    done
fi

# Queue all batches
echo "Queuing ${#BATCHES[@]} batches..."
for batch in "${BATCHES[@]}"; do
    queue_add "$batch" "$PRIORITY"
done

echo ""
echo "Running ${#BATCHES[@]} batches (max $MAX_CONCURRENT concurrent)..."
echo ""

# Launch parallel execution
START_TIME=$(date +%s)
COMPLETED=0
ACTIVE_PIDS=()

launch_next_batch() {
    if [[ ${#BATCHES[@]} -eq 0 ]] && [[ ${#ACTIVE_PIDS[@]} -eq 0 ]]; then
        return
    fi

    local active
    active=$(queue_get_active | grep -c . 2>/dev/null || echo "0")

    while [[ "$active" -lt "$MAX_CONCURRENT" ]] && [[ ${#BATCHES[@]} -gt 0 ]]; do
        local batch="${BATCHES[0]}"
        BATCHES=("${BATCHES[@]:1}")

        echo "[$(date +%T)] Starting: $batch"
        queue_start "$batch"

        # Launch batch
        local log_file="$ORCH_DIR/sprint-state/${batch}.log"
        mkdir -p "$(dirname "$log_file")"

        "$DISPATCH_SCRIPT" ".orchestration/tasks/$batch" > "$log_file" 2>&1 &
        local pid=$!
        ACTIVE_PIDS+=("$batch:$pid")

        echo "  PID: $pid"
        ((active++)) || true
    done
}

# Monitor execution
monitor_loop() {
    while [[ ${#ACTIVE_PIDS[@]} -gt 0 ]]; do
        launch_next_batch

        # Check for completed/failed
        local remaining=()
        for entry in "${ACTIVE_PIDS[@]}"; do
            local batch="${entry%%:*}"
            local pid="${entry##*:}"

            if ! kill -0 "$pid" 2>/dev/null; then
                # Process finished
                local log_file="$ORCH_DIR/sprint-state/${batch}.log"

                if grep -qi "error\|fail\|exception" "$log_file" 2>/dev/null; then
                    echo "[$(date +%T)] Failed: $batch"
                    queue_fail "$batch" "execution failed"
                else
                    echo "[$(date +%T)] Completed: $batch"
                    queue_complete "$batch"
                fi

                ((COMPLETED++)) || true
            else
                remaining+=("$entry")
            fi
        done

        ACTIVE_PIDS=("${remaining[@]}")
        sleep "$POLL_INTERVAL"
    done
}

launch_next_batch
monitor_loop

# Summary
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "=========================="
echo "Parallel Run Complete"
echo "=========================="
echo "Total batches: ${#BATCHES[@]}"
echo "Completed: $COMPLETED"
echo "Duration: ${DURATION}s"
echo ""
queue_get_stats | jq '.'