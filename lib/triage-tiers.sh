#!/usr/bin/env bash
# triage-tiers.sh — Budget-Tiered Task Triage Routing Library
# Source this file to get tier-based routing functions.

# bash 3.x (macOS default) doesn't support associative arrays
if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
    return 0 2>/dev/null || exit 0
fi

# Tier definitions
readonly TIER_MICRO_VAL="TIER_MICRO"
readonly TIER_STANDARD_VAL="TIER_STANDARD"
readonly TIER_COMPLEX_VAL="TIER_COMPLEX"
readonly TIER_CRITICAL_VAL="TIER_CRITICAL"

# Agent routing per tier
declare -A TIER_AGENTS=(
    ["$TIER_MICRO_VAL"]="haiku"
    ["$TIER_STANDARD_VAL"]="copilot"
    ["$TIER_COMPLEX_VAL"]="copilot"
    ["$TIER_CRITICAL_VAL"]="gemini"
)

# Timeout per tier (seconds)
declare -A TIER_TIMEOUTS=(
    ["$TIER_MICRO_VAL"]=60
    ["$TIER_STANDARD_VAL"]=180
    ["$TIER_COMPLEX_VAL"]=300
    ["$TIER_CRITICAL_VAL"]=480
)

# Features enabled per tier
declare -A TIER_FEATURES=(
    ["$TIER_MICRO_VAL"]="direct-exec"
    ["$TIER_STANDARD_VAL"]="dispatch"
    ["$TIER_COMPLEX_VAL"]="dispatch+dag+checkpoint"
    ["$TIER_CRITICAL_VAL"]="dispatch+council+intent-fork"
)

# Get agent for tier
triage_get_agent() {
    local tier="$1"
    echo "${TIER_AGENTS[$tier]:-copilot}"
}

# Get timeout for tier
triage_get_timeout() {
    local tier="$1"
    echo "${TIER_TIMEOUTS[$tier]:-180}"
}

# Get features for tier
triage_get_features() {
    local tier="$1"
    echo "${TIER_FEATURES[$tier]:-dispatch}"
}

# Check if tier requires council
triage_requires_council() {
    local tier="$1"
    [[ "$tier" == "$TIER_CRITICAL_VAL" ]]
}

# Check if tier requires DAG
triage_requires_dag() {
    local tier="$1"
    [[ "$tier" == "$TIER_COMPLEX_VAL" ]] || [[ "$tier" == "$TIER_CRITICAL_VAL" ]]
}

# Check if tier supports direct execution
triage_supports_direct_exec() {
    local tier="$1"
    [[ "$tier" == "$TIER_MICRO_VAL" ]]
}

# Log tier assignment
triage_log() {
    local task_id="$1"
    local tier="$2"
    local tokens="$3"
    local intent="$4"
    local routing="$5"

    local log_file="${ORCH_DIR:-.}/audit.jsonl"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

    cat >> "$log_file" <<EOF
{"event":"tier_assigned","task_id":"$task_id","tier":"$tier","tokens_estimated":$tokens,"intent_clarity":"$intent","routing_decision":"$routing","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
}
