# Phase 8.3 — Execution trace viewer via `orch-notify` MCP

**Date:** 2026-04-24
**Prereqs:** Phase 8.1 (`.status.json` canonical), Phase 8.2 (rollup aggregator) landed.
**Scope:** Expose task execution trace data through `orch-notify` MCP so Claude can query trace/waterfall without shelling out. Bridge the existing `bin/orch-trace.sh` (137-line CLI) + `.orchestration/tasks.jsonl` (event audit log) + `.status.json` (terminal state from 8.1) + `rollup` aggregate (from 8.2) into **three new MCP tools**.
**Out of scope:** Browser UI, time-series storage, pushing traces over webhooks, DAG visualization (kept for 8.4 or later).

---

## Context

Claude currently has five `orch-notify` MCP tools: `check_inbox`, `check_batch_status`, `list_batches`, `quick_metrics`, `get_project_health`, `check_escalations`. None expose per-task execution detail — to inspect *why* a task exhausted or took 45s, Claude must run `bin/orch-trace.sh` via Bash, which burns context on shell formatting and is awkward for structured downstream use.

Phase 8.3 adds three tools that return structured JSON the LLM can reason over directly:

1. **`get_task_trace(task_id)`** — full event timeline for one task + its `.status.json` + any reflexion blobs.
2. **`get_trace_waterfall(trace_id)`** — waterfall timing (who ran when, duration, parent/child agent relationships) for the trace.
3. **`recent_failures(limit, since)`** — most recent `final_state ∈ {failed, exhausted, needs_revision}` with their root-cause signals (last event, markers, reflexion iterations).

These three make it so Claude can ask "what happened to task X" or "what's been failing today" in a single MCP round-trip.

---

## Data sources (already present — do not reshape)

| Source | Path | Record shape | Used for |
|---|---|---|---|
| Event audit log | `.orchestration/tasks.jsonl` | `{event, task_id, trace_id, agent, status, ts, ...}` | timeline events, waterfall timing |
| Terminal state | `.orchestration/results/*.status.json` | schema v1 (Phase 8.1) — 15 fields | final outcome, duration, strategy |
| Reflexion artifacts | `.orchestration/reflexion/<task_id>.v{1,2}.reflexion.json` | `{iteration, reason, peer_output_summary, ...}` | reflexion loop history |
| Dispatch audit | `.orchestration/audit.jsonl` | `{event: tier_assigned|..., task_id, tokens_estimated, timestamp}` | tier + token signals |

Do not add a new on-disk schema. 8.3 is read-only aggregation over existing files.

---

## MCP tool specs

### Tool 1: `get_task_trace`

**Input:**
```json
{ "task_id": "arch-test-001" }
```

**Output:**
```json
{
  "task_id": "arch-test-001",
  "found": true,
  "status": {
    "schema_version": 1,
    "task_type": "architecture_analysis",
    "strategy_used": "consensus",
    "final_state": "done",
    "winner_agent": "merged",
    "candidates_tried": ["gemini-pro", "cc/claude-sonnet-4-6", "minimax-code"],
    "successful_candidates": ["gemini-pro", "cc/claude-sonnet-4-6"],
    "consensus_score": 0.72,
    "reflexion_iterations": 1,
    "markers": [],
    "duration_sec": 14.5,
    "started_at": "2026-04-24T08:00:00Z",
    "completed_at": "2026-04-24T08:00:14Z"
  },
  "events": [
    { "ts": "2026-04-24T08:00:00Z", "event": "task_start", "agent": null, "trace_id": "trace-abc" },
    { "ts": "2026-04-24T08:00:02Z", "event": "agent_dispatch", "agent": "gemini-pro", "trace_id": "trace-abc" },
    { "ts": "2026-04-24T08:00:08Z", "event": "agent_complete", "agent": "gemini-pro", "status": "ok", "trace_id": "trace-abc" },
    { "ts": "2026-04-24T08:00:14Z", "event": "task_complete", "status": "done", "trace_id": "trace-abc" }
  ],
  "reflexion": [
    { "iteration": 1, "reason": "sim_below_threshold", "score": 0.18, "at": "2026-04-24T08:00:10Z" }
  ],
  "audit_hints": [
    { "event": "tier_assigned", "tier": "TIER_STANDARD", "tokens_estimated": 200, "ts": "2026-04-24T07:59:58Z" }
  ]
}
```

**When not found:** return `{"task_id": "...", "found": false, "reason": "no_status_file_and_no_events"}` — exit 0, never throw. LLM should handle this gracefully.

