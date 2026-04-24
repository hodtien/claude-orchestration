#!/usr/bin/env bash
# task-status.sh — unified terminal-state JSON for every dispatched task
#
# Phase 8.1: writes ${tid}.status.json atomically at terminal state.
# Single source of truth for downstream consumers (dashboards, metrics, inbox).
#
# NOTE: Do NOT use set -e in this file. Sourced by callers.

# Atomic write: tmp -> rename. Respects STATUS_JSON_DISABLED=1 kill switch at call-time.
write_task_status() {
    [ "${STATUS_JSON_DISABLED:-0}" = "1" ] && return 0
    local tid="$1"
    local json_blob="$2"
    local results_dir="${RESULTS_DIR:-.orchestration/results}"
    mkdir -p "$results_dir"
    printf '%s' "$json_blob" > "$results_dir/.${tid}.status.json.tmp" || return 1
    mv "$results_dir/.${tid}.status.json.tmp" "$results_dir/${tid}.status.json"
}

# Build status JSON from CLI args. Fields (positional):
# tid task_type strategy final_state output_file output_bytes winner_agent
# candidates_tried_csv successful_candidates_csv consensus_score
# reflexion_iterations markers_csv duration_sec started_at completed_at
build_status_json() {
    python3 - "$@" <<'PYEOF'
import sys, json

(_, tid, task_type, strategy, final_state, output_file, output_bytes,
 winner_agent, cand_csv, succ_csv, score, refl_iter, markers_csv,
 duration, started_at, completed_at) = sys.argv

def csv(s):
    return [t for t in s.split(",") if t]

obj = {
    "schema_version": 1,
    "task_id": tid,
    "task_type": task_type,
    "strategy_used": strategy,
    "final_state": final_state,
    "output_file": output_file,
    "output_bytes": int(output_bytes) if output_bytes else 0,
    "winner_agent": winner_agent if winner_agent and winner_agent != "null" else None,
    "candidates_tried": csv(cand_csv),
    "successful_candidates": csv(succ_csv),
    "consensus_score": float(score) if score else 0.0,
    "reflexion_iterations": int(refl_iter) if refl_iter else 0,
    "markers": csv(markers_csv),
    "duration_sec": float(duration) if duration else 0.0,
    "started_at": started_at,
    "completed_at": completed_at,
}
print(json.dumps(obj, indent=2))
PYEOF
}