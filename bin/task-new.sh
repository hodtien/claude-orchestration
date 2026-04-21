#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH_TASKS_DIR="${ORCH_TASKS_DIR:-$PROJECT_ROOT/.orchestration/tasks}"

usage(){ cat <<'EOF'
Usage:
  task-new.sh list-batches
  task-new.sh [--batch B] [--name N] [--agent copilot|gemini] [--type code|analysis|review|test|ci]
              [--priority high|normal|low] [--timeout SECONDS] [--depends-on "id1,id2"]
              [--prompt TEXT | --prompt-file PATH] [--prefer-cheap] [--dry-run] [--dispatch]
EOF
}

trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

prompt_with_default() {
  local label="$1" cur="$2" in=""
  if [ -n "$cur" ]; then read -r -p "$label ($cur): " in; printf '%s' "${in:-$cur}"
  else read -r -p "$label: " in; printf '%s' "$in"; fi
}

list_batches() {
  local dir name count file
  [ -d "$ORCH_TASKS_DIR" ] || exit 0
  shopt -s nullglob
  for dir in "$ORCH_TASKS_DIR"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"; count=0
    for file in "$dir"/task-*.md; do [ -f "$file" ] && count=$((count + 1)); done
    printf '%s   %s tasks\n' "$name" "$count"
  done | sort
  shopt -u nullglob
}

if [ "${1:-}" = "list-batches" ]; then [ "$#" -eq 1 ] || { usage >&2; exit 1; }; list_batches; exit 0; fi

batch=""; name=""; agent=""; task_type=""; priority=""; timeout=""
depends_on_raw=""; prompt_text=""; prompt_file=""
prefer_cheap=false; dry_run=false; dispatch=false; has_flags=false
interactive_mode=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --batch|--name|--agent|--type|--priority|--timeout|--depends-on|--prompt|--prompt-file)
      [ "$#" -ge 2 ] || { echo "Error: $1 requires a value." >&2; exit 1; }
      case "$1" in
        --batch) batch="$2" ;;
        --name) name="$2" ;;
        --agent) agent="$2" ;;
        --type) task_type="$2" ;;
        --priority) priority="$2" ;;
        --timeout) timeout="$2" ;;
        --depends-on) depends_on_raw="$2" ;;
        --prompt) prompt_text="$2" ;;
        --prompt-file) prompt_file="$2" ;;
      esac
      has_flags=true; shift 2 ;;
    --prefer-cheap) prefer_cheap=true; has_flags=true; shift ;;
    --dry-run) dry_run=true; has_flags=true; shift ;;
    --dispatch) dispatch=true; has_flags=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument $1" >&2; usage >&2; exit 1 ;;
  esac
done

[ -n "$prompt_text" ] && [ -n "$prompt_file" ] && { echo "Error: --prompt and --prompt-file are mutually exclusive." >&2; exit 1; }
if [ -n "$prompt_file" ]; then [ -f "$prompt_file" ] || { echo "Error: prompt file not found: $prompt_file" >&2; exit 1; }; prompt_text="$(cat "$prompt_file")"; fi
if [ ! -t 0 ] && [ "$has_flags" = false ]; then usage >&2; exit 1; fi

agent="${agent:-copilot}"; task_type="${task_type:-code}"; priority="${priority:-normal}"; timeout="${timeout:-300}"
if [ -t 0 ] && { [ -z "$batch" ] || [ -z "$name" ] || [ -z "$prompt_text" ]; }; then
  interactive_mode=true
  echo "Orchestration Task Wizard"
  echo "─────────────────────────"
  batch="$(prompt_with_default "Batch name (e.g. phase4)" "$batch")"
  name="$(prompt_with_default "Task name (e.g. add-login)" "$name")"
  read -r -p "Agent [copilot/gemini] ($agent): " in; agent="${in:-$agent}"
  read -r -p "Task type [code/analysis/review/test/ci] ($task_type): " in; task_type="${in:-$task_type}"
  read -r -p "Priority [high/normal/low] ($priority): " in; priority="${in:-$priority}"
  read -r -p "Timeout in seconds ($timeout): " in; timeout="${in:-$timeout}"
  read -r -p "Depends on (comma-separated task IDs, or blank): " in; [ -n "$in" ] && depends_on_raw="$in"
  read -r -p "Prefer cheap agent? [y/N] " in
  if [ -n "$in" ]; then case "$in" in [Yy]|[Yy][Ee][Ss]) prefer_cheap=true ;; *) prefer_cheap=false ;; esac; fi
  echo "Describe what this task should do:"; read -r -p "> " prompt_text
