#!/usr/bin/env bash
# hybrid-resolver.sh — Phase 10 Hybrid Dispatch resolver
# Decides per task whether to dispatch via async batch (task-dispatch.sh) or
# interactive Agent tool subagent.
#
# NOTE: Do NOT use set -e — this lib is SOURCEd by callers that manage their own
# error handling (task-dispatch.sh, /dispatch command, tests).

# bash 3.2 safe — no associative arrays, no namerefs.

PROJECT_ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
HYBRID_MODELS_YAML="${HYBRID_MODELS_YAML:-${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}/config/models.yaml}"

# ── policy reader ─────────────────────────────────────────────────────────────
# _hybrid_policy_get KEY DEFAULT
# Reads hybrid_policy.<KEY> from models.yaml. Echoes value or DEFAULT on miss.
_hybrid_policy_get() {
  local key="$1"
  local default="$2"
  local val=""
  if [ -f "$HYBRID_MODELS_YAML" ] && command -v yq >/dev/null 2>&1; then
    val="$(yq -r ".hybrid_policy.${key} // \"\"" "$HYBRID_MODELS_YAML" 2>/dev/null)"
  fi
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    echo "$default"
  else
    echo "$val"
  fi
}

# _hybrid_task_field TASK_TYPE FIELD DEFAULT
# Reads task_mapping.<TASK_TYPE>.<FIELD>. Echoes value or DEFAULT.
_hybrid_task_field() {
  local task_type="$1"
  local field="$2"
  local default="$3"
  local val=""
  if [ -f "$HYBRID_MODELS_YAML" ] && command -v yq >/dev/null 2>&1; then
    val="$(yq -r ".task_mapping.\"${task_type}\".${field} // \"\"" "$HYBRID_MODELS_YAML" 2>/dev/null)"
  fi
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    echo "$default"
  else
    echo "$val"
  fi
}

# ── core API ──────────────────────────────────────────────────────────────────
# resolve_dispatch_mode TASK_TYPE TASK_COUNT PROMPT_LENGTH HAS_DEPENDS HAS_CONSENSUS
# Echoes "async" or "interactive". Never errors — always returns a usable value.
#
# Heuristics (evaluated in order — first match wins):
#   1. explicit mode in task_mapping (async|interactive) → use it
#   2. mode=auto + has_consensus=true → async
#   3. mode=auto + has_depends=true   → async
#   4. mode=auto + task_count >= interactive_threshold_tasks → async
#   5. mode=auto + prompt_length > interactive_max_prompt_chars → async
#   6. otherwise → interactive
resolve_dispatch_mode() {
  local task_type="${1:-default}"
  local task_count="${2:-1}"
  local prompt_length="${3:-0}"
  local has_depends="${4:-false}"
  local has_consensus="${5:-false}"

  local default_mode
  default_mode="$(_hybrid_policy_get default_mode auto)"

  local mode
  mode="$(_hybrid_task_field "$task_type" mode "$default_mode")"

  case "$mode" in
    async|interactive) echo "$mode"; return 0 ;;
  esac

  if [ "$has_consensus" = "true" ]; then
    echo "async"; return 0
  fi
  if [ "$has_depends" = "true" ]; then
    echo "async"; return 0
  fi

  local threshold
  threshold="$(_hybrid_policy_get interactive_threshold_tasks 2)"
  case "$threshold" in ''|*[!0-9]*) threshold=2 ;; esac
  if [ "$task_count" -ge "$threshold" ] 2>/dev/null; then
    echo "async"; return 0
  fi

  local max_chars
  max_chars="$(_hybrid_policy_get interactive_max_prompt_chars 8000)"
  case "$max_chars" in ''|*[!0-9]*) max_chars=8000 ;; esac
  if [ "$prompt_length" -gt "$max_chars" ] 2>/dev/null; then
    echo "async"; return 0
  fi

  echo "interactive"
  return 0
}

# resolve_interactive_agent TASK_TYPE
# Echoes the Agent tool subagent_type for interactive dispatch.
resolve_interactive_agent() {
  local task_type="${1:-default}"
  _hybrid_task_field "$task_type" interactive_agent general-purpose
}

# should_escalate_on_exhausted
should_escalate_on_exhausted() {
  local val
  val="$(_hybrid_policy_get escalate_on_exhausted true)"
  case "$val" in true|True|TRUE|1|yes) echo "true" ;; *) echo "false" ;; esac
}

