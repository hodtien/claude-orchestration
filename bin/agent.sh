#!/usr/bin/env bash
# agent.sh — Multi-agent CLI wrapper (global install)
# Detects project root via git, writes audit log per-project.
#
# Usage:
#   agent.sh <copilot|gemini|beeknoee> <task_id> <prompt> [timeout_secs=60] [max_retries=2]
#
# Log: <project>/.orchestration/tasks.jsonl
#
# Context pipe:
#   CONTEXT_FILE=.orchestration/results/task-001.out \
#     agent.sh copilot task-002 "Implement based on the analysis"
#
# Beeknoee API key resolution: $BEEKNOEE_API_KEY → project .mcp.json → ~/.claude.json

set -euo pipefail

AGENT="${1:?Usage: agent.sh <copilot|gemini|beeknoee> <task_id> <prompt> [timeout_secs] [max_retries]}"
TASK_ID="${2:?task_id required}"
PROMPT="${3:?prompt required}"
TIMEOUT="${4:-60}"
MAX_RETRIES="${5:-2}"

if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[orch] invalid task_id: '$TASK_ID' (allowed: [A-Za-z0-9._-])" >&2
  exit 2
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOG_DIR="$PROJECT_ROOT/.orchestration"
LOG_FILE="$LOG_DIR/tasks.jsonl"
mkdir -p "$LOG_DIR"

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

# ── agent runners ──────────────────────────────────────────────────────────────

run_copilot() {
  perl -e "alarm($TIMEOUT); exec @ARGV" -- \
    copilot -p "$PROMPT" --allow-all 2>&1
}

run_gemini() {
  perl -e "alarm($TIMEOUT); exec @ARGV" -- \
    gemini --prompt "$PROMPT" --output-format text -y 2>&1
}

run_beeknoee() {
  local api_key="${BEEKNOEE_API_KEY:-}"
  if [ -z "$api_key" ]; then
    # Try project .mcp.json first, then user-scope ~/.claude.json
    api_key=$(_PROJECT_ROOT="$PROJECT_ROOT" python3 -c "
import json, os, pathlib
for p in [
    os.path.join(os.environ['_PROJECT_ROOT'], '.mcp.json'),
    str(pathlib.Path.home() / '.claude.json'),
]:
    try:
        d = json.loads(pathlib.Path(p).read_text())
        key = d.get('mcpServers',{}).get('beeknoee',{}).get('env',{}).get('AI_CHAT_KEY','')
        if key:
            print(key)
            break
    except Exception:
        pass
else:
    print('')
" 2>/dev/null)
  fi
  if [ -z "$api_key" ]; then
    echo "[beeknoee] no API key — set BEEKNOEE_API_KEY or configure .mcp.json / ~/.claude.json"
    return 1
  fi

  local base_url="${BEEKNOEE_BASE_URL:-https://platform.beeknoee.com/api/v1}"
  local model="${BEEKNOEE_MODEL:-claude-sonnet-4-6}"

  local payload
  payload=$(_MODEL="$model" python3 -c "
import json, os
print(json.dumps({
    'model':    os.environ['_MODEL'],
    'messages': [{'role': 'user', 'content': os.environ['_PROMPT']}],
    'stream':   False,
}))")

  local raw status body
  raw=$(perl -e "alarm($TIMEOUT); exec @ARGV" -- \
    curl -s -X POST "$base_url/chat/completions" \
      -H "Authorization: Bearer $api_key" \
      -H "Content-Type: application/json" \
      -w $'\n__HTTP_STATUS__=%{http_code}' \
      -d "$payload" 2>&1) || {
    echo "[beeknoee] curl failed (network/timeout): $raw"
    return 1
  }

  status=$(printf '%s' "$raw" | sed -n 's/^__HTTP_STATUS__=\(.*\)$/\1/p' | tail -1)
  body=$(printf '%s' "$raw" | sed '/^__HTTP_STATUS__=/d')

  if [ "$status" != "200" ]; then
    echo "[beeknoee] HTTP $status from $base_url/chat/completions"
    echo "[beeknoee] body: $(printf '%s' "$body" | head -c 500)"
    return 1
  fi

  printf '%s' "$body" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['choices'][0]['message']['content'])
except (json.JSONDecodeError, KeyError, IndexError) as e:
    print(f'[beeknoee] malformed response: {type(e).__name__}: {e}')
    sys.exit(1)
" 2>&1
}

run_agent() {
  local start output exit_code duration
  start=$(date +%s)

  case "$AGENT" in
    copilot)  output=$(run_copilot)  && exit_code=0 || exit_code=$? ;;
    gemini)   output=$(run_gemini)   && exit_code=0 || exit_code=$? ;;
    beeknoee) output=$(run_beeknoee) && exit_code=0 || exit_code=$? ;;
    *)
      echo "[orch] Unknown agent: $AGENT (valid: copilot, gemini, beeknoee)" >&2
      exit 1 ;;
  esac

  duration=$(( $(date +%s) - start ))

  if [ "$exit_code" -eq 0 ]; then
    log_event "complete" "success" "$duration" "$output" ""
    printf '%s\n' "$output"
    return 0
  else
    log_event "complete" "failed" "$duration" "" "$output"
    return 1
  fi
}

# ── orchestration loop ────────────────────────────────────────────────────────

log_event "start" "running" 0 "" ""
echo "[orch] task=$TASK_ID agent=$AGENT timeout=${TIMEOUT}s retries=$MAX_RETRIES project=$PROJECT_ROOT" >&2

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