fi

[ -n "$batch" ] || { echo "Error: --batch is required." >&2; usage >&2; exit 1; }
[ -n "$name" ] || { echo "Error: --name is required." >&2; usage >&2; exit 1; }
[ -n "$prompt_text" ] || { echo "Error: prompt is required (--prompt or --prompt-file)." >&2; usage >&2; exit 1; }
[[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "Error: name must match ^[a-z0-9-]+\$." >&2; exit 1; }
[[ "$agent" =~ ^(copilot|gemini)$ ]] || { echo "Error: agent must be copilot|gemini." >&2; exit 1; }
[[ "$task_type" =~ ^(code|analysis|review|test|ci)$ ]] || { echo "Error: task_type must be code|analysis|review|test|ci." >&2; exit 1; }
[[ "$priority" =~ ^(high|normal|low)$ ]] || { echo "Error: priority must be high|normal|low." >&2; exit 1; }
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { echo "Error: timeout must be a positive integer." >&2; exit 1; }

depends_on=()
if [ -n "$depends_on_raw" ]; then
  IFS=',' read -r -a dep_items <<< "$depends_on_raw"
  for dep in "${dep_items[@]}"; do dep="$(trim "$dep")"; [ -n "$dep" ] && depends_on+=("$dep"); done
fi

batch_dir="$ORCH_TASKS_DIR/$batch"; max_num=0; warn_same_name=false; existing_ids=()
if [ -d "$batch_dir" ]; then
  shopt -s nullglob
  for file in "$batch_dir"/task-*.md; do
    [ -f "$file" ] || continue
    base="$(basename "$file")"; [[ "$base" == *-"$name".md ]] && warn_same_name=true
    if [[ "$base" =~ ^task-([0-9]+)-.+\.md$ ]]; then num=$((10#${BASH_REMATCH[1]})); [ "$num" -gt "$max_num" ] && max_num="$num"; fi
    existing_id="$(sed -n '/^---$/,/^---$/{s/^id:[[:space:]]*//p}' "$file" | head -1 | sed -e 's/[[:space:]]*$//' -e "s/^['\"]//" -e "s/['\"]$//")"
    if [ -n "$existing_id" ]; then existing_ids+=("$existing_id")
    else suffix="${base#task-}"; suffix="${suffix#[0-9][0-9]-}"; suffix="${suffix%.md}"; existing_ids+=("$batch-$suffix"); fi
  done
  shopt -u nullglob
fi
[ "$warn_same_name" = true ] && echo "WARN: existing task filename ends with -$name.md in batch $batch." >&2

for dep in "${depends_on[@]-}"; do
  [ -n "$dep" ] || continue
  found=false
  for existing in "${existing_ids[@]-}"; do [ "$dep" = "$existing" ] && found=true && break; done
  [ "$found" = false ] && echo "WARN: depends_on id not found in batch $batch: $dep" >&2
done

next_num=$((max_num + 1)); num_padded="$(printf '%02d' "$next_num")"; output_path="$batch_dir/task-$num_padded-$name.md"
depends_line="["; first=true
for dep in "${depends_on[@]-}"; do
  [ -n "$dep" ] || continue
  if [ "$first" = true ]; then depends_line="$depends_line$dep"; first=false
  else depends_line="$depends_line, $dep"; fi
done
depends_line="$depends_line]"

spec_content=$(cat <<EOF
---
id: $batch-$name
agent: $agent
task_type: $task_type
priority: $priority
timeout: $timeout
retries: 1
depends_on: $depends_line
context_from: []
prefer_cheap: $prefer_cheap
route: ""
agents: []
slo_duration_s: $timeout
---

$prompt_text
EOF
)

if [ "$dry_run" = true ]; then printf '%s\n' "$spec_content"; exit 0; fi
mkdir -p "$batch_dir"; printf '%s\n' "$spec_content" > "$output_path"
created_path="$output_path"; [[ "$output_path" == "$PROJECT_ROOT/"* ]] && created_path="${output_path#$PROJECT_ROOT/}"
echo "✔ Created: $created_path"
if [ "$interactive_mode" = true ] && [ "$dispatch" = false ]; then
  read -r -p "Dispatch now? [y/N]: " in
  case "$in" in [Yy]|[Yy][Ee][Ss]) dispatch=true ;; *) dispatch=false ;; esac
fi
if [ "$dispatch" = true ]; then "$PROJECT_ROOT/bin/task-dispatch.sh" ".orchestration/tasks/$batch/"; fi
