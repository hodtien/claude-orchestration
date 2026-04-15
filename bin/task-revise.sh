#!/usr/bin/env bash
# task-revise.sh — Feedback loop: revise a completed task with review feedback
#
# When Claude rejects a subagent's output, this script:
# 1. Reads the original task spec
# 2. Reads the previous output
# 3. Injects Claude's feedback
# 4. Re-dispatches to the same agent with revision context
# 5. Writes new output (versioned: task-id.v2.out, task-id.v3.out, ...)
#
# Usage:
#   task-revise.sh <batch-dir> <task-id> <feedback>
#   task-revise.sh <batch-dir> <task-id> --feedback-file <path>
#
# Example:
#   task-revise.sh .orchestration/tasks/my-batch postgis-analysis \
#     "Output missing connection pool analysis. Focus on pgxpool config in postgis.go lines 300-350."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BATCH_DIR="${1:?Usage: task-revise.sh <batch-dir> <task-id> <feedback|--feedback-file path>}"
TASK_ID="${2:?task-id required}"
FEEDBACK_ARG="${3:?feedback required (string or --feedback-file)}"
FEEDBACK_FILE="${4:-}"

# Resolve absolute path
if [[ ! "$BATCH_DIR" = /* ]]; then
  BATCH_DIR="$(pwd)/$BATCH_DIR"
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RESULTS_DIR="$PROJECT_ROOT/.orchestration/results"

# ── resolve feedback ──────────────────────────────────────────────────────────
feedback=""
if [ "$FEEDBACK_ARG" = "--feedback-file" ]; then
  if [ -z "$FEEDBACK_FILE" ] || [ ! -f "$FEEDBACK_FILE" ]; then
    echo "[revise] feedback file not found: $FEEDBACK_FILE" >&2
    exit 1
  fi
  feedback=$(cat "$FEEDBACK_FILE")
else
  feedback="$FEEDBACK_ARG"
fi

# ── find task spec ────────────────────────────────────────────────────────────
task_spec=""
for spec in "$BATCH_DIR"/task-*.md; do
  [ -f "$spec" ] || continue
  spec_id=$(awk 'BEGIN{n=0} /^---$/{n++; next} n==1 && /^id:/{gsub(/^id:[[:space:]]*/, ""); gsub(/[[:space:]]*#.*/, ""); print; exit}' "$spec")
  if [ "$spec_id" = "$TASK_ID" ]; then
    task_spec="$spec"
    break
  fi
done

if [ -z "$task_spec" ]; then
  echo "[revise] task spec not found for id: $TASK_ID in $BATCH_DIR" >&2
  exit 1
fi

# ── parse spec ────────────────────────────────────────────────────────────────
parse_front() {
  local file="$1" key="$2" default="${3:-}"
  local value
  value=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$file" \
    | grep "^${key}:" \
    | head -1 \
    | sed "s/^${key}:[[:space:]]*//" \
    | sed 's/[[:space:]]*#.*//' \
    | sed 's/^["'\'']\(.*\)["'\''"]$/\1/')
  printf '%s' "${value:-$default}"
}

parse_body() {
  awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$1"
}

agent=$(parse_front "$task_spec" "agent" "gemini")
timeout=$(parse_front "$task_spec" "timeout" "120")
retries=$(parse_front "$task_spec" "retries" "1")
original_prompt=$(parse_body "$task_spec")

# ── find previous output + determine version ──────────────────────────────────
prev_output=""
prev_version=1

# Check versioned outputs first (v3, v2, ...), then base
for v in $(seq 10 -1 2); do
  if [ -f "$RESULTS_DIR/${TASK_ID}.v${v}.out" ]; then
    prev_output=$(cat "$RESULTS_DIR/${TASK_ID}.v${v}.out")
    prev_version=$v
    break
  fi
done

if [ -z "$prev_output" ] && [ -f "$RESULTS_DIR/${TASK_ID}.out" ]; then
  prev_output=$(cat "$RESULTS_DIR/${TASK_ID}.out")
  prev_version=1
fi

if [ -z "$prev_output" ]; then
  echo "[revise] no previous output found for $TASK_ID — nothing to revise" >&2
  exit 1
fi

next_version=$((prev_version + 1))
revision_id="${TASK_ID}.v${next_version}"

echo "[revise] task=$TASK_ID agent=$agent v${prev_version}→v${next_version}"
echo "[revise] feedback: $(printf '%s' "$feedback" | head -c 200)"

# ── build revision prompt ─────────────────────────────────────────────────────
# Structure: original task + previous output + reviewer feedback + revision instructions
revision_prompt="# Revision Request (v${next_version})

## Original Task
${original_prompt}

## Previous Output (v${prev_version})
---
$(printf '%s' "$prev_output" | head -c 8000)
---

## Reviewer Feedback
${feedback}

## Instructions
Revise your previous output based on the reviewer feedback above.
Address each point in the feedback specifically.
Keep what was correct, fix what was flagged.
Do not repeat explanations that were already correct — focus on the changes."

echo "[revise] prompt size: ${#revision_prompt} chars"

# ── dispatch revision ─────────────────────────────────────────────────────────
if "$SCRIPT_DIR/agent.sh" "$agent" "$revision_id" "$revision_prompt" "$timeout" "$retries" \
    > "$RESULTS_DIR/${revision_id}.out" 2> "$RESULTS_DIR/${revision_id}.log"; then
  size=$(wc -c < "$RESULTS_DIR/${revision_id}.out" | tr -d ' ')
  echo "[revise] ✅ ${revision_id} complete (${size} bytes)"
  echo "[revise] output: $RESULTS_DIR/${revision_id}.out"

  # Write revision metadata
  {
    echo "revision: v${next_version}"
    echo "parent: v${prev_version}"
    echo "feedback: $(printf '%s' "$feedback" | head -c 500)"
    echo "timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "agent: $agent"
  } > "$RESULTS_DIR/${revision_id}.meta"

  exit 0
else
  echo "[revise] ❌ ${revision_id} failed" >&2
  exit 1
fi
