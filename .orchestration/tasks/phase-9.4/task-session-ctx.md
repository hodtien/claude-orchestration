---
id: session-ctx-001
agent: oc-medium
reviewer: copilot
timeout: 700
retries: 1
task_type: implement_feature
context_cache: [project-overview, architecture]
read_files: [docs/PLAN_phase9.md, WORK.md, lib/context-compressor.sh, bin/task-dispatch.sh, bin/agent.sh, bin/orch-dashboard.sh, mcp-server/server.mjs, lib/react-loop.sh, bin/test-react-loop.sh]
---

# Task: Phase 9.4 Session context chains

## Objective
Implement Phase 9.4: compressed session context for `depends_on` task pipelines.

Deliverables:
1. New `lib/session-context.sh` u2014 build/load session brief helpers, bash 3.2 compatible, no source-time side effects
2. Wire session context into `bin/task-dispatch.sh` at `depends_on` resolution (lines 1619-1658)
3. Add MCP tool `get_session_context(task_id)` in `mcp-server/server.mjs`
4. Add dashboard subcommand `orch-dashboard.sh context` via `bin/_dashboard/context.sh`

This is Phase 9.4 from `docs/PLAN_phase9.md` lines 129-148.

## Existing architecture to preserve

Current `depends_on` resolution lives in `bin/task-dispatch.sh`:
- Lines 1619-1658: iterates `depends_on` + `context_from` IDs, reads `$RESULTS_DIR/<id>.out`, prepends to prompt
- Lines 1660-1690: context compression fires when ctx_tokens > CONTEXT_BUDGET_THRESHOLD (default 50000)
- `bin/agent.sh` lines 104-112: reads `CONTEXT_FILE` env var, prepends to prompt
- `lib/context-compressor.sh` lines 31-50: `compress_summary(content, level)` u2014 keeps first N lines based on level float

Do NOT rewrite the existing context injection. Add a structured session brief layer on top.

## Design constraints

- bash 3.2 compatible: no associative arrays, no `mapfile`, no `|&`, no namerefs
- Python3 stdlib only for JSON work; no jq/yq/bc/pip
- No mkdir or file writes at module source time
- All paths env-overridable:
  - `PROJECT_ROOT`
  - `ORCH_DIR`
  - `RESULTS_DIR`
  - `SESSION_CTX_DIR` (default: `$ORCH_DIR/session-context`)
- Session context must be opt-in via `session_context: true` in task frontmatter or `SESSION_CONTEXT=true` env
- Default behavior must remain unchanged when disabled
- Do not call real LLMs inside `lib/session-context.sh`; it only processes existing outputs

## Deliverable 1: `lib/session-context.sh`

Create a new library with these public functions:

### `session_ctx_enabled <spec>`
Output: `true` or `false`.
Exit: always 0.

Enable if any of:
- task frontmatter contains `session_context: true`
- env `SESSION_CONTEXT=true`
- task has `depends_on` with >= 3 dependencies

Disable if task frontmatter contains `session_context: false`.

Use the same `react_parse_front` fallback pattern from `lib/react-loop.sh` u2014 copy the `react_parse_front` function and rename to `_session_parse_front`, or source `react-loop.sh` if available, or inline a minimal parser.

### `build_session_brief <task_id> <depends_on_ids_space_separated> <results_dir>`
Output: JSON object to stdout.
Required fields:
```json
{
  "task_id": "my-task-001",
  "chain_length": 3,
  "prior_tasks": [
    {
      "id": "dep-001",
      "summary": "First 3 lines or 200 chars of output...",
      "output_bytes": 1234,
      "has_output": true
    }
  ],
  "total_context_bytes": 5678,
  "compressed": false,
  "brief": "Merged summary text for injection into prompt...",
  "created_at": "2026-04-26T12:00:00Z"
}
```

Logic:
1. For each dependency ID, read `$RESULTS_DIR/<id>.out`
2. Extract a short summary: first 3 non-empty lines or first 200 chars (whichever is shorter)
3. Build a merged "brief" text: all summaries concatenated with `---` separators, max 2000 chars total
4. If total context bytes > 8000, set `compressed: true` and truncate the brief to 2000 chars
5. Return compact JSON via python3

Use python3 for JSON output to avoid shell quoting bugs.

### `save_session_context <task_id> <session_brief_json>`
Writes session brief JSON to `$SESSION_CTX_DIR/<task_id>.session.json`.
Creates `$SESSION_CTX_DIR` on first call (never at source time).
Return: 0 on success.

### `load_session_context <task_id>`
Reads `$SESSION_CTX_DIR/<task_id>.session.json` and outputs JSON to stdout.
If no file exists, return:
```json
{"task_id":"<task_id>","chain_length":0,"prior_tasks":[],"total_context_bytes":0,"compressed":false,"brief":"","created_at":""}
```

### `inject_session_brief <session_brief_json> <prompt>`
Output: modified prompt with session brief prepended.
Format:
```
--- Session Context Brief ---
<brief text from JSON>
--- End Session Brief ---

<original prompt>
```
If brief is empty, return original prompt unchanged.

### `_session_safe_tid <task_id>`
Same path traversal guard as `_react_safe_tid` in `lib/react-loop.sh` u2014 validate task_id contains only `[A-Za-z0-9._-]`, reject `/`, `..`, backslash.

