#!/usr/bin/env bash
# eval-harness.sh — Golden-set evaluation CLI
# Runs tasks from .orchestration/evals/<task_type>/ against configured models,
# checks output against expected_properties, records pass/fail + cost + latency.
#
# Usage:
#   eval-harness.sh <task_type> [--model <model>] [--verbose]
#   eval-harness.sh list              # show available task_types and case counts
#   eval-harness.sh results [--since <date>]  # show past results
#
# Input format (.orchestration/evals/<task_type>/*.yaml):
#   task_type: code_review
#   description: "Should catch unused variable"
#   input: |
#     Review this code:
#     ```python
#     x = 1
#     print(x)
#     ```
#   expected_properties:
#     must_contain: ["unused", "x", "warning"]
#     must_not_contain: ["TODO", "FIXME"]
#     regex_match: "warning.*unused"
#   timeout: 60
#   model: gemini-fast  # optional override

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH_DIR="$PROJECT_ROOT/.orchestration"
EVALS_DIR="$ORCH_DIR/evals"
RESULTS_DIR="$EVALS_DIR/results"
RESULTS_FILE="$RESULTS_DIR/$(date +%Y-%m-%d).json"
MODELS_YAML="$PROJECT_ROOT/config/models.yaml"

mkdir -p "$RESULTS_DIR"

# ── helpers ────────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 <task_type> [--model <model>] [--verbose]"
  echo "       $0 list"
  echo "       $0 results [--since <date>]"
  echo ""
  echo "task_type: folder name under $EVALS_DIR/"
  echo "model:     run only this model (default: all configured models for task_type)"
  echo "verbose:   print each case output"
  exit 1
}

parse_case() {
  # Parse a YAML eval case file, output JSON-like key-value pairs
  local file="$1"
  python3 - "$file" <<'PYEOF'
import json, sys, yaml

path = sys.argv[1]
with open(path) as f:
    raw = f.read()

# Strip frontmatter if present
if raw.startswith('---'):
    parts = raw.split('---', 2)
    if len(parts) >= 3:
        raw = parts[2]
    else:
        raw = parts[1]

data = yaml.safe_load(raw)
task_type = data.get('task_type', '')
description = data.get('description', '')
input_prompt = data.get('input', '')
expected = data.get('expected_properties', {})
timeout = data.get('timeout', 60)
model_override = data.get('model', '')

# Output as JSON
result = {
    'task_type': task_type,
    'description': description,
    'input': input_prompt,
    'expected': expected,
    'timeout': timeout,
    'model_override': model_override,
}
print(json.dumps(result))
PYEOF
}

