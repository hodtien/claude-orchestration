#!/usr/bin/env bash
# agent.sh — CLI-based Multi-agent wrapper
# Routes all agent calls through gemini-cli or copilot-cli directly.
#
# Usage:
#   agent.sh <agent-combo> <task_id> <prompt> [timeout_secs=60] [max_retries=2]
#
# Supported agents:
#   gemini-deep  — gemini-cli with gemini-3.1-pro-preview (deep reasoning)
#   gemini-fast  — gemini-cli with gemini-2.5-flash (balanced, fast)
#   copilot      — copilot-cli with gpt-5.3-codex (code implementation)
#   gh-code      — copilot-cli (same as copilot, code-heavy)
#   gh-thin      — copilot-cli (lightweight tasks)
#   gemini       — alias for gemini-fast
#
# Legacy aliases:
#   copilot → copilot
#
# Log: <project>/.orchestration/tasks.jsonl
#
# Context pipe:
#   CONTEXT_FILE=.orchestration/results/task-001.out \
#     agent.sh gemini-fast task-002 "Implement based on the analysis"

set -euo pipefail

AGENT="${1:?Usage: agent.sh <agent> <task_id> <prompt> [max_retries]}"
TASK_ID="${2:?task_id required}"
PROMPT="${3:?prompt required}"
MAX_RETRIES="${4:-2}"

if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[orch] invalid task_id: '$TASK_ID' (allowed: [A-Za-z0-9._-])" >&2
  exit 2
fi

# ── legacy alias mapping ─────────────────────────────────────────────────────
case "$AGENT" in
  gemini)  AGENT="gemini-fast" ;;
  copilot) AGENT="copilot" ;;
esac

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOG_DIR="$PROJECT_ROOT/.orchestration"
LOG_FILE="$LOG_DIR/tasks.jsonl"
mkdir -p "$LOG_DIR"
CHILD_PID=""
PARTIAL_OUTPUT_FILE=""

