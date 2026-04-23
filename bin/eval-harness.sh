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

SCRIPT_DIR="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_DIR")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH_DIR="$PROJECT_ROOT/.orchestration"
EVALS_DIR="$ORCH_DIR/evals"
# RESULTS_DIR must match where task-dispatch.sh writes ($ORCH_DIR/results)
RESULTS_DIR="$ORCH_DIR/results"
RESULTS_FILE="$RESULTS_DIR/$(date +%Y-%m-%d).json"
MODELS_YAML="$PROJECT_ROOT/config/models.yaml"

mkdir -p "$RESULTS_DIR"

# ── helpers ────────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: eval-harness.sh <task_type> [--model <model>] [--verbose]"
  echo "       eval-harness.sh list"
  echo "       eval-harness.sh results [--since <date>]"
  echo ""
  echo "task_type: folder name under $EVALS_DIR/"
  echo "model:     run only this model (default: all configured models for task_type)"
  echo "verbose:   print each case output"
  exit 1
}

parse_case() {
  # Parse a YAML eval case file, output JSON
  local file="$1"
  python3 - "$file" <<'PYEOF'
import json, sys, yaml

path = sys.argv[1]
with open(path) as f:
    raw = f.read()

# Strip frontmatter if present
if raw.startswith('---'):
    parts = raw.split('---', 2)
    raw = parts[2] if len(parts) >= 3 else parts[1]

data = yaml.safe_load(raw)
task_type = data.get('task_type', '')
description = data.get('description', '')
input_prompt = data.get('input', '')
expected = data.get('expected_properties', {})
timeout = data.get('timeout', 60)
model_override = data.get('model', '')

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

  for needle in $must_contain; do
    if ! echo "$output" | grep -qi "$needle"; then
      failed+=("must_contain:'$needle'")
    fi
  done

  for bad in $must_not_contain; do
    if echo "$output" | grep -qi "$bad"; then
      failed+=("must_not_contain:'$bad'")
    fi
  done

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
  # Note: YAML key is task_mapping (not task_types)
  local task_type="$1"
  python3 - "$task_type" "$MODELS_YAML" <<'PYEOF'
import json, sys, yaml

task_type = sys.argv[1]
yaml_path = sys.argv[2]
with open(yaml_path) as f:
    data = yaml.safe_load(f)

mapping = data.get('task_mapping', {})
if task_type in mapping:
    entry = mapping[task_type]
    parallel = entry.get('parallel', [])
    fallback = entry.get('fallback', [])
    models = parallel + fallback
    print(json.dumps(models))
else:
    print(json.dumps([]))
PYEOF
}

run_single_case() {
  # Run one eval case with one model, return JSON result on stdout
  local case_json="$1"
  local model="$2"
  local verbose="$3"

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
  local spec_file="$batch_dir/task-${tid}.md"  # task-dispatch requires task-*.md naming
  # Write spec in YAML frontmatter + markdown body format (task-dispatch reads task-*.md)
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
  local start_ts end_ts duration output dispatch_status
  start_ts=$(date +%s)

  # Capture dispatch exit status; task-dispatch exits 0 on success even if agent fails internally
  "$SCRIPT_DIR/task-dispatch.sh" "$batch_dir" >/dev/null 2>&1
  dispatch_status=$?

  end_ts=$(date +%s)
  duration=$(( end_ts - start_ts ))

  # Read output
  output=$(cat "$ORCH_DIR/results/$tid.out" 2>/dev/null || echo "")

  # Detect agent/dispatch failure: if output is empty or dispatch failed, treat as fail
  if [[ $dispatch_status -ne 0 ]] || [[ -z "$output" ]]; then
    output="[AGENT_DISPATCH_FAILED] dispatch_status=$dispatch_status output_empty=$([ -z "$output" ] && echo true || echo false)"
    check_result="fail:dispatch_error"
    pass_fail="fail"
    failed_checks="dispatch_error"
    cost_chars=$(wc -c <<< "$output" | tr -d ' ')
    [[ "$verbose" == "true" ]] && echo "    [$model] $tid → FAIL ($duration s, dispatch_status=$dispatch_status)"

    # Clean up batch dir
    rm -rf "$batch_dir" 2>/dev/null || true

    # Output JSON result to stdout
    python3 - "$task_type" "$model" "$tid" "$description" "$pass_fail" "$duration" "$cost_chars" "$failed_checks" <<'PYEOF'
import json, sys, datetime

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
    "timestamp": datetime.datetime.now(datetime.UTC).isoformat() + 'Z'
}
print(json.dumps(result))
PYEOF
    return 0
  fi

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

  # Output JSON result to stdout
  python3 - "$task_type" "$model" "$tid" "$description" "$pass_fail" "$duration" "$cost_chars" "$failed_checks" <<'PYEOF'
