#!/usr/bin/env bash
# task-fork.sh — Intent Fork detection and execution
# Detects ambiguity in task prompts, creates N branches, probes in parallel,
# scores each fork, and collapses to the best path.
#
# Usage:
#   task-fork.sh <spec-file> [num_forks=2]
#
# Creates fork specs in: .orchestration/forks/<task-id>-fork-*.md
# Outputs collapsed result to: .orchestration/results/<task-id>.out
# Stores discarded forks with reasoning in: .orchestration/forks/<task-id>-fork-*.discarded.md

set -euo pipefail

SPEC_FILE="${1:?spec-file required}"
NUM_FORKS="${2:-2}"
FORKS_DIR="${FORKS_DIR:-$HOME/.claude-orchestration/.orchestration/forks}"
RESULTS_DIR="$HOME/.claude-orchestration/.orchestration/results"

mkdir -p "$FORKS_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── parse spec ────────────────────────────────────────────────────────────────
get_front() {
  local key="$1" default="${2:-}"
  python3 - "$SPEC_FILE" "$key" "$default" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
m = re.match(r'^---\s*\n(.*?)\n---', text, re.DOTALL)
if not m:
    print(sys.argv[3], end='')
    sys.exit(0)
key = sys.argv[2]
for line in m.group(1).splitlines():
    line = line.strip()
    if line.startswith(key + ':'):
        val = line[len(key)+1:].strip()
        if val and val[0] not in ('"', "'", '['):
            val = re.sub(r'\s+#.*$', '', val)
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
            val = val[1:-1]
        print(val, end='')
        sys.exit(0)
print(sys.argv[3], end='')
PYEOF
}

get_body() {
  python3 - "$SPEC_FILE" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
m = re.match(r'^---\s*\n.*?\n---\s*\n?(.*)\Z', text, re.DOTALL)
if m:
    print(m.group(1).rstrip())
PYEOF
}

TASK_ID=$(get_front "id" "$(basename "$SPEC_FILE" .md)")
AGENT=$(get_front "agent" "gemini-fast")
TIMEOUT=$(get_front "fork_timeout" "60")
FORK_MODE=$(get_front "fork_mode" "auto")

# ── detect ambiguity ───────────────────────────────────────────────────────────
detect_ambiguity() {
  local prompt="$1"
  local score=0
  local reasons=()

  # Explicit AMBIGUOUS marker
  if echo "$prompt" | grep -qE '\{\{AMBIGUOUS:'; then
    echo "explicit"
    return
  fi

  # Question marks with could/should/might
  q_count=$(echo "$prompt" | grep -cE '\?' 2>/dev/null || echo 0)
  if [ "$q_count" -ge 2 ]; then
    score=$((score + 1))
    reasons+=("multiple_questions")
  fi

  # Vague scope words
  vague_count=$(echo "$prompt" | grep -cE '(improve|enhance|fix|stuff|something|things?|update|change|modify)' 2>/dev/null || echo 0)
  if [ "$vague_count" -ge 2 ]; then
    score=$((score + 1))
    reasons+=("vague_scope")
  fi

  # OR patterns suggesting choice
  or_count=$(echo "$prompt" | grep -cE '\b(or|either)\b' 2>/dev/null || echo 0)
  if [ "$or_count" -ge 2 ]; then
    score=$((score + 2))
    reasons+=("explicit_choice")
  fi

  if [ "$score" -ge 2 ]; then
    echo "detected:$score"
  else
    echo "none"
  fi
}

# ── extract explicit forks from {{AMBIGUOUS:...}} ────────────────────────────
extract_explicit_forks() {
  local prompt="$1"
  echo "$prompt" | grep -oP '\{\{AMBIGUOUS:([^}]+)\}\}' | while read -r marker; do
    local options="${marker#{{AMBIGUOUS:}"
    options="${options%}}"
    echo "$options" | tr '|' '\n'
  done
}