save_partial_output() {
  local ts waited
  trap - TERM INT
  if [ -n "${CHILD_PID:-}" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    waited=0
    while kill -0 "$CHILD_PID" 2>/dev/null && [ "$waited" -lt 5 ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$CHILD_PID" 2>/dev/null; then
      kill -KILL "$CHILD_PID" 2>/dev/null || true
    fi
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  CHILD_PID=""
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  if [ -n "${PARTIAL_OUTPUT_FILE:-}" ] && [ -f "$PARTIAL_OUTPUT_FILE" ]; then
    printf '\n\n--- CANCELLED at %s ---\n' "$ts" >> "$PARTIAL_OUTPUT_FILE"
    cat "$PARTIAL_OUTPUT_FILE"
    rm -f "$PARTIAL_OUTPUT_FILE"
  else
    printf '\n\n--- CANCELLED at %s ---\n' "$ts"
  fi
  PARTIAL_OUTPUT_FILE=""
  exit 130
}

trap 'save_partial_output' TERM

# ── context pipe ──────────────────────────────────────────────────────────────
if [ -n "${CONTEXT_FILE:-}" ]; then
  if [ ! -f "$CONTEXT_FILE" ]; then
    echo "[orch] CONTEXT_FILE not found: $CONTEXT_FILE" >&2; exit 1
  fi
  context_content=$(cat "$CONTEXT_FILE")
  PROMPT="$(printf 'Context from previous step:\n---\n%s\n---\n\nTask: %s' "$context_content" "$PROMPT")"
  echo "[orch] context loaded from $CONTEXT_FILE ($(wc -c < "$CONTEXT_FILE") bytes)" >&2
fi

# ── helpers ───────────────────────────────────────────────────────────────────

log_event() {
  local event="$1" status="$2" duration_s="$3" output="$4" error="$5"
  python3 - "$event" "$status" "$duration_s" "$output" "$error" <<'PYEOF'
import sys, json, datetime, os
_, event, status, duration_s, output, error = sys.argv
print(json.dumps({
    "ts":           datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "event":        event,
    "task_id":      os.environ.get("_TASK_ID"),
    "trace_id":     os.environ.get("ORCH_TRACE_ID"),
    "parent_task_id": os.environ.get("ORCH_PARENT_TASK_ID"),
    "agent":        os.environ.get("_AGENT"),
    "project":      os.environ.get("_PROJECT_ROOT"),
    "status":       status,
    "duration_s":   int(duration_s),
    "prompt_chars": int(os.environ.get("_PROMPT_CHARS", 0)),
    "output_chars": len(output),
    "output":       output[:2000],
    "error":        error[:500],
}))
PYEOF
} >> "$LOG_FILE"

export _TASK_ID="$TASK_ID" _AGENT="$AGENT" _PROMPT_CHARS="${#PROMPT}" _PROMPT="$PROMPT" _PROJECT_ROOT="$PROJECT_ROOT"

# ── CLI runners ───────────────────────────────────────────────────────────────

# gemini-cli runner
run_gemini() {
  local gemini_model="${1:-gemini-2.5-flash}"
  # Write prompt to temp file to handle multiline correctly
  local prompt_file
  prompt_file=$(mktemp "/tmp/orch-gemini-$$.XXXXXX")
  printf '%s' "$PROMPT" > "$prompt_file"

  # Read prompt and pipe to gemini CLI
  gemini -m "$gemini_model" -p "$(cat "$prompt_file")" 2>&1
  local exit_code=$?
  rm -f "$prompt_file"
  return $exit_code
}

# copilot-cli runner
run_copilot() {
  # Write prompt to temp file
  local prompt_file
  prompt_file=$(mktemp "/tmp/orch-copilot-$$.XXXXXX")
  printf '%s' "$PROMPT" > "$prompt_file"

  copilot --model gpt-5.3-codex -p "$(cat "$prompt_file")" 2>&1
  local exit_code=$?
  rm -f "$prompt_file"
  return $exit_code
}

run_agent() {
  local start output exit_code duration
  start=$(date +%s)
  PARTIAL_OUTPUT_FILE="$LOG_DIR/.${TASK_ID}.partial.$$"
  : > "$PARTIAL_OUTPUT_FILE"

  # Dispatch to appropriate CLI based on agent name
  case "$AGENT" in
    gemini-deep|gemini-deep-preview)
      run_gemini "gemini-3.1-pro-preview" > "$PARTIAL_OUTPUT_FILE" 2>&1
      ;;
    gemini-fast|gemini-flash|gemini-2.5-flash)
      run_gemini "gemini-2.5-flash" > "$PARTIAL_OUTPUT_FILE" 2>&1
      ;;
    gemini-lite|gemini-3.1-flash-lite-preview)
      run_gemini "gemini-3.1-flash-lite-preview" > "$PARTIAL_OUTPUT_FILE" 2>&1
      ;;
    gemini|gemini-pro|gemini-3.1-pro-preview)
      # Default: gemini-3.1-pro-preview for pro-tier tasks
      run_gemini "gemini-3.1-pro-preview" > "$PARTIAL_OUTPUT_FILE" 2>&1
      ;;
    copilot|gh-code|gh-thin)
      run_copilot > "$PARTIAL_OUTPUT_FILE" 2>&1
      ;;
    *)
      echo "[orch] ERROR: unknown agent '$AGENT'" >&2
      echo "[orch] Known agents: gemini-deep, gemini-fast, gemini, copilot, gh-code, gh-thin" >&2
      return 1
      ;;
  esac

  exit_code=$?
  output=$(cat "$PARTIAL_OUTPUT_FILE")
  rm -f "$PARTIAL_OUTPUT_FILE"
  PARTIAL_OUTPUT_FILE=""

  duration=$(( $(date +%s) - start ))

  if [ "$exit_code" -eq 0 ]; then
    log_event "complete" "success" "$duration" "$output" ""
    printf '%s\n' "$output"
    return 0
  elif [ "$exit_code" -gt 127 ]; then
    # Signal / cancelled
    log_event "complete" "failed" "$duration" "" "cancelled signal=$exit_code"
    return 1
  else
    log_event "complete" "failed" "$duration" "$output" "exit_code=$exit_code"
    printf '%s\n' "$output"
    return 1
  fi
}

# ── orchestration loop ───────────────────────────────────────────────────────

log_event "start" "running" 0 "" ""
echo "[orch] task=$TASK_ID agent=$AGENT retries=$MAX_RETRIES project=$PROJECT_ROOT" >&2

attempt=0
while [ "$attempt" -le "$MAX_RETRIES" ]; do
  if [ "$attempt" -gt 0 ]; then
    backoff=$(( attempt * 2 ))
    echo "[orch] retry $attempt/$MAX_RETRIES (backoff ${backoff}s)..." >&2
    log_event "retry" "retrying" 0 "" "attempt $attempt"
    sleep "$backoff"
  fi

  if run_agent; then
    echo "[orch] done (attempt $(( attempt + 1 )))" >&2
    exit 0
  fi

  attempt=$(( attempt + 1 ))
done

log_event "complete" "exhausted" 0 "" "all retries failed"
echo "[orch] FAILED after $MAX_RETRIES retries" >&2
exit 1
