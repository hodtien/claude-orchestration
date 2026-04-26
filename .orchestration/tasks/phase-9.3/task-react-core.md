---
id: react-core-001
agent: oc-medium
reviewer: copilot
timeout: 700
retries: 1
task_type: implement_feature
context_cache: [project-overview, architecture]
read_files: [docs/PLAN_phase9.md, WORK.md, config/models.yaml, lib/quality-gate.sh, lib/learning-engine.sh, lib/task-status.sh, bin/task-dispatch.sh, bin/orch-dashboard.sh, mcp-server/server.mjs]
---

# Task: Phase 9.3 ReAct adaptive dispatch core

## Objective
Implement Phase 9.3: adaptive ReAct dispatch for uncertain or long-running first-success tasks.

Deliverables:
1. New `lib/react-loop.sh` — observe/think/act helper library, bash 3.2 compatible, no source-time side effects
2. Wire optional ReAct mode into `bin/task-dispatch.sh` for `dispatch_task_first_success()`
3. Add config fields to `config/models.yaml`: `react_mode`, `react_max_turns`, `react_quality_threshold`
4. Add MCP tool `get_react_trace(task_id)` in `mcp-server/server.mjs`
5. Add dashboard subcommand `orch-dashboard.sh react` via `bin/_dashboard/react.sh`

This is Phase 9.3 from `docs/PLAN_phase9.md` lines 112-127.

## Existing architecture to preserve

Current first-success flow lives in `bin/task-dispatch.sh`:
- Source blocks near lines 20-63 load libs. Add `react-loop.sh` after `learning-engine.sh`.
- `dispatch_task()` calls `dispatch_task_first_success` around lines 1459-1464.
- `dispatch_task_first_success()` begins around line 1464.
- Agent attempts happen inside the loop that eventually reaches quality gate around lines 1821-1834.
- Success status JSON is written around lines 1852-1856.
- Learning hook is at lines 1858-1859.
- Failure/DLQ path begins around line 1883.

Do not rewrite the dispatcher. Add a small optional hook around the already-existing quality-gate decision.

## Design constraints

- bash 3.2 compatible: no associative arrays, no `mapfile`, no `|&`, no namerefs
- Python3 stdlib only for JSON work; no jq/yq/bc/pip
- No mkdir or file writes at module source time
- All paths env-overridable:
  - `PROJECT_ROOT`
  - `ORCH_DIR`
  - `RESULTS_DIR`
  - `REACT_DIR`
  - `REACT_TRACE_DIR`
  - `REACT_MAX_TURNS`
  - `REACT_QUALITY_THRESHOLD`
- ReAct must be opt-in. Existing dispatch behavior must be unchanged when disabled.
- Wrap ReAct calls with `|| true` where they must not break dispatch.
- Do not call real LLMs inside `lib/react-loop.sh`; it only evaluates existing output and returns a decision.
- Do not touch consensus dispatch except for shared helper sourcing if unavoidable.

## Deliverable 1: `lib/react-loop.sh`

Create a new library with these public functions:

### `react_enabled_for_task <spec> <task_type> <timeout>`
Output: `true` or `false`.
Exit: always 0.

Enable if any of these is true:
- task frontmatter contains `react_mode: true`
- env/config global `REACT_MODE=true`
- task is high-uncertainty by heuristic: `timeout >= 300` OR prompt body length > 4000 chars

Disable if task frontmatter contains `react_mode: false`.

Implementation notes:
- Use existing `parse_front`/`parse_body` if available; otherwise degrade safely.
- This function should not parse YAML deeply. The existing dispatcher frontmatter parser is enough.

### `react_observe <tid> <agent> <output_file> <log_file>`
Output: compact JSON object to stdout.
Required fields:
```json
{
  "task_id": "react-smoke-001",
  "agent": "oc-medium",
  "output_chars": 1234,
  "log_chars": 456,
  "has_output": true,
  "has_error": false,
  "placeholder": false,
  "quality_score": 0.82,
  "observed_at": "2026-04-26T00:00:00Z"
}
```

Quality score heuristic:
- Start at `0.0`
- +0.35 if output file exists and non-empty
- +0.25 if output chars >= `MIN_OUTPUT_LENGTH` (default 20)
- +0.20 if output does not match placeholder patterns: `todo`, `fixme`, `wip`, `not implemented`, `coming soon`
- +0.10 if log does not include common hard errors: `Traceback`, `SyntaxError`, `command not found`, `No such file`, `timeout`
- +0.10 if output chars >= 500
- Clamp to `0.0..1.0`

