#!/usr/bin/env bash
# sprint-queue.sh — Sprint Queue Manager
# Priority-based queue for parallel batch execution.

set -euo pipefail

ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
QUEUE_DIR="$ORCH_DIR/sprint-queue"
QUEUE_DB="$QUEUE_DIR/queue.jsonl"
QUEUE_STATE="$QUEUE_DIR/state.json"

mkdir -p "$QUEUE_DIR"

# Priority levels
readonly PRIORITY_CRITICAL=1
readonly PRIORITY_HIGH=2
readonly PRIORITY_NORMAL=3
readonly PRIORITY_LOW=4

# Resource limits
MAX_CONCURRENT_BATCHES="${MAX_CONCURRENT_BATCHES:-3}"
MAX_CONCURRENT_AGENTS="${MAX_CONCURRENT_AGENTS:-5}"

# Initialize queue state
init_queue() {
    if [[ ! -f "$QUEUE_STATE" ]]; then
        cat > "$QUEUE_STATE" <<EOF
{
  "queued": [],
  "active": [],
  "completed": [],
  "failed": [],
  "max_concurrent": $MAX_CONCURRENT_BATCHES,
  "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    fi
}

# Add batch to queue
queue_add() {
    local batch_id="$1"
    local priority="${2:-3}"
    local dependencies="${3:-}"

    init_queue

    local entry=$(cat <<EOF
{
  "batch_id": "$batch_id",
  "priority": $priority,
  "dependencies": "$dependencies",
  "queued_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "queued"
}
EOF
)

    echo "$entry" >> "$QUEUE_DB"

    # Update state
    local queued_list
    queued_list=$(jq --argjson entry "$entry" '.queued += [$entry]' "$QUEUE_STATE" 2>/dev/null)
    echo "$queued_list" > "$QUEUE_STATE"

    echo "Queued: $batch_id (priority=$priority)"
}

# Get next batch ready to run
queue_get_ready() {
    init_queue

    local active_count
    active_count=$(jq '.active | length' "$QUEUE_STATE" 2>/dev/null || echo "0")

    if [[ "$active_count" -ge "$MAX_CONCURRENT_BATCHES" ]]; then
        echo "MAX_CONCURRENT reached ($active_count/$MAX_CONCURRENT_BATCHES)"
        return 1
    fi

    # Get highest priority queued batch
    local ready
    ready=$(jq '[.queued[] | select(.dependencies == "" or (.dependencies != "" and '"$(jq -r '.completed | length' "$QUEUE_STATE" 2>/dev/null)"' > 0))] | sort_by(.priority)[0]' "$QUEUE_STATE" 2>/dev/null)

    if [[ -n "$ready" ]] && [[ "$ready" != "null" ]]; then
        echo "$ready" | jq -r '.batch_id'
    else
        echo "No ready batches"
        return 1
    fi
}

# Get currently running batches
queue_get_active() {
    init_queue

    jq -r '.active[] | .batch_id' "$QUEUE_STATE" 2>/dev/null || echo ""
}

# Mark batch as active/running
queue_start() {
    local batch_id="$1"

    init_queue

    # Remove from queued, add to active
    local updated
    updated=$(jq --arg bid "$batch_id" \
        '.active += [.queued[] | select(.batch_id == $bid)] |
         .queued = [.queued[] | select(.batch_id != $bid)]' \
        "$QUEUE_STATE" 2>/dev/null)
    echo "$updated" > "$QUEUE_STATE"

    echo "Started: $batch_id"
}

# Mark batch as complete
queue_complete() {
    local batch_id="$1"

    init_queue

    # Remove from active, add to completed
    local updated
    updated=$(jq --arg bid "$batch_id" \
        '.completed += [.active[] | select(.batch_id == $bid)] |
         .active = [.active[] | select(.batch_id != $bid)]' \
        "$QUEUE_STATE" 2>/dev/null)
    echo "$updated" > "$QUEUE_STATE"

    echo "Completed: $batch_id"
}

# Mark batch as failed
queue_fail() {
    local batch_id="$1"
    local reason="${2:-unknown}"

    init_queue

    # Remove from active, add to failed
    local updated
    updated=$(jq --arg bid "$batch_id" --arg reason "$reason" \
        '.failed += [.active[] | select(.batch_id == $bid) + {"reason": $reason}] |
         .active = [.active[] | select(.batch_id != $bid)]' \
        "$QUEUE_STATE" 2>/dev/null)
    echo "$updated" > "$QUEUE_STATE"

    echo "Failed: $batch_id (reason: $reason)"
}

# Get queue statistics
queue_get_stats() {
    init_queue

    local queued active completed failed
    queued=$(jq '.queued | length' "$QUEUE_STATE" 2>/dev/null || echo "0")
    active=$(jq '.active | length' "$QUEUE_STATE" 2>/dev/null || echo "0")
    completed=$(jq '.completed | length' "$QUEUE_STATE" 2>/dev/null || echo "0")
    failed=$(jq '.failed | length' "$QUEUE_STATE" 2>/dev/null || echo "0")

    cat <<EOF
{
  "queued": $queued,
  "active": $active,
  "completed": $completed,
  "failed": $failed,
  "max_concurrent": $MAX_CONCURRENT_BATCHES,
  "utilization": "$(echo "scale=1; ($active * 100) / $MAX_CONCURRENT_BATCHES" | bc 2>/dev/null || echo "0")%"
}
EOF
}

# Check if dependencies are satisfied
queue_check_deps() {
    local batch_id="$1"

    init_queue

    local deps
    deps=$(jq --arg bid "$batch_id" '.queued[] | select(.batch_id == $bid) | .dependencies' "$QUEUE_STATE" 2>/dev/null)

    if [[ -z "$deps" ]] || [[ "$deps" == "null" ]] || [[ "$deps" == "\"\"" ]]; then
        echo "true"
        return
    fi

    # Parse dependencies
    local completed
    completed=$(jq '.completed[] | .batch_id' "$QUEUE_STATE" 2>/dev/null)

    for dep in $deps; do
        if ! echo "$completed" | grep -q "$dep"; then
            echo "false"
            return
        fi
    done

    echo "true"
}

# Get pending batches count
queue_pending() {
    init_queue
    jq '.queued | length' "$QUEUE_STATE" 2>/dev/null || echo "0"
}

# Clear completed and failed from state
queue_cleanup() {
    init_queue

    local updated
    updated=$(jq '{queued: .queued, active: .active, completed: [], failed: [], max_concurrent: .max_concurrent, last_updated: "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' "$QUEUE_STATE" 2>/dev/null)
    echo "$updated" > "$QUEUE_STATE"

    echo "Queue cleaned"
}

# Main (only run if executed directly, not sourced)
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        add)      shift; queue_add "$@" ;;
        ready)    shift; queue_get_ready ;;
        active)   shift; queue_get_active ;;
        start)    shift; queue_start "$@" ;;
        complete) shift; queue_complete "$@" ;;
        fail)     shift; queue_fail "$@" ;;
        stats)    shift; queue_get_stats ;;
        pending)  shift; queue_pending ;;
        cleanup)  shift; queue_cleanup ;;
        check-deps) shift; queue_check_deps "$@" ;;
        *)        echo "Usage: $0 add|ready|active|start|complete|fail|stats|pending|cleanup|check-deps" >&2; exit 1 ;;
    esac
fi