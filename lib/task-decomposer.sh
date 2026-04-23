#!/usr/bin/env bash
# task-decomposer.sh — Task Decomposition Engine
# Break complex tasks into 15-min executable units with dependency graph.

set -euo pipefail

ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
DECOMP_DIR="$ORCH_DIR/decomposed"
TASK_DB="$ORCH_DIR/task-db.jsonl"

mkdir -p "$DECOMP_DIR"

# Complexity thresholds (in estimated tokens)
readonly COMPLEXITY_LOW=500
readonly COMPLEXITY_MEDIUM=2000
readonly COMPLEXITY_HIGH=8000
readonly COMPLEXITY_EXTREME=30000

# Decomposition strategies
readonly STRAT_SEQUENTIAL="sequential"
readonly STRAT_PARALLEL="parallel"
readonly STRAT_PIPELINE="pipeline"

# Estimate complexity from task description
estimate_complexity() {
    local task="$1"
    local file="${2:-}"

    local estimated=500  # baseline

    # Count lines
    if [[ -n "$file" ]] && [[ -f "$file" ]]; then
        local lines
        lines=$(wc -l < "$file")
        estimated=$((estimated + lines * 10))
    fi

    # Keywords that increase complexity
    local keywords="refactor|architecture|security|authentication|payment|database|migration|multi-agent|concurrent"
    local kw_count
    kw_count=$(echo "$task" | grep -cE "$keywords" 2>/dev/null || echo "0")
    estimated=$((estimated + kw_count * 1000))

    # File mentions
    local file_count
    file_count=$(echo "$task" | grep -cE "<<<FILE:|\.sh|\.md|\.json" 2>/dev/null || echo "0")
    estimated=$((estimated + file_count * 300))

    echo "$estimated"
}