**Rules:**
- `.status.json` is authoritative for terminal fields. If absent → `status: null, found: true if any events, false otherwise`.
- `events` = all rows in `tasks.jsonl` matching `task_id`, sorted by `ts` ascending.
- `reflexion` = parse all `<task_id>.v*.reflexion.json` in `.orchestration/reflexion/`, sort by iteration.
- `audit_hints` = rows from `.orchestration/audit.jsonl` matching this `task_id` (tier_assigned, route_decision, etc.).
- Hard cap: 500 events max. If exceeded, truncate tail and add `"truncated": true`.

### Tool 2: `get_trace_waterfall`

**Input:**
```json
{ "trace_id": "trace-abc" }
```

**Output:**
```json
{
  "trace_id": "trace-abc",
  "found": true,
  "task_ids": ["arch-test-001"],
  "span": { "started_at": "2026-04-24T08:00:00Z", "completed_at": "2026-04-24T08:00:14Z", "duration_sec": 14.0 },
  "lanes": [
    {
      "agent": "gemini-pro",
      "task_id": "arch-test-001",
      "started_at": "2026-04-24T08:00:02Z",
      "completed_at": "2026-04-24T08:00:08Z",
      "duration_sec": 6.0,
      "status": "ok"
    },
    {
      "agent": "cc/claude-sonnet-4-6",
      "task_id": "arch-test-001",
      "started_at": "2026-04-24T08:00:02Z",
      "completed_at": "2026-04-24T08:00:11Z",
      "duration_sec": 9.0,
      "status": "ok"
    }
  ],
  "parallelism": { "max_concurrent_agents": 2, "total_agent_time_sec": 15.0, "wall_time_sec": 14.0, "speedup": 1.07 }
}
```

**Rules:**
- Extract all events with matching `trace_id` from `tasks.jsonl`.
- Pair each `agent_dispatch` with the matching `agent_complete` (same `task_id` + `agent`) to form a lane. If no matching complete within the trace, lane is left-open and `status: "unknown"`, `completed_at: null`, `duration_sec: null`.
- `max_concurrent_agents` = max lanes active at any instant (sweep-line algorithm).
- `total_agent_time_sec` = sum of all lane durations (null-durations count as 0).
- `speedup` = `total_agent_time_sec / wall_time_sec`, rounded to 2 decimals. If `wall_time_sec == 0` → `1.0`.
- Not found: `{"trace_id": "...", "found": false}`, exit 0.

### Tool 3: `recent_failures`

**Input:**
```json
{ "limit": 10, "since": "24h" }
```

**Output:**
```json
{
  "generated_at": "2026-04-24T12:00:00Z",
  "filter": { "limit": 10, "since": "24h" },
  "scanned": 142,
  "failures": [
    {
      "task_id": "impl-feature-007",
      "task_type": "implement_feature",
      "final_state": "failed",
      "strategy_used": "consensus_exhausted",
      "completed_at": "2026-04-24T11:45:12Z",
      "duration_sec": 45.0,
      "reflexion_iterations": 3,
      "consensus_score": 0.08,
      "candidates_tried": ["oc-medium", "gh/gpt-5.3-codex", "cc/claude-sonnet-4-6"],
      "successful_candidates": [],
      "markers": [".exhausted", ".disagreement"],
      "last_event": { "event": "task_complete", "status": "failed", "ts": "2026-04-24T11:45:12Z" }
    }
  ]
}
```

**Rules:**
- Scan all `.status.json` in `.orchestration/results/`, filter `final_state ∈ {failed, exhausted, needs_revision}`.
- `since` uses the same parser as 8.2 rollup (`Nh`, `Nd`, ISO8601). Files with unparseable `completed_at` are excluded when `since` is active, included when absent.
- Sort descending by `completed_at`, take top `limit` (default 10, cap 100).
- `last_event` = final event for this `task_id` in `tasks.jsonl` (tail lookup).
- No failures: `failures: []`, `scanned: N`. Never throw.

---

## Implementation

### Files to touch

| File | Role | Expected change |
|---|---|---|
| `mcp-server/server.mjs` | Add 3 tool handlers + schemas | +~180 lines |
| `lib/trace-query.sh` **(new)** | Shell helpers that return JSON on stdout for the three operations | ~220 lines |
| `bin/test-trace-query.sh` **(new)** | Unit tests calling `lib/trace-query.sh` with seeded fixtures | ~220 lines |
| `test-fixtures/trace/` **(new)** | Fixtures: seeded `tasks.jsonl`, `.status.json`, reflexion blobs, `audit.jsonl` | 6–10 files |

**Keep the MCP handler thin:** MCP handler calls `lib/trace-query.sh get_task_trace <task_id>` → reads stdout → returns `{ content: [{ type: "text", text: <json> }] }` unchanged. Same pattern as existing `check_batch_status`. The shell helper is where the real logic lives; tests run against the shell without needing a live MCP server.

### MCP handler skeleton (`server.mjs`)

