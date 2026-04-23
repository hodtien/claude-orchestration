#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$PROJECT_ROOT/.orchestration/templates/batches"
TASKS_ROOT="$PROJECT_ROOT/.orchestration/tasks"

usage(){ cat <<'EOF'
Usage:
  task-init.sh list
  task-init.sh <template> <batch-id> [VAR=value ...]
  task-init.sh <template> <batch-id> --dry-run
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 1; }
if [[ "$1" == "list" ]]; then
  cat <<'EOF'
Available batch templates:
  code-review    — Gemini architecture + Copilot quality review (parallel)
  feature-dev    — Design → Implement → Review pipeline
  security-audit — Threat model + dependency audit
  perf-analysis  — Bottleneck analysis → fix implementation
  doc-update     — Documentation generation + README update
EOF
  exit 0
fi
[[ $# -ge 2 ]] || { usage >&2; exit 1; }

TEMPLATE_FILE="$TEMPLATE_DIR/$1.yml"; BATCH_ID="$2"; shift 2
[[ -f "$TEMPLATE_FILE" ]] || { echo "[task-init] template not found: ${TEMPLATE_FILE##*/}" >&2; exit 1; }
DRY_RUN=false; KV_ARGS=()
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true && continue
  [[ "$arg" == *=* ]] && KV_ARGS+=("$arg") && continue
  echo "[task-init] invalid argument: $arg" >&2; usage >&2; exit 1
done

set +u
python3 - "$TEMPLATE_FILE" "$BATCH_ID" "$TASKS_ROOT" "$DRY_RUN" "${KV_ARGS[@]}" <<'PY'
import re, sys
from pathlib import Path
tpl, batch_id, tasks_root, dry_run = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), sys.argv[4] == "true"
vars_in = {k: v for k, v in (a.split("=", 1) for a in sys.argv[5:])}
lines = tpl.read_text(encoding="utf-8").splitlines()
tasks, task, section = [], None, ""
for raw in lines:
    line = raw.rstrip()
    if not line.strip() or line.lstrip().startswith("#"): continue
    if not line.startswith(" "):
        section = line.split(":", 1)[0].strip()
        continue
    if section == "tasks":
        m = re.match(r"^\s*-\s*id:\s*(.+?)\s*$", line)
        if m:
            if task: tasks.append(task)
            v = m.group(1).strip(); task = {"id": v[1:-1] if len(v) > 1 and v[0] == v[-1] and v[0] in "'\"" else v}
            continue
        m = re.match(r"^\s+([a-zA-Z_][\w-]*):\s*(.*)$", line)
        if not (m and task): continue
        k, v = m.group(1), m.group(2).strip()
        if len(v) > 1 and v[0] == v[-1] and v[0] in "'\"": v = v[1:-1]
        task[k] = [x.strip().strip("'\"") for x in v[1:-1].split(",") if x.strip()] if k == "depends_on" and v.startswith("[") and v.endswith("]") else ([] if k == "depends_on" and not v else ([v] if k == "depends_on" else v))
if task: tasks.append(task)
if not tasks: print(f"[task-init] invalid template: {tpl}", file=sys.stderr); sys.exit(1)

missing, token = set(), re.compile(r"\{([A-Z0-9_]+)\}")
def sub(v):
    if isinstance(v, list): return [sub(i) for i in v]
    if not isinstance(v, str): return v
    def rep(m):
        k = m.group(1)
        if k == "BATCH_ID": return batch_id
        if k in vars_in: return vars_in[k]
        missing.add(k); return f"<{k}>"
    return token.sub(rep, v)
def q(s): return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

count = 0
for t in tasks:
    tid = sub(str(t.get("id", "")).strip())
    suffix = tid[len(batch_id) + 1:] if tid.startswith(f"{batch_id}-") else tid
    rel = f".orchestration/tasks/{batch_id}/task-{suffix}.md"
    deps = sub(t.get("depends_on", [])); deps = [deps] if isinstance(deps, str) and deps else deps
    dep_text = "[" + ", ".join(q(d) for d in (deps or [])) + "]" if deps else "[]"
    task_type = sub(str(t.get("task_type", "")))
    fmt = "code" if task_type == "code" else "markdown"
    try: slo = int(str(sub(str(t.get("slo_duration_s", "0")))))
    except ValueError: slo = 0
    content = f"""---
id: {q(tid)}
agent: {q(sub(str(t.get("agent", "copilot"))))}
reviewer: ""
timeout: 180
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: {dep_text}
task_type: {q(task_type)}
slo_duration_s: {slo}
output_format: {q(fmt)}
---

# Task: {tid}

## Objective
{sub(str(t.get("prompt", ""))).strip()}
"""
    if dry_run: print(f"--- {rel} ---\n{content.rstrip()}\n")
    else:
        out = tasks_root / batch_id / f"task-{suffix}.md"
        out.parent.mkdir(parents=True, exist_ok=True); out.write_text(content, encoding="utf-8")
    count += 1

for v in sorted(missing): print(f"[task-init] WARN: {v} not set; using <{v}>", file=sys.stderr)
msg = f"Created {count} task specs in .orchestration/tasks/{batch_id}/"
print(f"Dry run: would create {count} task specs in .orchestration/tasks/{batch_id}/" if dry_run else msg)
print(f"Next step: bin/task-dispatch.sh .orchestration/tasks/{batch_id}/ --parallel")
PY
set -u