### Source guard / standalone CLI
Add source guard like existing libs. Standalone commands:
```bash
bash lib/session-context.sh brief <task_id> <dep1> <dep2> ... -- <results_dir>
bash lib/session-context.sh load <task_id>
```

## Deliverable 2: Wire into `bin/task-dispatch.sh`

### Step 1: Source lib
After the `react-loop.sh` source block (around lines 64-73), add:
```bash
# shellcheck source=../lib/session-context.sh
if [ -f "$SCRIPT_DIR/../lib/session-context.sh" ]; then
    . "$SCRIPT_DIR/../lib/session-context.sh"
else
    session_ctx_enabled() { echo "false"; }
    build_session_brief() { echo '{}'; }
    save_session_context() { return 0; }
    load_session_context() { echo '{}'; }
    inject_session_brief() { echo "$2"; }
fi
```

### Step 2: Config defaults
After the ReAct config defaults (around lines 105-108), add:
```bash
SESSION_CONTEXT="${SESSION_CONTEXT:-false}"
SESSION_CTX_DIR="${SESSION_CTX_DIR:-$ORCH_DIR/session-context}"
```

### Step 3: Wire session brief into depends_on resolution
In the `depends_on` context injection block (lines 1619-1658), AFTER the `ctx_block` is built but BEFORE it is prepended to `prompt` (line 1656), add:

```bash
      # Session context brief (Phase 9.4)
      local session_enabled="false"
      session_enabled=$(session_ctx_enabled "$spec" 2>/dev/null || echo "false")
      if [ "$session_enabled" = "true" ] && [ -n "$ctx_tasks" ]; then
        local session_brief
        session_brief=$(build_session_brief "$tid" "$ctx_tasks" "$RESULTS_DIR" 2>/dev/null || echo '{}')
        save_session_context "$tid" "$session_brief" 2>/dev/null || true
        local brief_text
        brief_text=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('brief',''))" "$session_brief" 2>/dev/null || echo "")
        if [ -n "$brief_text" ]; then
          prompt=$(inject_session_brief "$session_brief" "$prompt" 2>/dev/null || echo "$prompt")
          echo "[dispatch] session brief injected for $tid ($(echo \"$brief_text\" | wc -c | tr -d ' ')B)"
        fi
      fi
```

Adapt placement to current code. Keep behavior unchanged when disabled.

## Deliverable 3: MCP `get_session_context`

In `mcp-server/server.mjs`:

### Add helper near `runGetReactTrace()`:
```javascript
function runGetSessionContext(taskId) {
  const libPath = join(PROJECT_ROOT, "lib", "session-context.sh");
  if (!existsSync(libPath)) return { error: "lib/session-context.sh not found" };
  if (!taskId) return { error: "task_id is required" };
  if (!/^[A-Za-z0-9._-]+$/.test(taskId)) return { error: "invalid task_id" };
  try {
    const result = spawnSync("bash", [libPath, "load", taskId], {
      encoding: "utf8",
      timeout: 10000,
      env: { ...process.env, PROJECT_ROOT },
    });
    if (result.status === 0 && result.stdout) return JSON.parse(result.stdout);
    return { error: (result.stderr || "session context load failed").slice(0, 500) };
  } catch (e) {
    return { error: String(e).slice(0, 500) };
  }
}
```

### Add tool entry after `get_react_trace`:
```javascript
{
  name: "get_session_context",
  description: "Get the session context brief for a task in a depends_on pipeline.",
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
case "get_session_context":
  result = runGetSessionContext(args?.task_id || "");
  break;
```

## Deliverable 4: dashboard `context`

Add to `bin/orch-dashboard.sh` case statement:
```bash
  context) source "$SCRIPT_DIR/_dashboard/context.sh" "$@" ;;
```

Help text:
```text
  context   Show session context briefs for task pipelines. Flags: --json --task-id <id>
```

Create `bin/_dashboard/context.sh`:
- `--json`: output aggregate JSON
- `--task-id <id>`: filter one task
- Without args: scan `${SESSION_CTX_DIR:-$ORCH_DIR/session-context}/*.session.json`
- Human output columns: Task ID, Chain Length, Total Bytes, Compressed, Brief (first 60 chars)
- If no sessions: print `No session context briefs recorded yet.` and exit 0

Follow the exact pattern of `bin/_dashboard/react.sh` for structure.

## Verification

Run:
```bash
bash -c 'source lib/session-context.sh; echo OK'
bash lib/session-context.sh load made-up-task
bash bin/orch-dashboard.sh context --json
node --check mcp-server/server.mjs
```

Expected:
- sourcing has zero filesystem side effects
- missing task returns JSON with `chain_length: 0`
- dashboard does not crash when no sessions exist
- MCP server syntax is valid

## Non-goals

- Do not implement LLM-based summarization u2014 use line/char truncation only
- Do not replace existing `depends_on` context injection u2014 layer on top
- Do not make session context default-on
- Do not add new dependencies

## Acceptance criteria

- `lib/session-context.sh` exists and exposes all functions above
- `dispatch_task_first_success()` supports opt-in session brief injection without changing default behavior
- MCP lists and handles `get_session_context`
- Dashboard has `context` subcommand
- Existing tests still pass