Follow the existing pattern at the `check_batch_status` handler (`server.mjs:~420`). For each new tool:

```javascript
{
  name: "get_task_trace",
  description: "Fetch full execution trace for one task — status.json fields, all events from tasks.jsonl, reflexion history, audit hints.",
  inputSchema: {
    type: "object",
    properties: {
      task_id: { type: "string", description: "Task ID (e.g., 'arch-test-001')" }
    },
    required: ["task_id"]
  }
}
```

Handler body: exec `lib/trace-query.sh get_task_trace "$task_id"`, pass stdout through as text content. On non-zero exit, return `{ found: false, error: stderr }` — never leak stack traces to the LLM.

### Shell helper dispatch (`lib/trace-query.sh`)

```bash
case "${1:-}" in
  get_task_trace)    shift; _get_task_trace "$@" ;;
  get_trace_waterfall) shift; _get_trace_waterfall "$@" ;;
  recent_failures)   shift; _recent_failures "$@" ;;
  *) echo "usage: trace-query.sh {get_task_trace|get_trace_waterfall|recent_failures} ..." >&2; exit 2 ;;
esac
```

Each `_*` function is a `python3 - <<'PYEOF'` heredoc that does the file scanning + JSON emission. Same pattern as `bin/orch-metrics.sh` rollup. **No new dependencies beyond python3 stdlib.**

---

## Edge cases — MUST handle

1. **Task exists in `tasks.jsonl` but no `.status.json`** (mid-flight or crashed dispatcher) → `get_task_trace` returns `status: null, events: [...]`, still `found: true`.
2. **`.status.json` exists but no events in `tasks.jsonl`** (rare; replay scenarios) → return status, `events: []`.
3. **Malformed `tasks.jsonl` line** → skip that line, continue. Never crash.
4. **Trace with 0 agent lanes** (task completed without dispatching) → `lanes: []`, `max_concurrent_agents: 0`, `speedup: 1.0`.
5. **Reflexion blob with missing `iteration` field** → skip, do not crash. Counter does not advance.
6. **`since` filter that rejects everything** → `failures: []`, `scanned: N`, exit 0.
7. **`limit > 100`** → silently clamp to 100 and add `"limit_clamped": true` to the output.
8. **`trace_id` or `task_id` contains shell-unsafe chars** — MCP handler passes as single arg; helper treats as literal string (never eval, never interpolate into shell commands).

---

## Acceptance criteria

- [ ] Three MCP tools registered in `server.mjs` with correct `inputSchema`. `orch-notify` restart picks them up.
- [ ] `lib/trace-query.sh get_task_trace <id>` emits JSON matching spec for a seeded fixture task.
- [ ] `lib/trace-query.sh get_trace_waterfall <tid>` emits waterfall with correct `max_concurrent_agents` on a fixture that has 2 overlapping lanes.
- [ ] `lib/trace-query.sh recent_failures` returns failures sorted by `completed_at` desc, respects `--limit` and `--since`.
- [ ] All edge cases above covered by `bin/test-trace-query.sh`. Minimum **20 test assertions**.
- [ ] Runtime < 1s for 1000 events + 100 status files (in-process python aggregation).
- [ ] No regression: existing `orch-notify` tools (`check_inbox` / `check_batch_status` / `list_batches` / `quick_metrics` / `get_project_health` / `check_escalations`) still work identically — grep the pre-existing handlers and confirm no shared state touched.
- [ ] Fixtures under `test-fixtures/trace/`, isolated from real `.orchestration/`. Tests set `TRACE_LOG_DIR` / `TRACE_RESULTS_DIR` env vars to point at fixture dir; helper reads from env (default `.orchestration`).

---

## Commit message template

```
Phase 8.3: orch-notify trace viewer — 3 new MCP tools

Adds get_task_trace, get_trace_waterfall, recent_failures to orch-notify MCP.
Claude can now inspect per-task execution detail without shelling out —
structured JSON over .status.json (8.1) + tasks.jsonl + reflexion blobs
+ audit hints.

Thin MCP handler delegates to lib/trace-query.sh for all logic — same
pattern as check_batch_status. No new deps beyond python3 stdlib. 20+
tests in bin/test-trace-query.sh cover all edge cases (mid-flight tasks,
malformed lines, 0-lane traces, clamped limits).

No regression in existing orch-notify tools.
```

---

## Open icebox (not this phase)

- **8.4 — Token budget dashboard** in `orch-dashboard.sh` using `recent_failures` + `rollup` as data sources.
- **Push-based trace delivery** (webhook / SSE stream) — wait for real demand.
- **Trace DAG visualization** — needs 8.4 dashboard to land first.
- **Retention/compaction policy** for `tasks.jsonl` — separate ops concern.
