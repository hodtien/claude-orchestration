---
id: integration-smoke-001
agent: oc-medium
reviewer: copilot
timeout: 700
retries: 1
task_type: implement_feature
context_cache: [project-overview, architecture]
read_files: [bin/task-dispatch.sh, bin/orch-dashboard.sh, mcp-server/server.mjs, lib/orch-metrics.sh, lib/task-status.sh, bin/test-orch-metrics-rollup.sh, bin/test-task-status.sh]
---

# Task: Phase 10.2 Full pipeline integration smoke test

## Objective
Create `bin/test-full-integration.sh` — exercises the dispatch pipeline end-to-end in isolation: spec → result → status → metrics rollup → dashboard → MCP query syntax.

## Design constraints

- bash 3.2 compatible: no associative arrays, no `mapfile`, no `|&`, no namerefs
- Python3 stdlib only for JSON; no jq/yq/bc
- Fully isolated: all state in `$TMPTEST_DIR`, no repo runtime artifacts
- No real agent calls (mock the agent step)
- No network calls
- Executable: `chmod +x bin/test-full-integration.sh`
- Follow `bin/test-react-loop.sh` assertion patterns

## Strategy

Rather than invoking the live dispatcher (which calls real agents), this test:
1. Creates realistic dispatch artifacts manually (spec, .out, .status.json, audit.jsonl)
2. Calls library functions to verify they process the artifacts correctly
3. Calls dashboard subcommands against the mock state
4. Verifies MCP server syntax via `node --check`

## Test setup

```bash
TMPTEST_DIR="$(mktemp -d)"
export ORCH_DIR="$TMPTEST_DIR/.orchestration"
export RESULTS_DIR="$ORCH_DIR/results"
export PROJECT_ROOT
mkdir -p "$RESULTS_DIR" "$ORCH_DIR/tasks/smoke-test"
cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT
```

## Mock artifact formats

`.status.json`:
```json
{
  "task_id": "smoke-001",
  "agent": "oc-medium",
  "final_state": "done",
  "duration_s": 5.2,
  "exit_code": 0,
  "tokens_est": 1200,
  "created_at": "2026-04-26T12:00:00Z"
}
```

`audit.jsonl` entry:
```json
{"task_id":"smoke-001","agent":"oc-medium","status":"done","duration_s":5.2,"tokens_est":1200,"ts":"2026-04-26T12:00:00Z"}
```

## Test cases (25+)

### Phase A: Artifact creation (5)
1. Create task spec, verify frontmatter parseable
2. Mock `.out` exists
3. `.status.json` valid JSON structure
4. `audit.jsonl` valid JSONL
5. All artifacts in expected paths

### Phase B: Status library integration (5)
6. Source `lib/task-status.sh`, call functions on mock status
7. `final_state` reads correctly
8. Duration extraction
9. Agent extraction
10. Status summary on mock data

### Phase C: Metrics rollup integration (5)
11. Source `lib/orch-metrics.sh`, parse mock `audit.jsonl`
12. Metrics count the mock task
13. Success rate with 1 success
14. Add failed task → success rate drops
15. Duration metrics computed

### Phase D: Dashboard integration (5)
16. `orch-dashboard.sh metrics --json` valid JSON against mock ORCH_DIR
17. Dashboard metrics output includes mock agent
18. `orch-dashboard.sh budget --json` valid JSON (or graceful empty)
19. `orch-dashboard.sh help` lists all subcommands
20. All 10 subcommands appear in help: cost, metrics, slo, report, db, budget, learn, react, context, status

### Phase E: MCP server integration (3)
21. `node --check mcp-server/server.mjs` exit 0
22. server.mjs has all 15+ expected tool names
23. Each tool has `inputSchema` with `type: "object"`

### Phase F: Cross-component chain (5)
24. Full chain: spec → mock dispatch → result → status → metrics rollup → dashboard read
25. depends_on resolution path exists for two-task chain
26. Session context: load returns saved brief
27. Failed task: metrics counts failure
28. Empty state: dashboard commands don't crash

## Implementation notes

- Source libraries directly: `source "$PROJECT_ROOT/lib/task-status.sh"`
- Pass `ORCH_DIR` env to dashboard calls for isolation
- For MCP, use `grep` on `server.mjs` (no boot)

## Verification

```bash
bash bin/test-full-integration.sh
```

Expected: `ALL N TESTS: N PASS, 0 FAIL`

## Non-goals

- Do not start the MCP server
- Do not call real agents
- Do not dispatch real tasks
- Do not modify repo state outside TMPTEST_DIR

## Acceptance criteria

- All 25+ assertions pass
- Isolated temp state
- No repo artifacts left behind
- Full pipeline chain verified
- Dashboard subcommands work against mock data
- MCP syntax valid + tool inventory complete