Use python3 for JSON output to avoid shell quoting bugs.

### `react_think <observation_json> <threshold>`
Output: JSON decision object.
Required fields:
```json
{
  "decision": "accept",
  "reason": "quality_above_threshold",
  "quality_score": 0.82,
  "threshold": 0.7,
  "next_action": "continue"
}
```

Decision rules:
- `accept` if `quality_score >= threshold`
- `redirect` if has output but score below threshold and output is not a placeholder
- `retry` if no output or placeholder
- `abort` only for hard errors with no output

### `react_record_trace <tid> <turn> <agent> <observation_json> <decision_json>`
Writes one JSONL line to `$REACT_TRACE_DIR/${tid}.react.jsonl`.
Fields:
```json
{
  "task_id": "react-smoke-001",
  "turn": 1,
  "agent": "oc-medium",
  "observation": { ... },
  "decision": { ... },
  "created_at": "2026-04-26T00:00:00Z"
}
```

This function may create `$REACT_TRACE_DIR`, but only when called.

### `react_get_trace <tid>`
Reads `$REACT_TRACE_DIR/${tid}.react.jsonl` and returns aggregate JSON:
```json
{
  "task_id": "react-smoke-001",
  "turns": 2,
  "final_decision": "accept",
  "trace": [ ... ]
}
```
If no trace exists, return:
```json
{"task_id":"react-smoke-001","turns":0,"trace":[]}
```

### `react_select_next_agent <current_agent> <agent_candidates> <decision_json>`
Output: next agent name or empty string.
Rules:
- For `redirect`, return the next distinct candidate after current agent.
- For `retry`, return current agent.
- For `accept` or `abort`, return empty.
- Work with a space-separated `agent_candidates` string.

### Source guard / standalone CLI
Add source guard like existing libs. Standalone commands:
```bash
bash lib/react-loop.sh trace <task_id>
bash lib/react-loop.sh observe <task_id> <agent> <output_file> <log_file>
```

## Deliverable 2: Wire into `bin/task-dispatch.sh`

### Step 1: Source lib
After the `learning-engine.sh` source block near lines 57-63, add:
```bash
# shellcheck source=../lib/react-loop.sh
if [ -f "$SCRIPT_DIR/../lib/react-loop.sh" ]; then
    . "$SCRIPT_DIR/../lib/react-loop.sh"
else
    react_enabled_for_task() { echo "false"; }
    react_observe() { echo '{}'; }
    react_think() { echo '{"decision":"accept"}'; }
    react_record_trace() { return 0; }
    react_select_next_agent() { return 0; }
fi
```

### Step 2: Config defaults
After batch/config initialization, add env defaults:
```bash
REACT_MODE="${REACT_MODE:-false}"
REACT_MAX_TURNS="${REACT_MAX_TURNS:-3}"
REACT_QUALITY_THRESHOLD="${REACT_QUALITY_THRESHOLD:-0.7}"
```

If `config/models.yaml` already contains the fields, parse them with the existing lightweight grep/awk style. If parsing is not cleanly available, keep env defaults and the explicit task frontmatter override as the controlling mechanism.

### Step 3: Optional ReAct decision after quality gate
In `dispatch_task_first_success()`, after the quality gate block around lines 1821-1834 and before report generation around 1836, add a small decision section:

```bash
      local react_enabled="false"
      react_enabled=$(react_enabled_for_task "$spec" "${task_type:-}" "${timeout:-0}" 2>/dev/null || echo "false")
      if [ "$react_enabled" = "true" ]; then
        local react_turns react_obs react_decision react_action react_next
        react_turns=$(find "${REACT_TRACE_DIR:-$ORCH_DIR/react-traces}" -name "${tid}.react.jsonl" -type f 2>/dev/null | wc -l | tr -d ' ')
        react_obs=$(react_observe "$tid" "$agent" "$RESULTS_DIR/${tid}.out" "$RESULTS_DIR/${tid}.log" 2>/dev/null || echo '{}')
        react_decision=$(react_think "$react_obs" "${REACT_QUALITY_THRESHOLD:-0.7}" 2>/dev/null || echo '{"decision":"accept"}')
        react_record_trace "$tid" "$((react_turns + 1))" "$agent" "$react_obs" "$react_decision" 2>/dev/null || true
        react_action=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('decision','accept'))" "$react_decision" 2>/dev/null || echo "accept")

        if [ "$react_action" = "redirect" ] && [ "$((react_turns + 1))" -lt "${REACT_MAX_TURNS:-3}" ]; then
          react_next=$(react_select_next_agent "$agent" "$agent_candidates" "$react_decision" 2>/dev/null || echo "")
          if [ -n "$react_next" ]; then
            echo "[dispatch] ReAct redirect: $tid $agent -> $react_next"
            agent_candidates="$react_next $agent_candidates"
            continue
          fi
        elif [ "$react_action" = "retry" ] && [ "$((react_turns + 1))" -lt "${REACT_MAX_TURNS:-3}" ]; then
          echo "[dispatch] ReAct retry: $tid on $agent"
          agent_candidates="$agent $agent_candidates"
          continue
        elif [ "$react_action" = "abort" ]; then
          echo "[dispatch] ReAct abort: $tid"
          task_status="needs_revision"
        fi
      fi
```