import json, sys, datetime

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
    "timestamp": datetime.datetime.now(datetime.UTC).isoformat() + 'Z'
}
print(json.dumps(result))
PYEOF
}

list_task_types() {
  echo "Available task types in $EVALS_DIR/:"
  for dir in "$EVALS_DIR"/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
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

case "${1:-}" in
  list)
    list_task_types
    exit 0
    ;;
  results)
    since="${2:-}"
    show_results "$since"
    exit 0
    ;;
  --help|-h|help)
    usage
    ;;
esac

# Collect positional args
TASK_TYPE="${1:-}"
MODEL_FILTER=""
VERBOSE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_FILTER="$2"; shift 2 ;;
    --verbose) VERBOSE="true"; shift ;;
    -*) echo "Unknown flag: $1" >&2; shift ;;
    *) break ;;
  esac
done

if [[ -z "$TASK_TYPE" ]]; then
  usage
fi

CASE_DIR="$EVALS_DIR/$TASK_TYPE"
if [[ ! -d "$CASE_DIR" ]]; then
  echo "❌ No eval cases found for task_type: $TASK_TYPE" >&2
  echo "   Try: eval-harness.sh list" >&2
  exit 1
fi

# Collect models to test
if [[ -n "$MODEL_FILTER" ]]; then
  read -ra MODELS <<< "$MODEL_FILTER"
else
  models_json=$(get_models_for_task_type "$TASK_TYPE")
  if [[ -z "$models_json" ]] || [[ "$models_json" == "[]" ]]; then
    echo "⚠️  No models configured for task_type: $TASK_TYPE — using gemini-fast as fallback"
    MODELS=("gemini-fast")
  else
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

ALL_RESULTS_JSON=""
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
    ALL_RESULTS_JSON="${ALL_RESULTS_JSON}${result_json}"$'\n'
  done
done

# Aggregate results
echo ""
echo "=========================================="
echo "RESULTS SUMMARY"
echo "=========================================="

tmp_results=$(mktemp "/tmp/eval-results-XXXXXX.json" 2>/dev/null || echo "/tmp/eval-results-$$.json")
echo "$ALL_RESULTS_JSON" > "$tmp_results"

python3 - "$tmp_results" <<'PYEOF'
import json, sys, os, datetime, pathlib
from collections import defaultdict

results_path = sys.argv[1]
with open(results_path) as f:
    content = f.read()
os.unlink(results_path)


results = []
for line in content.split('\n'):
    line = line.strip()
    if not line:
        continue
    try:
        results.append(json.loads(line))
    except Exception as e:
        print(f"ERROR: {e}: {line[:80]}", file=sys.stderr)
        pass

if not results:
    print("No results recorded.")
    sys.exit(0)

by_model = defaultdict(list)
for r in results:
    by_model[r['model']].append(r)

print(f"{'Model':<25} {'Result':<10} {'Duration':<10} {'Chars':<8}")
print("-" * 60)

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
results_dir = pathlib.Path(os.path.expanduser("~/.claude/orchestration/evals/results/"))
results_dir.mkdir(parents=True, exist_ok=True)
results_file = results_dir / f"{datetime.date.today().isoformat()}.json"

existing = []
if results_file.exists():
    try:
        with open(results_file) as f:
            existing = json.load(f)
    except:
        pass

all_results = existing + results
with open(results_file, 'w') as f:
    json.dump(all_results, f, indent=2)

print(f"\n📄 Results written to: evals/results/{datetime.date.today().isoformat()}.json")
PYEOF
