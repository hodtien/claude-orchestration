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

AGENT="${1:?Usage: agent.sh <agent> <task_id> <prompt> [timeout_secs=60] [max_retries=2]}"
TASK_ID="${2:?task_id required}"
PROMPT="${3:?prompt required}"
TIMEOUT_SECS="${4:-60}"
MAX_RETRIES="${5:-2}"
# Safety: max partial output file size (default 5MB)
MAX_PARTIAL_BYTES="${MAX_PARTIAL_BYTES:-5242880}"

# Validate numeric args — prevents timeout being misread as retries
if ! [[ "$TIMEOUT_SECS" =~ ^[0-9]+$ ]]; then
  echo "[orch] WARN: invalid timeout_secs '$TIMEOUT_SECS', defaulting to 60" >&2
  TIMEOUT_SECS=60
fi
if ! [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
  echo "[orch] WARN: invalid max_retries '$MAX_RETRIES', defaulting to 2" >&2
  MAX_RETRIES=2
fi
# Hard cap retries to prevent runaway loops (was the root cause of 152G file)
if [ "$MAX_RETRIES" -gt 8 ]; then
  echo "[orch] WARN: max_retries clamped from $MAX_RETRIES to 8" >&2
  MAX_RETRIES=8
fi

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

cleanup_partial() {
  if [ -n "${PARTIAL_OUTPUT_FILE:-}" ] && [ -f "$PARTIAL_OUTPUT_FILE" ]; then
    rm -f "$PARTIAL_OUTPUT_FILE"
  fi
}
trap 'save_partial_output' TERM
trap 'cleanup_partial' EXIT

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

export _TASK_ID="$TASK_ID" _AGENT="$AGENT" _PROMPT_CHARS="${#PROMPT}" _PROMPT="$PROMPT" _PROJECT_ROOT="$PROJECT_ROOT" _TIMEOUT_SECS="$TIMEOUT_SECS"

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

# router (9Router) runner — for router-channel agents like minimax-code
run_router() {
  local model="${1:-minimax-code}"
  local prompt_file
  prompt_file=$(mktemp "/tmp/orch-router-$$.XXXXXX")
  printf '%s' "$PROMPT" > "$prompt_file"

  python3 - "$model" "$prompt_file" <<'PYEOF'
import json, os, sys, subprocess
model = sys.argv[1]
prompt_file = sys.argv[2]
with open(os.path.expanduser("~/.claude/settings.json")) as f:
    token = json.load(f)["env"]["ANTHROPIC_AUTH_TOKEN"]
with open(prompt_file) as f:
    prompt = f.read()
timeout_s = int(os.environ.get("_TIMEOUT_SECS", "60") or "60")
result = subprocess.run([
    "curl", "-s", "-X", "POST", "http://localhost:20128/v1/messages",
    "-H", "Content-Type: application/json",
    "-H", "anthropic-version: 2023-06-01",
    "-H", f"x-api-key: {token}",
    "-d", json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": 4096, "stream": False})
], capture_output=True, text=True, timeout=timeout_s)
try:
    data = json.loads(result.stdout)
    for block in data.get("content", []):
        if block.get("type") == "text":
            print(block.get("text", ""), end="", flush=True)
            break
    else:
        for block in data.get("content", []):
            if block.get("type") == "thinking":
                print("[thinking]", end="", flush=True)
                break
except json.JSONDecodeError:
    print(result.stdout[:500] if result.stdout else "[empty response]", end="", flush=True)
PYEOF

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

# Claude Code CLI runner — tool-enabled local execution
# Uses claude -p with --allowedTools so agents can Read/Write/Bash/Grep/Glob
# Model aliases (oc-medium, oc-high, etc.) resolved by ~/.claude/settings.json models config
run_claude_code() {
  local model="$1"
  local prompt_file
  prompt_file=$(mktemp "/tmp/orch-claude-$$.XXXXXX")
  printf '%s' "$PROMPT" > "$prompt_file"

  claude -p \
    --model "$model" \
    --allowedTools "Read,Write,Bash,Grep,Glob" \
    < "$prompt_file" 2>&1
  local exit_code=$?
  rm -f "$prompt_file"
  return $exit_code
}

run_agent() {
  local start output exit_code duration
  local partial_size=0
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
    minimax-code|minimax|minimax_flash)
      run_router "minimax-code" > "$PARTIAL_OUTPUT_FILE" 2>&1
      ;;
    oc-high|oc-medium|oc-low|claude-review|claude-review-backup|claude-architect|claude-architect-backup)
      run_claude_code "$AGENT" > "$PARTIAL_OUTPUT_FILE" 2>&1
      ;;
    cc/*)
      run_router "$AGENT" > "$PARTIAL_OUTPUT_FILE" 2>&1
      ;;
    *)
      echo "[orch] ERROR: unknown agent '$AGENT'" > "$PARTIAL_OUTPUT_FILE"
      echo "[orch] Known: gemini-deep, gemini-fast, gemini, copilot, gh-code, gh-thin, minimax-code, cc/*, oc-high, oc-medium, oc-low, claude-review, claude-architect" >> "$PARTIAL_OUTPUT_FILE"
      exit_code=1
      ;;
  esac

  # If case branch actually executed a command, capture its exit code
  if [ -z "${exit_code+x}" ]; then
    exit_code=$?
  fi

  partial_size=$(wc -c < "$PARTIAL_OUTPUT_FILE" | tr -d ' ')
  if [ "$partial_size" -gt "$MAX_PARTIAL_BYTES" ]; then
    output="$(head -c "$MAX_PARTIAL_BYTES" "$PARTIAL_OUTPUT_FILE")\n\n[orch] NOTE: output truncated from ${partial_size} bytes to ${MAX_PARTIAL_BYTES} bytes"
  else
    output=$(cat "$PARTIAL_OUTPUT_FILE")
  fi

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
