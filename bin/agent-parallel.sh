#!/usr/bin/env bash
# agent-parallel.sh — Dispatch multiple agents in parallel, collect results (global install)
#
# Usage:
#   agent-parallel.sh "agent|task_id|prompt[|timeout][|retries]" ...
#
# Results saved to: <project>/.orchestration/results/<task_id>.out

set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 'agent|task_id|prompt [|timeout] [|retries]' ..." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RESULTS_DIR="$PROJECT_ROOT/.orchestration/results"
LOCK_DIR="$PROJECT_ROOT/.orchestration/.locks"
AGENT_SH="$SCRIPT_DIR/agent.sh"
mkdir -p "$RESULTS_DIR" "$LOCK_DIR"

declare -a PIDS=()
declare -a OUT_FILES=()
declare -a LOG_FILES=()
declare -a LABELS=()

START_ALL=$(date +%s)

echo "[parallel] launching ${#@} jobs..." >&2

for spec in "$@"; do
  IFS='|' read -r agent task_id prompt timeout retries <<< "$spec"
  timeout="${timeout:-60}"
  retries="${retries:-2}"

  out_file="$RESULTS_DIR/${task_id}.out"
  log_file="$RESULTS_DIR/${task_id}.log"
  lock_file="$LOCK_DIR/${task_id}.lock"

  # Check for duplicate task_id — skip if already running
  if [ -f "$lock_file" ] && kill -0 "$(cat "$lock_file" 2>/dev/null)" 2>/dev/null; then
    echo "[parallel] ⚠️  skip $task_id ($agent) — already running (pid $(cat "$lock_file"))" >&2
    continue
  fi

  echo "[parallel]   → $task_id ($agent)" >&2

  # Wrap in subshell with lock file (write PID, cleanup on exit)
  (
    echo $$ > "$lock_file"
    trap 'rm -f "$lock_file"' EXIT
    bash "$AGENT_SH" "$agent" "$task_id" "$prompt" "$timeout" "$retries" \
      > "$out_file" 2> "$log_file"
  ) &

  PIDS+=($!)
  OUT_FILES+=("$out_file")
  LOG_FILES+=("$log_file")
  LABELS+=("$task_id ($agent)")
done

declare -a EXIT_CODES=()
ALL_OK=true

for i in "${!PIDS[@]}"; do
  pid="${PIDS[$i]}"
  label="${LABELS[$i]}"
  exit_code=0
  wait "$pid" || exit_code=$?
  EXIT_CODES+=("$exit_code")
  if [ "$exit_code" -eq 0 ]; then
    echo "[parallel] ✅ $label" >&2
  else
    echo "[parallel] ❌ $label (exit $exit_code)" >&2
    ALL_OK=false
  fi
done

ELAPSED=$(( $(date +%s) - START_ALL ))
echo "[parallel] finished in ${ELAPSED}s" >&2

echo ""
for i in "${!LABELS[@]}"; do
  label="${LABELS[$i]}"
  out_file="${OUT_FILES[$i]}"
  exit_code="${EXIT_CODES[$i]}"
  status_icon="✅"
  [ "$exit_code" -ne 0 ] && status_icon="❌"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $status_icon  $label"
  echo "  result saved to: ${out_file/$PROJECT_ROOT\//}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [ -f "$out_file" ] && [ -s "$out_file" ]; then
    cat "$out_file"
  else
    echo "(no output)"
  fi
  echo ""
done

echo "[parallel] results dir: .orchestration/results/" >&2

$ALL_OK && exit 0 || exit 1