check_case() {
  # Run output through expected_property checks
  # Returns: pass|fail + list of failed checks
  local output="$1"
  local must_contain="$2"
  local must_not_contain="$3"
  local regex_match="$4"

  local failed=()

  # must_contain: ALL must appear in output
  for needle in $must_contain; do
    if ! echo "$output" | grep -qi "$needle"; then
      failed+=("must_contain:'$needle'")
    fi
  done

  # must_not_contain: NONE should appear
  for bad in $must_not_contain; do
    if echo "$output" | grep -qi "$bad"; then
      failed+=("must_not_contain:'$bad'")
    fi
  done

  # regex_match: at least one pattern must match
  if [[ -n "$regex_match" ]]; then
    if ! echo "$output" | grep -qiE "$regex_match"; then
      failed+=("regex_match:'$regex_match'")
    fi
  fi

  if [[ ${#failed[@]} -eq 0 ]]; then
    echo "pass"
  else
    echo "fail:${failed[*]}"
  fi
}

get_models_for_task_type() {
  # Parse models.yaml, return list of models for given task_type
  local task_type="$1"
  python3 - "$task_type" "$MODELS_YAML" <<'PYEOF'
import json, sys, yaml

task_type = sys.argv[1]
yaml_path = sys.argv[2]

with open(yaml_path) as f:
    data = yaml.safe_load(f)

# Find task_type entry
models = []
task_types = data.get('task_types', {})
if task_type in task_types:
    entry = task_types[task_type]
    parallel = entry.get('parallel', [])
    fallback = entry.get('fallback', [])
    models = parallel + fallback

print(json.dumps(models))
PYEOF
}

run_single_case() {
  # Run one eval case with one model, return JSON result
  local case_json="$1"
  local model="$2"
  local verbose="${3:-false}"

  local task_type description input_prompt timeout
  task_type=$(echo "$case_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_type',''))" 2>/dev/null || echo "")
  description=$(echo "$case_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('description',''))" 2>/dev/null || echo "")
  input_prompt=$(echo "$case_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('input',''))" 2>/dev/null || echo "")
  timeout=$(echo "$case_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('timeout',60))" 2>/dev/null || echo "60")

  # Create temporary batch dir for dispatch
  local batch_id="eval-$(date +%Y%m%d-%H%M%S)-$$"
  local batch_dir="$ORCH_DIR/tasks/$batch_id"
  mkdir -p "$batch_dir"

  local tid="eval-$(echo "$model" | tr '/-' '_')-$(date +%Y%m%d%H%M%S)"
  local spec_file="$batch_dir/$tid.yaml"
  cat > "$spec_file" <<SPECEOF
---
id: $tid
task_type: $task_type
agent: $model
timeout: $timeout
priority: high
---
$input_prompt
SPECEOF

  # Run dispatch (sequential, single task)
  local start_ts end_ts duration cost_chars output exit_code
  start_ts=$(date +%s)

  "$SCRIPT_DIR/task-dispatch.sh" "$batch_dir" 2>/dev/null || true

  end_ts=$(date +%s)
  duration=$(( end_ts - start_ts ))

  # Read output
  output=$(cat "$ORCH_DIR/results/$tid.out" 2>/dev/null || echo "")
  cost_chars=$(wc -c <<< "$output" | tr -d ' ')

  # Check against expectations
  local expected_json
  expected_json=$(echo "$case_json" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('expected',{})))" 2>/dev/null || echo '{}')
  local must_contain must_not_contain regex_match
  must_contain=$(echo "$expected_json" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin).get('must_contain',[])))" 2>/dev/null || echo "")
  must_not_contain=$(echo "$expected_json" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin).get('must_not_contain',[])))" 2>/dev/null || echo "")
  regex_match=$(echo "$expected_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('regex_match',''))" 2>/dev/null || echo "")

  local check_result
  check_result=$(check_case "$output" "$must_contain" "$must_not_contain" "$regex_match")
  local pass_fail="${check_result%%:*}"
  local failed_checks="${check_result#*:}"

  [[ "$verbose" == "true" ]] && echo "    [$model] $tid → $pass_fail ($duration s, ${cost_chars}b)"

  # Clean up batch dir
  rm -rf "$batch_dir" 2>/dev/null || true

  # Return JSON result
  python3 - "$task_type" "$model" "$tid" "$description" "$pass_fail" "$duration" "$cost_chars" "$failed_checks" <<'PYEOF'
import json, sys

task_type = sys.argv[1]
model = sys.argv[2]
tid = sys.argv[3]
description = sys.argv[4]
pass_fail = sys.argv[5]
duration = int(sys.argv[6])
cost_chars = int(sys.argv[7])
failed_checks = sys.argv[8] if len(sys.argv) > 8 else ""

result = {
    "task_type": task_type,
    "model": model,
    "tid": tid,
    "description": description,
    "status": pass_fail,
    "duration_s": duration,
    "output_chars": cost_chars,
    "failed_checks": failed_checks,
    "timestamp": __import__('datetime').datetime.utcnow().isoformat() + 'Z'
}
print(json.dumps(result))
PYEOF
}

