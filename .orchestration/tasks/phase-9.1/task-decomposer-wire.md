---
id: decomposer-wire-001
agent: oc-medium
reviewer: copilot
timeout: 300
retries: 1
task_type: implement_feature
context_cache: [project-overview, architecture]
read_files: [lib/task-decomposer.sh, bin/task-dispatch.sh, mcp-server/server.mjs, config/models.yaml, docs/PLAN_phase9.md]
---

# Task: Wire task-decomposer.sh into dispatch pipeline + MCP tool

## Objective
Three deliverables:
1. Fix bugs in `lib/task-decomposer.sh` (ORCH_DIR, jq dependency, mkdir side-effect)
2. Wire `decompose_task()` into `bin/task-dispatch.sh` pre-dispatch phase
3. Register `decompose_preview` MCP tool in `mcp-server/server.mjs`

This is Phase 9.1 of the orchestration roadmap. Full analysis at `docs/PLAN_phase9.md`.

## Context

`lib/task-decomposer.sh` (344 lines) exists with 5 functions: `estimate_complexity()`, `decompose_task()`, `generate_pipeline_graph()`, `generate_parallel_graph()`, `analyze_intent()`, `generate_spec()`. All implemented but NOT wired into dispatch and contain 3 bugs.

Patterns to follow exactly:
- `lib/task-status.sh` — source guard pattern in task-dispatch.sh (line 44-49)
- `lib/trace-query.sh` — env-overridable paths for test isolation
- `mcp-server/server.mjs` `runTraceQuery()` / `runBudgetDashboard()` — thin spawnSync delegation

## Deliverable 1: Fix bugs in `lib/task-decomposer.sh`

### Bug 1: Wrong ORCH_DIR default (CRITICAL)
**Current** (line 7):
```bash
ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
```
**Fix:**
```bash
ORCH_DIR="${ORCH_DIR:-${PROJECT_ROOT:-.}/.orchestration}"
```
This matches `bin/task-dispatch.sh` line 69: `ORCH_DIR="$PROJECT_ROOT/.orchestration"`.

### Bug 2: jq dependency (HIGH)
Lines 108, 132, 268-274 use `jq` for JSON manipulation. All other Phase 6-8 code uses python3 stdlib (json module). Replace all `jq` calls with python3 one-liners.

**Line 108** — replace `jq ". + [\"$unit_num\"]"` with:
```bash
units=$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); a.append(sys.argv[2]); print(json.dumps(a))" "$units" "$unit_num")
```

**Line 132** — same pattern for final unit append.

**Lines 268-274** — `generate_spec()` uses `jq -r` to parse intent JSON. Replace with:
```bash
intent_type=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['intent_type'])" "$intent_json")
scope=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['scope'])" "$intent_json")
complexity=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['complexity_estimate'])" "$intent_json")
original=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['original_input'])" "$intent_json")
```

Or consolidate into a single python3 call that outputs all 4 values.

### Bug 3: mkdir at module load time (MEDIUM)
**Current** (line 11):
```bash
mkdir -p "$DECOMP_DIR"
```
**Fix:** Remove this line. Let `decompose_task()` create the directory when needed (line 59 already does `mkdir -p "$output_dir"`). Module source should have zero side effects.

### Additional: Add env overrides for test isolation
Add at the top of the file (after ORCH_DIR):
```bash
DECOMP_DIR="${DECOMP_DIR:-$ORCH_DIR/decomposed}"
TASK_DB="${TASK_DB:-$ORCH_DIR/task-db.jsonl}"
```
(DECOMP_DIR is already on line 8, just ensure it uses the corrected ORCH_DIR.)

## Deliverable 2: Wire into `bin/task-dispatch.sh`

### Step 1: Source the lib
After line 49 (task-status.sh source), add:
```bash
# shellcheck source=../lib/task-decomposer.sh
if [ -f "$SCRIPT_DIR/../lib/task-decomposer.sh" ]; then
    . "$SCRIPT_DIR/../lib/task-decomposer.sh"
else
    estimate_complexity() { echo "500"; }
    decompose_task() { return 1; }
fi
```

### Step 2: Add auto_decompose to batch.conf parsing
In `load_batch_conf()` (line 307), add `"auto_decompose"` to the `allowed` set:
```python
allowed = {"failure_mode", "max_failures", "notify_on_failure", "auto_decompose"}
```
And add to the for loop at line 326:
```python
for key in ("failure_mode", "max_failures", "notify_on_failure", "budget_tokens", "auto_decompose"):
```

Add a global variable after `BATCH_CONF` (line 79):
```bash
AUTO_DECOMPOSE="${AUTO_DECOMPOSE:-false}"
```