# ── generate implicit forks (for vague prompts) ─────────────────────────────
generate_implicit_forks() {
  local prompt="$1" num="$2"
  local interpretations=()

  # Detect focus areas from vague words
  if echo "$prompt" | grep -qi 'improve\|enhance'; then
    interpretations+=("Performance: focus on speed, efficiency, throughput")
  fi
  if echo "$prompt" | grep -qi 'fix\|bug\|error'; then
    interpretations+=("Reliability: focus on error handling, edge cases")
  fi
  if echo "$prompt" | grep -qi 'security\|safe'; then
    interpretations+=("Security: focus on vulnerability prevention")
  fi
  if echo "$prompt" | grep -qi 'clean\|refactor'; then
    interpretations+=("Maintainability: focus on code structure, readability")
  fi

  # Default interpretations if none detected
  if [ ${#interpretations[@]} -eq 0 ]; then
    interpretations+=("Option A: implement the most straightforward interpretation")
    interpretations+=("Option B: implement with best practices emphasized")
  fi

  printf '%s\n' "${interpretations[@]}" | head -n "$num"
}

# ── create fork spec ─────────────────────────────────────────────────────────
create_fork_spec() {
  local fork_num="$1" interpretation="$2"
  local fork_id="${TASK_ID}-fork-${fork_num}"
  local fork_file="$FORKS_DIR/${fork_id}.md"
  local original_body
  original_body=$(get_body)

  # Replace AMBIGUOUS markers with specific interpretation
  local fork_body
  fork_body=$(echo "$original_body" | sed "s/{{AMBIGUOUS:[^}]*}}/$interpretation/g")

  cat > "$fork_file" <<EOF
---
id: $fork_id
agent: $AGENT
timeout: $TIMEOUT
retries: 1
priority: normal
context_from: []
depends_on: []
fork_of: $TASK_ID
fork_interpretation: $interpretation
output_format: markdown
---

# Fork $fork_num: $interpretation

**Original Task:** $TASK_ID
**Interpretation:** $interpretation

$fork_body

---
*Auto-generated by task-fork.sh — intent fork analysis*
EOF

  echo "$fork_file"
}

# ── score and rank forks ──────────────────────────────────────────────────────
score_forks() {
  local results_dir="$1"  # where fork result files live

  python3 - "$FORKS_DIR" "$TASK_ID" <<'PYEOF'
import json, os, glob, re
from pathlib import Path

forks_dir, task_id = Path(sys.argv[1]), sys.argv[2]

# Score each fork: size + keyword completeness
fork_scores = []

for fp in sorted(forks_dir.glob(f"{task_id}-fork-*.md")):
    fid = fp.stem
    if fid == task_id:
        continue

    # Parse interpretation from frontmatter
    interp = "unknown"
    try:
        text = fp.read_text()
        m = re.match(r'^---\s*\n(.*?)\n---', text, re.DOTALL)
        if m:
            for line in m.group(1).splitlines():
                if line.strip().startswith('fork_interpretation:'):
                    interp = line.split(':', 1)[1].strip()
                    break
    except:
        pass

    # Check result file
    result_file = Path(f"~/.claude-orchestration/.orchestration/results/{fid}.out").expanduser()
    size = 0
    if result_file.exists():
        size = result_file.stat().st_size

    # Simple scoring: larger output = more substance
    # In production, would analyze for completeness, specificity, etc.
    score = min(size / 500.0, 10.0)  # cap at 10

    fork_scores.append({
        "fork_id": fid,
        "interpretation": interp,
        "size": size,
        "score": round(score, 2),
    })

# Sort by score descending
fork_scores.sort(key=lambda x: -x["score"])

# Output ranked list
for fs in fork_scores:
    print(f"{fs['fork_id']}|{fs['interpretation']}|{fs['score']}|{fs['size']}")
PYEOF
}

# ── collapse best fork ────────────────────────────────────────────────────────
collapse_best_fork() {
  local scores="$1"  # newline-separated: fork_id|interpretation|score|size

  local best_line
  best_line=$(echo "$scores" | head -1)
  local best_id="${best_line%%|*}"
  local best_interp="${best_line#*|}"
  best_interp="${best_interp%%|*}"

  echo "[fork] Best fork: $best_id ($best_interp)" >&2

  # Copy best result to main output
  local best_result="$RESULTS_DIR/${best_id}.out"
  local main_result="$RESULTS_DIR/${TASK_ID}.out"
  if [ -f "$best_result" ] && [ -s "$best_result" ]; then
    cp "$best_result" "$main_result"
    echo "[fork] Collapsed best fork to $main_result" >&2
  fi

  # Mark discarded forks
  echo "$scores" | tail -n +2 | while IFS='|' read -r fid interp score size; do
    [ -z "$fid" ] && continue
    local discarded="$FORKS_DIR/${fid}.discarded.md"
    cat > "$discarded" <<EOF
# Discarded Fork: $fid

**Interpretation:** $interp
**Score:** $score
**Size:** $size bytes

*Discarded because another fork scored higher.*
*Best fork was: $best_id*

---Original output---
$(cat "$RESULTS_DIR/${fid}.out" 2>/dev/null || echo "(no output)")
EOF
  done

  echo "$best_id"
}

# ── main ─────────────────────────────────────────────────────────────────────────
prompt_body=$(get_body)
echo "[fork] Analyzing $TASK_ID for ambiguity..." >&2
echo "[fork] Fork mode: $FORK_MODE" >&2

ambiguity=$(detect_ambiguity "$prompt_body")
echo "[fork] Ambiguity: $ambiguity" >&2

# Only process if ambiguity detected and fork_mode is auto
if [ "$FORK_MODE" = "disabled" ]; then
  echo "[fork] Fork mode disabled — passing through" >&2
  exit 0
fi

if [ "$ambiguity" = "none" ]; then
  echo "[fork] No ambiguity detected — passing through" >&2
  exit 0
fi

# Extract or generate interpretations
declare -a FORK_INTERPRETATIONS=()
fork_num=0

if [ "$ambiguity" = "explicit" ]; then
  echo "[fork] Found explicit AMBIGUOUS markers" >&2
  while IFS= read -r opt; do
    [ -z "$opt" ] && continue
    fork_num=$((fork_num + 1))
    FORK_INTERPRETATIONS+=("$opt")
  done < <(extract_explicit_forks "$prompt_body")
else
  echo "[fork] Detected implicit ambiguity (score=$ambiguity)" >&2
  while IFS= read -r interp; do
    [ -z "$interp" ] && continue
    fork_num=$((fork_num + 1))
    FORK_INTERPRETATIONS+=("$interp")
  done < <(generate_implicit_forks "$prompt_body" "$NUM_FORKS")
fi

if [ $fork_num -eq 0 ]; then
  echo "[fork] No forks generated — passing through" >&2
  exit 0
fi

echo "[fork] Creating $fork_num fork(s)..." >&2

# Create fork specs and dispatch in parallel
declare -a fork_pids=()
for i in "${!FORK_INTERPRETATIONS[@]}"; do
  fork_num=$((i + 1))
  interp="${FORK_INTERPRETATIONS[$i]}"

  fork_file=$(create_fork_spec "$fork_num" "$interp")
  echo "[fork] Created fork $fork_num: $fork_file" >&2

  # Dispatch fork asynchronously
  (
    fork_id="${TASK_ID}-fork-${fork_num}"
    "$SCRIPT_DIR/agent.sh" "$AGENT" "$fork_id" "$(cat "$fork_file" | sed '1,/^---$/d')" "$TIMEOUT" "1" \
      > "$RESULTS_DIR/${fork_id}.out" 2>&1
  ) &
  fork_pids+=($!)
done

# Wait for all forks
for pid in "${fork_pids[@]}"; do
  wait "$pid" || true
done

echo "[fork] All forks complete — scoring..." >&2

# Score and collapse
scores=$(score_forks "$FORKS_DIR")
best_fork=$(collapse_best_fork "$scores")

echo "[fork] Done. Best fork: $best_fork" >&2
echo "Collapsed to: $best_fork"
