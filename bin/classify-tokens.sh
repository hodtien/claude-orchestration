#!/usr/bin/env bash
# classify-tokens.sh — Budget-Tiered Task Triage Classifier
# Routes tasks into tiers based on estimated token budget and intent clarity.
#
# Usage:
#   ./classify-tokens.sh <task-spec-file>
#   ./classify-tokens.sh --tier-only <task-spec-file>  # output tier only
#
# Output:
#   TIER_MICRO|TIER_STANDARD|TIER_COMPLEX|TIER_CRITICAL
#   tokens_estimated=<n>
#   intent_clarity=<high|medium|low>
#   reasoning=<explanation>

set -euo pipefail

# Tier thresholds
MICRO_THRESHOLD=100
STANDARD_THRESHOLD=5000
COMPLEX_THRESHOLD=50000

usage() {
    cat <<EOF
Usage: $0 <task-spec-file>
       $0 --tier-only <task-spec-file>

Budget-Tiered Task Triage Classifier

Tiers:
  TIER_MICRO     — <$MICRO_THRESHOLD tokens, clear intent         → direct execution
  TIER_STANDARD  — $MICRO_THRESHOLD-$STANDARD_THRESHOLD tokens    → normal dispatch
  TIER_COMPLEX   — $STANDARD_THRESHOLD-$COMPLEX_THRESHOLD tokens  → full pipeline + DAG
  TIER_CRITICAL  — >$COMPLEX_THRESHOLD tokens or ambiguous       → council protocol

Exit codes:
  0  — success
  1  — error (file not found, etc.)
EOF
    exit 0
}

TIER_ONLY=false
[[ "${1:-}" == "--tier-only" ]] && TIER_ONLY=true && shift
TASK_FILE="${1:-}"

if [[ -z "$TASK_FILE" ]] || [[ ! -f "$TASK_FILE" ]]; then
    echo "Error: task file not found: $TASK_FILE" >&2
    exit 1
fi

# Extract word count from Instructions section
word_count=$(awk '
    /^## Instructions$/,0 {
        if (NR > 1 && /^## /) next
        if (/^## Instructions$/) { skip=1; next }
        if (skip) gsub(/[^a-zA-Z0-9]/, " ")
    }
    { if (skip) print }
' "$TASK_FILE" | wc -w | tr -d ' ')

# Default word count if Instructions section is empty
[[ -z "$word_count" ]] && word_count=0

# Estimate tokens: words × 1.3 + buffer for context
tokens_estimated=$((word_count * 13 / 10 + 200))

# Read intent_clarity from frontmatter
intent_clarity=$(awk '
    /^intent_clarity:/ {
        gsub(/^intent_clarity: */, "")
        print tolower($0)
        exit
    }
' "$TASK_FILE" 2>/dev/null || echo "medium")

# Read task_type
task_type=$(awk '
    /^task_type:/ {
        gsub(/^task_type: */, "")
        print tolower($0)
        exit
    }
' "$TASK_FILE" 2>/dev/null || echo "unknown")

# Read complexity markers from content
has_ambiguity=false
has_multiagent=false
has_council=false

if grep -qiE '(ambiguous|unclear|conflicting|tbd)' "$TASK_FILE"; then
    has_ambiguity=true
fi
if grep -qiE '(parallel|concurrent|multi-agent|agents.*multiple)' "$TASK_FILE"; then
    has_multiagent=true
fi
if grep -qiE '(council|debate|consensus|vote)' "$TASK_FILE"; then
    has_council=true
fi

# Determine tier
if [[ "$intent_clarity" == "low" ]] || [[ "$has_ambiguity" == "true" ]] || [[ "$has_council" == "true" ]]; then
    tier="TIER_CRITICAL"
    reasoning="ambiguous intent or requires council"
elif [[ "$tokens_estimated" -lt $MICRO_THRESHOLD ]] && [[ "$intent_clarity" == "high" ]]; then
    tier="TIER_MICRO"
    reasoning="micro task (<100 tokens, high clarity)"
elif [[ "$tokens_estimated" -lt $STANDARD_THRESHOLD ]]; then
    tier="TIER_STANDARD"
    reasoning="standard task ($tokens_estimated tokens)"
elif [[ "$tokens_estimated" -lt $COMPLEX_THRESHOLD ]] || [[ "$has_multiagent" == "true" ]]; then
    tier="TIER_COMPLEX"
    reasoning="complex task ($tokens_estimated tokens or multi-agent)"
else
    tier="TIER_CRITICAL"
    reasoning="large or ambiguous task ($tokens_estimated tokens)"
fi

if $TIER_ONLY; then
    echo "$tier"
else
    echo "tier=$tier"
    echo "tokens_estimated=$tokens_estimated"
    echo "intent_clarity=$intent_clarity"
    echo "task_type=$task_type"
    echo "reasoning=$reasoning"
fi