Adapt the exact placement to current code. Keep behavior unchanged when disabled.

Important: avoid infinite loops. ReAct turns must be capped by `REACT_MAX_TURNS`.

## Deliverable 3: `config/models.yaml`

Under a new top-level `react_policy`, add:
```yaml
react_policy:
  react_mode: false
  react_max_turns: 3
  react_quality_threshold: 0.7
```

Prefer `react_policy` to avoid overloading consensus `parallel_policy`.

## Deliverable 4: MCP `get_react_trace`

In `mcp-server/server.mjs`:

### Add helper near `runGetRoutingAdvice()` / `runDecomposePreview()`:
```javascript
function runGetReactTrace(taskId) {
  const libPath = join(PROJECT_ROOT, "lib", "react-loop.sh");
  if (!existsSync(libPath)) return { error: "lib/react-loop.sh not found" };
  if (!taskId) return { error: "task_id is required" };
  try {
    const result = spawnSync("bash", [libPath, "trace", taskId], {
      encoding: "utf8",
      timeout: 10000,
      env: { ...process.env, PROJECT_ROOT },
    });
    if (result.status === 0 && result.stdout) return JSON.parse(result.stdout);
    return { error: (result.stderr || "react trace failed").slice(0, 500) };
  } catch (e) {
    return { error: String(e).slice(0, 500) };
  }
}
```

### Add tool entry after `get_routing_advice`:
```javascript
{
  name: "get_react_trace",
  description: "Get the observe/think/act ReAct trace for a dispatched task.",
  inputSchema: {
    type: "object",
    properties: {
      task_id: { type: "string", description: "Task ID to inspect" }
    },
    required: ["task_id"]
  }
}
```

### Add switch case:
```javascript
case "get_react_trace":
  result = runGetReactTrace(args?.task_id || "");
  break;
```

## Deliverable 5: dashboard `react`

Add to `bin/orch-dashboard.sh` case statement:
```bash
  react)   source "$SCRIPT_DIR/_dashboard/react.sh" "$@" ;;
```

Help text:
```text
  react     Show ReAct observe/think/act traces. Flags: --json --task-id <id>
```

Create `bin/_dashboard/react.sh`:
- `--json`: output aggregate JSON
- `--task-id <id>`: filter one task
- Without args: scan `${REACT_TRACE_DIR:-$ORCH_DIR/react-traces}/*.react.jsonl`
- Human output columns: Task ID, Turns, Final Decision, Last Agent, Last Score
- If no traces: print `No ReAct traces recorded yet.` and exit 0

## Verification

Run:
```bash
bash -c 'source lib/react-loop.sh; echo OK'
bash lib/react-loop.sh trace made-up-task
bash bin/orch-dashboard.sh react --json
node --check mcp-server/server.mjs
```

Expected:
- sourcing has zero filesystem side effects
- missing trace returns JSON with `turns: 0`
- dashboard does not crash when no traces exist
- MCP server syntax is valid

## Non-goals

- Do not implement streaming partial-output observation in this phase. Observe after each agent attempt only.
- Do not replace consensus or reflexion loops.
- Do not add new dependencies.
- Do not make ReAct default-on.

## Acceptance criteria

- `lib/react-loop.sh` exists and exposes all functions above
- `dispatch_task_first_success()` supports opt-in ReAct retry/redirect/abort without changing default behavior
- `config/models.yaml` contains `react_policy`
- MCP lists and handles `get_react_trace`
- Dashboard has `react` subcommand
- Existing tests still pass, especially `bin/test-learning-engine.sh` and dispatch smoke tests if available