### Step 3: Pre-dispatch decomposition check
In the `dispatch_task()` function (line 1325), BEFORE the consensus/first_success routing (line 1333), add:
```bash
  # Phase 9.1: auto-decompose complex tasks
  if [[ "$AUTO_DECOMPOSE" == "true" ]]; then
    local spec_body spec_lines complexity_est
    spec_body=$(sed '1,/^---$/d' "$spec" | sed '/^---$/,/^---$/d')
    spec_lines=$(echo "$spec_body" | wc -l | tr -d ' ')
    complexity_est=$(estimate_complexity "$spec_body" "$spec")
    if [[ "$spec_lines" -gt 80 ]] || [[ "$complexity_est" -gt 2000 ]]; then
      local tid_decomp
      tid_decomp=$(parse_front "$spec" "id" "unknown")
      echo "[dispatch] auto-decompose $tid_decomp (${spec_lines} lines, complexity ${complexity_est})"
      local decomp_dir
      decomp_dir=$(decompose_task "$tid_decomp" "$spec_body" "$complexity_est" 2>/dev/null || true)
      if [[ -d "$decomp_dir" ]] && [[ -f "$decomp_dir/meta.json" ]]; then
        local unit_count
        unit_count=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['unit_count'])" "$decomp_dir/meta.json" 2>/dev/null || echo "0")
        if [[ "$unit_count" -gt 1 ]]; then
          echo "[dispatch] decomposed into $unit_count units → $decomp_dir"
          # Dispatch sub-units (sequential for now)
          local unit_spec
          for unit_spec in "$decomp_dir"/unit-*.md; do
            [ -f "$unit_spec" ] || continue
            dispatch_task_first_success "$unit_spec" "$agent_override"
          done
          return $?
        fi
      fi
    fi
  fi
```

This is ~20 lines inserted before line 1333. The decomposition is opt-in via `auto_decompose: true` in batch.conf.

## Deliverable 3: `decompose_preview` MCP tool

### Add to `mcp-server/server.mjs` ListToolsRequestSchema handler:
```javascript
{
  name: "decompose_preview",
  description: "Preview how a task spec would be auto-decomposed into 15-min units. Returns unit count, strategy, and unit summaries without dispatching. Use to validate decomposition before running a batch.",
  inputSchema: {
    type: "object",
    properties: {
      task_spec: { type: "string", description: "Full task spec content (frontmatter + body)" },
      task_id: { type: "string", description: "Task ID for the preview (default: 'preview')" }
    },
    required: ["task_spec"]
  }
}
```

### Add to CallToolRequestSchema switch:
```javascript
case "decompose_preview": {
  result = runDecomposePreview(args?.task_spec || "", args?.task_id || "preview");
  break;
}
```

### Add helper function (parallel to `runTraceQuery`):
```javascript
function runDecomposePreview(taskSpec, taskId) {
  const helperPath = join(PROJECT_ROOT, "lib", "task-decomposer.sh");
  if (!existsSync(helperPath)) {
    return { error: "lib/task-decomposer.sh not found" };
  }
  try {
    // Write spec to temp file, decompose, read meta.json
    const result = spawnSync("bash", ["-c", `
      source "${helperPath}"
      export ORCH_DIR=$(mktemp -d)
      export DECOMP_DIR="$ORCH_DIR/decomposed"
      complexity=$(estimate_complexity "$1" "")
      output_dir=$(decompose_task "$2" "$1" "$complexity")
      if [ -f "$output_dir/meta.json" ]; then
        cat "$output_dir/meta.json"
      else
        echo '{"error":"decomposition produced no output"}'
      fi
      rm -rf "$ORCH_DIR"
    `, "--", taskSpec, taskId], {
      encoding: "utf8",
      timeout: 15000,
      env: { ...process.env, PROJECT_ROOT },
    });
    if (result.status === 0 && result.stdout) {
      return JSON.parse(result.stdout);
    }
    return { error: (result.stderr || "decompose failed").slice(0, 500) };
  } catch (e) {
    return { error: String(e).slice(0, 500) };
  }
}
```

## Constraints
- Python3 stdlib only — NO jq, NO PyYAML, NO pip packages
- Decomposition is opt-in (disabled by default via `AUTO_DECOMPOSE=false`)
- Do not touch existing dispatch functions (consensus/first_success)
- Do not touch existing MCP tools (10 tools — only add the 11th)
- All env vars overridable for test isolation (ORCH_DIR, DECOMP_DIR, TASK_DB)
- bash 3.2 compatible (no associative arrays, no `|&`)
- Module source must have zero side effects (no mkdir at load time)

## Verification
After changes:
```bash
# Source test — should not crash or create dirs
bash -c 'source lib/task-decomposer.sh; echo OK'

# Standalone test
bash lib/task-decomposer.sh complexity "implement new authentication with database migration" ""

# Dispatch test (opt-in disabled by default — should not decompose)
task-dispatch.sh .orchestration/tasks/phase-9.1/ --status
```
