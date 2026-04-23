#!/usr/bin/env bash
# orch-scheduler.sh — Cron-based Batch Scheduler
# Loads scheduled task configs and queues batches for execution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEDULED_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}/scheduled"
QUEUE_DIR="$SCHEDULED_DIR/queue"
HISTORY_DIR="$SCHEDULED_DIR/history"
MAX_CONCURRENT="${MAX_CONCURRENT:-2}"

mkdir -p "$SCHEDULED_DIR" "$QUEUE_DIR" "$HISTORY_DIR"

usage() {
    cat <<EOF
Usage: $0 [command]

Commands:
  list        List all scheduled tasks
  due         Show tasks due to run now
  queue       Queue all due tasks for execution
  run         Execute queued tasks
  check       Run full check cycle (load, queue, execute)

Examples:
  $0 list                    # Show all scheduled tasks
  $0 due                      # Show tasks due now
  $0 check                    # Full scheduler cycle
EOF
    exit 0
}

# Load a scheduled config
scheduler_load_config() {
    local config_file="$1"
    local name
    name=$(basename "$config_file" .scheduled)

    # Parse key fields
    local batch cron enabled priority timeout
    batch=$(grep '^batch:' "$config_file" | cut -d: -f2- | tr -d ' ')
    cron=$(grep '^cron:' "$config_file" | cut -d: -f2- | tr -d ' ')
    enabled=$(grep '^enabled:' "$config_file" | cut -d: -f2- | tr -d ' ')
    priority=$(grep '^priority:' "$config_file" | cut -d: -f2- | tr -d ' ')
    timeout=$(grep '^timeout_batch:' "$config_file" | cut -d: -f2- | tr -d ' ' || echo "3600")

    echo "$name|$batch|$cron|$enabled|$priority|$timeout"
}

# Check if cron expression matches now
scheduler_is_due() {
    local cron_expr="$1"
    local now_min now_hour now_dom now_mon now_dow

    now_min=$(date +%M)
    now_hour=$(date +%H)
    now_dom=$(date +%d)
    now_mon=$(date +%m)
    now_dow=$(date +%w)

    # Simple cron check (basic format: "M H DoM Mon DoW")
    local cron_min cron_hour cron_dom cron_mon cron_dow
    cron_min=$(echo "$cron_expr" | awk '{print $1}')
    cron_hour=$(echo "$cron_expr" | awk '{print $2}')
    cron_dom=$(echo "$cron_expr" | awk '{print $3}')
    cron_mon=$(echo "$cron_expr" | awk '{print $4}')
    cron_dow=$(echo "$cron_expr" | awk '{print $5}')

    # Check each field
    [[ "$cron_min" == "*" || "$cron_min" == "$now_min" ]] || return 1
    [[ "$cron_hour" == "*" || "$cron_hour" == "$now_hour" ]] || return 1
    [[ "$cron_dom" == "*" || "$cron_dom" == "$now_dom" ]] || return 1
    [[ "$cron_mon" == "*" || "$cron_mon" == "$now_mon" ]] || return 1
    [[ "$cron_dow" == "*" || "$cron_dow" == "$now_dow" ]] || return 1

    return 0
}

# Queue a batch for execution
scheduler_queue_batch() {
    local name="$1"
    local batch="$2"
    local priority="${3:-normal}"

    local queue_file="$QUEUE_DIR/${name}-$(date +%Y%m%d-%H%M%S).queued"
    cat > "$queue_file" <<EOF
{
  "name": "$name",
  "batch": "$batch",
  "priority": "$priority",
  "queued_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    echo "[scheduler] queued: $name ($batch)"
}

# List all scheduled tasks
scheduler_list() {
    echo "# Scheduled Tasks"
    echo ""

    local count=0
    for config in "$SCHEDULED_DIR"/*.scheduled 2>/dev/null; do
        [[ -f "$config" ]] || continue
        ((count++)) || true

        local info
        info=$(scheduler_load_config "$config")
        IFS='|' read -r name batch cron enabled priority timeout <<< "$info"

        local status="disabled"
        [[ "$enabled" == "true" ]] && status="enabled"
        scheduler_is_due "$cron" && status="DUE"

        echo "| $name | $cron | $status | $batch |"
    done

    echo ""
    echo "Total: $count scheduled tasks"
}

# Show tasks due now
scheduler_show_due() {
    echo "# Tasks Due Now"
    echo ""

    for config in "$SCHEDULED_DIR"/*.scheduled 2>/dev/null; do
        [[ -f "$config" ]] || continue

        local info
        info=$(scheduler_load_config "$config")
        IFS='|' read -r name batch cron enabled priority timeout <<< "$info"

        [[ "$enabled" != "true" ]] && continue
        scheduler_is_due "$cron" || continue

        echo "• $name (batch: $batch, cron: $cron)"
    done
}

# Run queued tasks
scheduler_run_queued() {
    local running=0

    for queue_file in "$QUEUE_DIR"/*.queued 2>/dev/null; do
        [[ -f "$queue_file" ]] || continue

        # Check concurrent limit
        [[ "$running" -ge "$MAX_CONCURRENT" ]] && break

        local name batch priority queued_at
        name=$(jq -r '.name' "$queue_file")
        batch=$(jq -r '.batch' "$queue_file")
        priority=$(jq -r '.priority' "$queue_file")
        queued_at=$(jq -r '.queued_at' "$queue_file")

        echo "[scheduler] executing: $name"

        # Run the batch
        "$SCRIPT_DIR/task-dispatch.sh" ".orchestration/tasks/$batch/" 2>&1 &
        local pid=$!

        # Log execution
        local history_file="$HISTORY_DIR/${name}-history.json"
        local new_entry=$(mktemp)

        jq --arg name "$name" --arg batch "$batch" --arg queued_at "$queued_at" --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pid "$pid" \
            '{name: $name, batch: $batch, queued_at: $queued_at, started_at: $started_at, pid: ($pid | tonumber), status: "running"}' \
            > "$new_entry"

        # Append to history
        if [[ -f "$history_file" ]]; then
            jq ".runs += [$new_entry]" "$history_file" > "${history_file}.tmp" && mv "${history_file}.tmp" "$history_file"
        else
            echo '{"runs": []}' > "$history_file"
            jq ".runs += [$new_entry]" "$history_file" > "${history_file}.tmp" && mv "${history_file}.tmp" "$history_file"
        fi

        rm -f "$queue_file"
        ((running++)) || true
    done

    echo "[scheduler] running $running tasks in parallel"
}

# Full check cycle
scheduler_check() {
    echo "[scheduler] $(date)"

    scheduler_show_due

    scheduler_run_queued
}

# Main
case "${1:-}" in
    list)  scheduler_list ;;
    due)   scheduler_show_due ;;
    queue) scheduler_run_queued ;;
    run)   scheduler_run_queued ;;
    check) scheduler_check ;;
    *)     usage ;;
esac