# Decompose into 15-min units
decompose_task() {
    local task_id="$1"
    local task_desc="$2"
    local complexity="${3:-500}"

    local output_dir="$DECOMP_DIR/$task_id"
    mkdir -p "$output_dir"

    local units="[]"
    local unit_num=1

    # Split by logical boundaries
    local sections
    sections=$(echo "$task_desc" | awk '/^### / {print NR":"$0}' | cut -d: -f1)

    # Determine strategy
    local strategy="$STRAT_SEQUENTIAL"
    if echo "$task_desc" | grep -qi "parallel\|concurrent\|independent"; then
        strategy="$STRAT_PARALLEL"
    elif echo "$task_desc" | grep -qi "pipeline\|chain\|handoff"; then
        strategy="$STRAT_PIPELINE"
    fi

    # Split into units (max 50 sub-tasks per decomposition)
    local paragraphs
    paragraphs=$(echo "$task_desc" | awk 'BEGIN{RS="\n\n"} {print}' | grep -v "^$")

    local unit_content=""
    local unit_lines=0
    local max_lines_per_unit=80  # ~15 min of work

    while IFS= read -r para; do
        local para_lines
        para_lines=$(echo "$para" | wc -l | tr -d ' ')
        ((unit_lines += para_lines))

        unit_content+="$para"$'\n\n'

        if [[ "$unit_lines" -ge "$max_lines_per_unit" ]]; then
            # Emit unit
            local unit_file="$output_dir/unit-$(printf '%02d' "$unit_num").md"
            cat > "$unit_file" <<EOF
---
id: ${task_id}-unit-${unit_num}
parent: $task_id
unit: $unit_num
strategy: $strategy
priority: normal
estimated_duration: 15
---

# Unit $unit_num of $task_id

$unit_content
EOF
            units=$(echo "$units" | jq ". + [\"$unit_num\"]" 2>/dev/null || echo "$units")
            ((unit_num++)) || true
            unit_content=""
            unit_lines=0
        fi
    done <<< "$paragraphs"

    # Emit final unit if any
    if [[ -n "$unit_content" ]]; then
        local unit_file="$output_dir/unit-$(printf '%02d' "$unit_num").md"
        cat > "$unit_file" <<EOF
---
id: ${task_id}-unit-${unit_num}
parent: $task_id
unit: $unit_num
strategy: $strategy
priority: normal
estimated_duration: 15
---

# Unit $unit_num of $task_id

$unit_content
EOF
        units=$(echo "$units" | jq ". + [\"unit-$(printf '%02d' "$unit_num")\"]" 2>/dev/null || echo "$units")
    fi

    # Generate dependency graph
    if [[ "$strategy" == "$STRAT_PIPELINE" ]]; then
        generate_pipeline_graph "$task_id" "$unit_num" > "$output_dir/dependencies.dot"
    else
        generate_parallel_graph "$task_id" "$unit_num" > "$output_dir/dependencies.dot"
    fi

    # Store decomposition metadata
    local meta_file="$output_dir/meta.json"
    cat > "$meta_file" <<EOF
{
  "task_id": "$task_id",
  "strategy": "$strategy",
  "unit_count": $unit_num,
  "units": $units,
  "complexity_original": $complexity,
  "decomposed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    echo "$output_dir"
}

# Generate pipeline (sequential) dependency graph
generate_pipeline_graph() {
    local task_id="$1"
    local count="$2"

    echo "digraph ${task_id//-/_} {"
    echo "  rankdir=LR;"
    echo "  node [shape=box];"

    for ((i=1; i<=count; i++)); do
        local prev=$((i - 1))
        if [[ "$i" -eq 1 ]]; then
            echo "  \"${task_id}-unit-${i}\" [label=\"Unit ${i} (start)\"];"
        else
            echo "  \"${task_id}-unit-${i}\" [label=\"Unit ${i}\"];"
            echo "  \"${task_id}-unit-${prev}\" -> \"${task_id}-unit-${i}\" [label=\"handoff\"];"
        fi
    done
    echo "}"
}

# Generate parallel dependency graph
generate_parallel_graph() {
    local task_id="$1"
    local count="$2"

    echo "digraph ${task_id//-/_} {"
    echo "  rankdir=TB;"
    echo "  node [shape=box];"

    echo "  \"${task_id}-start\" [label=\"START\" shape=circle];"
    echo "  \"${task_id}-end\" [label=\"END\" shape=circle];"

    for ((i=1; i<=count; i++)); do
        echo "  \"${task_id}-unit-${i}\" [label=\"Unit ${i}\"];"
        echo "  \"${task_id}-start\" -> \"${task_id}-unit-${i}\";"
        echo "  \"${task_id}-unit-${i}\" -> \"${task_id}-end\";"
    done
    echo "}"
}

# Analyze intent from natural language
analyze_intent() {
    local input="$1"

    local intent_type="unknown"
    local confidence=0.5
    local scope=""
    local complexity=500

    # Classify intent type
    if echo "$input" | grep -qiE "add|create|implement|new feature|build"; then
        intent_type="feature"
        confidence=0.8
    elif echo "$input" | grep -qiE "fix|bug|patch|repair"; then
        intent_type="bugfix"
        confidence=0.85
    elif echo "$input" | grep -qiE "refactor|restructure|clean|simplify"; then
        intent_type="refactor"
        confidence=0.8
    elif echo "$input" | grep -qiE "test|coverage|verify"; then
        intent_type="testing"
        confidence=0.9
    elif echo "$input" | grep -qiE "docs?|document|readme|guide"; then
        intent_type="documentation"
        confidence=0.9
    elif echo "$input" | grep -qiE "security|audit|vulnerability|threat"; then
        intent_type="security"
        confidence=0.85
    elif echo "$input" | grep -qiE "performance|speed|optimize|fast"; then
        intent_type="optimization"
        confidence=0.8
    else
        intent_type="general"
        confidence=0.6
    fi

    # Estimate scope
    if echo "$input" | grep -qiE "single|one file|simple"; then
        scope="single"
        complexity=300
    elif echo "$input" | grep -qiE "multiple|several|across"; then
        scope="multi"
        complexity=2000
    elif echo "$input" | grep -qiE "entire|full|system|architecture"; then
        scope="system"
        complexity=8000
    else
        scope="medium"
        complexity=1000
    fi

    cat <<EOF
{
  "intent_type": "$intent_type",
  "confidence": $confidence,
  "scope": "$scope",
  "complexity_estimate": $complexity,
  "original_input": "$input",
  "analyzed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# Generate task spec from intent
generate_spec() {
    local intent_json="$1"
    local output_file="${2:-}"

    local intent_type
    intent_type=$(echo "$intent_json" | jq -r '.intent_type')
    local scope
    scope=$(echo "$intent_json" | jq -r '.scope')
    local complexity
    complexity=$(echo "$intent_json" | jq -r '.complexity_estimate')
    local original
    original=$(echo "$intent_json" | jq -r '.original_input')

    local task_id="task-$(date +%Y%m%d%H%M%S)"
    local priority="normal"
    local agent="copilot"
    local timeout=180

    # Adjust based on complexity
    if [[ "$complexity" -ge 8000 ]]; then
        priority="high"
        agent="gemini"
        timeout=600
    elif [[ "$complexity" -ge 3000 ]]; then
        priority="medium"
        timeout=300
    fi

    # Adjust based on intent type
    case "$intent_type" in
        security)
            agent="gemini"
            priority="high"
            timeout=600
            ;;
        testing)
            agent="copilot"
            priority="medium"
            ;;
    esac

    local spec="---
id: $task_id
agent: $agent
timeout: $timeout
priority: $priority
intent_type: $intent_type
scope: $scope
---

# Task: $intent_type

## Original Request
$original

## Scope
$scope

## Complexity
Estimated: $complexity tokens

## Agent
$agent (confidence: appropriate for $intent_type)
"

    if [[ -n "$output_file" ]]; then
        echo "$spec" > "$output_file"
        echo "$output_file"
    else
        echo "$spec"
    fi
}

# Main (only run if executed directly, not sourced)
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        decompose)    shift; decompose_task "$@" ;;
        complexity)   shift; estimate_complexity "$@" ;;
        intent)       shift; analyze_intent "$@" ;;
        spec)         shift; generate_spec "$@" ;;
        *)            echo "Usage: $0 decompose|complexity|intent|spec" >&2; exit 1 ;;
    esac
fi