list_task_types() {
  echo "Available task types in $EVALS_DIR/:"
  for dir in "$EVALS_DIR"/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    # Skip results/ directory
    [ "$name" = "results" ] && continue
    count=$(find "$dir" -maxdepth 1 -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
    echo "  $name — $count case(s)"
  done
}

show_results() {
  local since="${1:-}"
  echo "Eval results from $RESULTS_DIR/:"
  for f in "$RESULTS_DIR"/*.json; do
    [ -f "$f" ] || continue
    date=$(basename "$f" .json)
    [[ -n "$since" && "$date" < "$since" ]] && continue
    echo ""
    echo "=== $date ==="
    python3 - "$f" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    results = json.load(f)

if not isinstance(results, list):
    results = [results]

by_model = {}
for r in results:
    m = r.get('model','?')
    by_model.setdefault(m, []).append(r)

for model, records in by_model.items():
    passed = sum(1 for r in records if r.get('status') == 'pass')
    total = len(records)
    avg_dur = sum(r.get('duration_s',0) for r in records) / total if total else 0
    avg_chars = sum(r.get('output_chars',0) for r in records) / total if total else 0
    rate = f"{passed}/{total}"
    print(f"  {model}: {rate} pass ({avg_dur:.0f}s avg, ~{avg_chars:.0f} chars avg)")
PYEOF
  done
}

# ── main ──────────────────────────────────────────────────────────────────────

MODE="${1:-}"
shift || true

# Handle non-task_type positional args
case "$MODE" in
  list)
    list_task_types
    exit 0
    ;;
  results)
    since="${1:-}"
    show_results "$since"
    exit 0
    ;;
  --help|-h|help)
    usage
    ;;
esac

TASK_TYPE="${1:-}"
MODEL_FILTER="${2:-}"
VERBOSE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_FILTER="$2"; shift 2 ;;
    --verbose) VERBOSE="true"; shift ;;
    *) shift ;;
  esac
done

if [[ -z "$TASK_TYPE" ]]; then
  usage
fi

CASE_DIR="$EVALS_DIR/$TASK_TYPE"
if [[ ! -d "$CASE_DIR" ]]; then
  echo "❌ No eval cases found for task_type: $TASK_TYPE" >&2
  echo "   Try: $0 list" >&2
  exit 1
fi

# Collect models to test
if [[ -n "$MODEL_FILTER" ]]; then
  MODELS=("$MODEL_FILTER")
else
  models_json=$(get_models_for_task_type "$TASK_TYPE")
  if [[ -z "$models_json" ]]; then
    echo "⚠️  No models configured for task_type: $TASK_TYPE — using gemini-fast as fallback"
    MODELS=("gemini-fast")
  else
    # Parse JSON array into bash array
    MODELS=($(echo "$models_json" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin)))" 2>/dev/null || echo "gemini-fast"))
  fi
fi

CASES=("$CASE_DIR"/*.yaml)
if [[ ${#CASES[@]} -eq 0 ]] || [[ ! -f "${CASES[0]}" ]]; then
  echo "❌ No .yaml eval cases found in $CASE_DIR/" >&2
  exit 1
fi

echo "=========================================="
echo "eval-harness.sh — $TASK_TYPE"
echo "Models: ${MODELS[*]}"
echo "Cases: ${#CASES[@]}"
echo "=========================================="

ALL_RESULTS=()
TOTAL_CASES=$(( ${#CASES[@]} * ${#MODELS[@]} ))
CURRENT=0

for case_file in "${CASES[@]}"; do
  case_json=$(parse_case "$case_file")
  echo ""
  echo "[$(basename "$case_file")] $(echo "$case_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('description','')[:60])" 2>/dev/null || echo "")"

  for model in "${MODELS[@]}"; do
    CURRENT=$((CURRENT + 1))
    echo "  [$CURRENT/$TOTAL_CASES] Testing with $model..."
    result_json=$(run_single_case "$case_json" "$model" "$VERBOSE")
    ALL_RESULTS+=("$result_json")
  done
done

# Aggregate results
echo ""
echo "=========================================="
echo "RESULTS SUMMARY"
echo "=========================================="

python3 - <<'PYEOF'
import json, sys, os
from collections import defaultdict

results = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        results.append(json.loads(line))
    except:
        pass

if not results:
    print("No results recorded.")
    sys.exit(0)

by_model = defaultdict(list)
for r in results:
    by_model[r['model']].append(r)

print(f"{'Model':<25} {'Result':<10} {'Duration':<10} {'Chars':<8}")
print("-" * 60)

# Per-model summary
for model, records in sorted(by_model.items()):
    passed = sum(1 for r in records if r.get('status') == 'pass')
    total = len(records)
    avg_dur = sum(r.get('duration_s',0) for r in records) / total if total else 0
    avg_chars = sum(r.get('output_chars',0) for r in records) / total if total else 0
    rate = passed / total * 100 if total else 0
    print(f"{model:<25} {passed}/{total} ({rate:.0f}%)  {avg_dur:>6.0f}s avg  ~{avg_chars:>6.0f} chars")

print("-" * 60)
overall_pass = sum(1 for r in results if r.get('status') == 'pass')
overall_total = len(results)
print(f"{'TOTAL':<25} {overall_pass}/{overall_total} ({overall_pass/overall_total*100:.0f}%)")

# Write results file
results_file = os.path.expanduser("~/.claude/orchestration/evals/results/") + __import__('datetime').date.today().isoformat() + ".json"
os.makedirs(os.path.dirname(results_file), exist_ok=True)

# Append to existing or create new
existing = []
if os.path.exists(results_file):
    try:
        with open(results_file) as f:
            existing = json.load(f)
    except:
        pass

all_results = existing + results
with open(results_file, 'w') as f:
    json.dump(all_results, f, indent=2)

print(f"\n📄 Results written to: evals/results/{__import__('datetime').date.today().isoformat()}.json")
PYEOF
