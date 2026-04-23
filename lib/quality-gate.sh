#!/usr/bin/env bash
# quality-gate.sh — Quality gates + reflexion loop for Phase 6.2 / 7.3
# Provides: check_quality_gate, trigger_reflexion
#
# NOTE: Do NOT use "set -e" in this file.
# This lib is SOURCEd by task-dispatch.sh which uses its own error-handling.
# Using set -e here would break error-tolerant patterns (|| true) in the caller.
# Individual functions handle their own errors with explicit return codes.

ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
RESULTS_DIR="$ORCH_DIR/results"
REFLEXION_DIR="$ORCH_DIR/reflexions"

mkdir -p "$REFLEXION_DIR"

# ── check_quality_gate ──────────────────────────────────────────────────────────
# Basic assertions: output length, no TODO/FIXME alone, JSON valid if required
# Input: output_file log_file task_id
# Output: "pass" | "fail:${reason}"
# Exit: 0 = pass, 1 = fail
check_quality_gate() {
  local output_file="$1" log_file="$2" tid="$3"
  local min_length="${MIN_OUTPUT_LENGTH:-20}"

  # Output file must exist
  if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
    echo "fail:no_output_file"
    return 1
  fi

  # Read content once for all pattern checks
  local content
  content=$(cat "$output_file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  local size=${#content}

  # Check for TODO/FIXME placeholder patterns FIRST (before length check)
  # These are P0 failures regardless of length
  if echo "$content" | grep -qE "^(todo|fixme|wip|not implemented|coming soon)$"; then
    echo "fail:placeholder_output"
    return 1
  fi
  if echo "$content" | grep -qE "^todo:|^fixme:|^todo |^fixme "; then
    echo "fail:placeholder_output"
    return 1
  fi

  # Length check (only for non-placeholder content)
  if [ "$size" -lt "$min_length" ]; then
    echo "fail:output_too_short:${size}chars"
    return 1
  fi

  echo "pass"
  return 0
}

# ── trigger_reflexion ──────────────────────────────────────────────────────────
# Creates a reflexion log entry + revision marker for the task
# Max 2 revision iterations
# Input: tid output_file gate_result
# Output: writes reflexion JSON + needs_revision marker
trigger_reflexion() {
  local tid="$1" output_file="$2" gate_result="$3"
  local reflexion_file="$REFLEXION_DIR/${tid}.reflexion.json"

  # Count existing revision attempts by scanning reflexion dir for this tid
  local rev_count=0
  rev_count=$(find "$REFLEXION_DIR" -maxdepth 1 -name "${tid}.*.reflexion.json" -type f 2>/dev/null | wc -l | tr -d ' ')

  if [ "$rev_count" -ge 2 ]; then
    echo "[reflexion] ⛔ max revisions reached for $tid (2/2)" >&2
    return 0
  fi

  # Read failure reason from gate_result
  local reason="quality_gate_failed"
  if [ "$gate_result" != "pass" ]; then
    reason="$gate_result"
  fi

  # Extract last output for critic feedback
  local last_output=""
  if [ -f "$output_file" ]; then
    last_output=$(cat "$output_file" 2>/dev/null | head -100)
  fi

  # Write reflexion log — use revision_count as suffix to allow multiple attempts
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local revision_label=$((rev_count + 1))
  python3 - "$tid" "$reason" "$last_output" "$revision_label" "$timestamp" "$REFLEXION_DIR" <<'PYEOF'
import json, sys, os
tid = sys.argv[1]
reason = sys.argv[2]
last_output = sys.argv[3]
revision_label = sys.argv[4]
ts = sys.argv[5]
dir_path = sys.argv[6]

entry = {
    "task_id": tid,
    "reason": reason,
    "last_output": last_output[:500],
    "revision_count": int(revision_label),
    "created_at": ts,
    "status": "pending"
}

path = os.path.join(dir_path, f"{tid}.v{revision_label}.reflexion.json")
with open(path, "w") as f:
    json.dump(entry, f, indent=2)
print(path)
PYEOF

  echo "[reflexion] 🔄 revision $((rev_count + 1))/2 created for $tid — reason: $reason" >&2

  # Mark task for PM review by creating a needs_revision marker
  echo "needs_revision" > "$RESULTS_DIR/${tid}.needs_revision"

  return 0
}
