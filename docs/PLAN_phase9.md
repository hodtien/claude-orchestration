# Phase 9 — Advanced Patterns: Analysis & Roadmap

**Date:** 2026-04-24
**Context:** Phase 6-8 complete. Orchestration stack is production-quality for dispatch, consensus, observability. 8,094 lines across bin/lib/mcp, 7 test suites (136 total tests), 10 MCP tools.

---

## Current State Audit

### Actively wired in dispatch pipeline (healthy)

| Lib | Lines | Status | Wired in |
|---|---|---|---|
| `lib/triage-tiers.sh` | sourced | ✅ Active | task-dispatch.sh |
| `lib/intent-verifier.sh` | 184 | ✅ Active | task-dispatch.sh |
| `lib/cost-tracker.sh` | 215 | ✅ Active | task-dispatch.sh |
| `lib/agent-failover.sh` | sourced | ✅ Active | task-dispatch.sh |
| `lib/quality-gate.sh` | sourced | ✅ Active | task-dispatch.sh |
| `lib/context-compressor.sh` | sourced | ✅ Active | task-dispatch.sh |
| `lib/consensus-vote.sh` | sourced | ✅ Active | task-dispatch.sh |
| `lib/task-status.sh` | sourced | ✅ Active | task-dispatch.sh |
| `lib/trace-query.sh` | 393 | ✅ Active | orch-notify MCP |
| `bin/task-selfheal.sh` | 302 | ✅ Active | task-dispatch.sh (failure path) |
| `bin/task-fork.sh` | 359 | ✅ Wired | task-dispatch.sh (fork_mode=auto) |

### Dormant scaffolds (code exists, NOT wired into dispatch)

| Lib | Lines | Functions | Wired? | Value assessment |
|---|---|---|---|---|
| `lib/task-decomposer.sh` | 344 | `decompose_task`, `generate_pipeline_graph` | ❌ Only in `bin/deprecated/decompose.sh` | **HIGH** — auto-decomposition of large specs into 15-min units |
| `lib/learning-engine.sh` | 259 | `learn_from_outcome`, `update_routing_for_success`, `get_agent_recommendation` | ❌ Not wired | **HIGH** — closes the feedback loop: outcome → routing improvement |
| `lib/cross-project.sh` | 202 | `extract_pattern`, `import_pattern`, `suggest_patterns` | ❌ Not wired | **MEDIUM** — useful only when multiple orchestrated projects exist |
| `lib/speculation-buffer.sh` | 108 | shared state speculation | ❌ Not wired | **LOW** — premature without multi-agent concurrency on shared files |
| `lib/dag-healer.sh` | sourced | DAG self-heal | ⚠️ Wired via task-selfheal.sh | Active but limited scope |

### Test coverage gap

| Area | Tests | Gap |
|---|---|---|
| Dispatch core (consensus/first_success) | 11+11 | ✅ Good |
| Compressor | 3 (informal) | ⚠️ Could use structured suite |
| Task status | 5 | ✅ OK |
| Metrics rollup | 27 | ✅ Excellent |
| Trace query | 36 | ✅ Excellent |
| Budget dashboard | 45 | ✅ Excellent |
| **task-decomposer** | 0 | ❌ Untested |
| **learning-engine** | 0 | ❌ Untested |
| **cross-project** | 0 | ❌ Untested |
| **agent.sh** | 0 | ❌ No unit tests for agent wrapper |

---

## Original Phase 9 Items — Re-evaluation

| Original item | Assessment | Verdict |
|---|---|---|
| **9.1** Multi-turn orchestration sessions | Core value: agents that remember context across turns within a batch. Currently each `agent.sh` call is stateless. Real multi-turn needs a session file per agent or a context-pipe chain. | **REFRAME → 9.1 Session context chains** |
| **9.2** Gibberlink/agent-to-agent protocol | Original idea: agents talk directly to each other. In practice, dispatch already chains via `depends_on` + `context_from` + `.out` files. A formal protocol adds complexity without clear ROI. | **DEFER or DROP** — existing DAG + depends_on covers 90% |
| **9.3** Cross-project orchestration | `lib/cross-project.sh` exists (202 lines) but not wired. Value is real only when running orchestration across multiple repos. | **DEFER** — wire when second project adopts orchestration |
| **9.4** ReAct pattern for orchestration | Observe → Think → Act loop. Currently dispatch is fire-and-forget. ReAct would let the dispatcher observe intermediate output, decide next action, loop. Related to learning-engine. | **REFRAME → 9.3 Adaptive dispatch (ReAct + learning loop)** |

---

## Revised Phase 9 Roadmap

Based on the audit: prioritize **wiring dormant high-value scaffolds** and **closing the feedback loop** over new greenfield patterns. The biggest unlocks are:

1. **Auto-decomposition** — LLM-assisted task breakdown before dispatch (task-decomposer.sh is 344 lines of scaffold)
2. **Learning loop** — batch outcomes improve routing decisions (learning-engine.sh is 259 lines of scaffold)
3. **Session context** — agents can build on prior turns within a pipeline (currently stateless)

### Phase 9.1 — Task auto-decomposition (P1)

**Goal:** When a task spec is complex (>80 lines or complexity estimate >500 tokens), automatically decompose it into 15-min executable units with dependency graph, then dispatch as a sub-batch.

**What exists:** `lib/task-decomposer.sh` (344 lines) — `decompose_task()`, `generate_pipeline_graph()`, `generate_parallel_graph()`, `analyze_intent()`, `generate_spec()`. All implemented but not wired.

**Work needed:**
- Wire `decompose_task()` into `task-dispatch.sh` pre-dispatch phase (after spec parse, before agent call)
- Add config flag `auto_decompose: true|false` in `batch.conf`
- Threshold: decompose when spec body > 80 lines OR `complexity:` frontmatter > 500
- Sub-batch output dir: `.orchestration/tasks/<batch-id>/<task-id>-units/`
- Test suite: `bin/test-task-decomposer.sh` (15+ tests)
- MCP tool: `decompose_preview(task_spec)` → returns proposed units without executing

**Deliverables:**
- `bin/test-task-decomposer.sh` — test suite for decompose_task()
- Wire into dispatch pipeline (3-5 lines in task-dispatch.sh)
- `config/batch.conf` defaults update
- MCP tool `decompose_preview` in orch-notify

### Phase 9.2 — Learning loop (P1)

**Goal:** After each batch completes, analyze outcomes and update routing/model preferences automatically. Close the feedback loop: dispatch → execute → observe → learn → better dispatch.

**What exists:** `lib/learning-engine.sh` (259 lines) — `learn_from_outcome()`, `update_routing_for_success()`, `get_agent_recommendation()`, `analyze_batch()`. All implemented but not wired.

**Work needed:**
- Wire `learn_from_outcome()` into dispatch success/failure paths (after `write_task_status()`)
- Wire `analyze_batch()` into batch completion handler (after inbox notification)
- Store learnings in `.orchestration/learnings.jsonl` (already defined in learning-engine.sh)
- Add `get_routing_advice(task_type)` MCP tool — returns model recommendation based on historical data
- Reporting: `orch-dashboard.sh learn` subcommand showing win rates per model × task_type
- Test suite: `bin/test-learning-engine.sh` (15+ tests)

**Deliverables:**
- `bin/test-learning-engine.sh` — test suite
- Wire into dispatch pipeline (2 call sites: success path + failure path)
- MCP tool `get_routing_advice` in orch-notify
- Dashboard subcommand `orch-dashboard.sh learn`

### Phase 9.3 — Adaptive dispatch / ReAct (P2)

**Goal:** For long-running or uncertain tasks, the dispatcher can observe intermediate output from an agent, decide whether to continue / redirect / abort, and loop. This is the ReAct (Reason + Act) pattern applied to orchestration.

**What exists:** The reflexion loop in consensus (Phase 7.1d) is a limited version — it retries with peer output. Full ReAct would:
- After agent returns partial output, evaluate quality
- Decide: accept / refine prompt / switch model / abort
- Loop up to N times with progressively refined context

**Work needed:**
- `lib/react-loop.sh` — new, ~200 lines
- Hook into `dispatch_task_first_success()` as optional wrapper
- Config: `react_mode: true|false`, `react_max_turns: 3`, `react_quality_threshold: 0.7`
- Quality evaluation via `quality-gate.sh` (already wired) or lightweight heuristic
- Test suite: `bin/test-react-loop.sh` (10+ tests)
- MCP tool: `get_react_trace(task_id)` — shows the observe/think/act chain for a task

### Phase 9.4 — Session context chains (P2)

**Goal:** When tasks in a pipeline (`depends_on`) share a theme, carry forward a compressed session context so later agents have richer understanding of the work done by earlier agents.

**What exists:**
- `depends_on` resolution in task-dispatch.sh (reads prior `.out` files)
- `context-compressor.sh` (compress prior output)
- `CONTEXT_FILE` env var in agent.sh (pipe prior output to next agent)

**Gap:** Currently `depends_on` appends raw `.out` to the prompt. For long chains, this bloats context. Need:
- Summarize prior chain output into a "session brief" (~500 tokens max)
- Carry `session_context.json` alongside the task pipeline
- Agent.sh reads session context as preamble before the task prompt

**Work needed:**
- `lib/session-context.sh` — new, ~100 lines (build_session_brief, load_session_context)
- Wire into dispatch pipeline at `depends_on` resolution phase
- Compress using `context-compressor.sh` (already has `compress_summary()`)
- Test suite: `bin/test-session-context.sh` (10+ tests)

---

## Phase 9 Priority Order

| Sub-phase | Priority | Dependencies | Estimated effort | Dispatch-able? |
|---|---|---|---|---|
| **9.1** Task decomposition | P1 | None | 1 day | ✅ Yes — 2 task specs |
| **9.2** Learning loop | P1 | 9.1 soft (better with decomp data) | 1 day | ✅ Yes — 2 task specs |
| **9.3** ReAct adaptive | P2 | 9.2 (needs quality signal) | 1-2 days | ✅ Yes — 2 task specs |
| **9.4** Session context | P2 | None | 0.5 day | ✅ Yes — 1 task spec |

**Total: ~4 days of work, all dispatch-able via batch orchestration.**

### Dispatch strategy

Each sub-phase decomposes into 2 tasks (core + tests), following the Phase 8.4 pattern:

```
.orchestration/tasks/phase-9.1/
  task-decomposer-wire.md    # agent: gemini-fast, reviewer: copilot
  task-decomposer-test.md    # agent: copilot, depends_on: [decomposer-wire-001]

.orchestration/tasks/phase-9.2/
  task-learning-wire.md
  task-learning-test.md      # depends_on: [learning-wire-001]

.orchestration/tasks/phase-9.3/
  task-react-core.md
  task-react-test.md         # depends_on: [react-core-001]

.orchestration/tasks/phase-9.4/
  task-session-ctx.md
  task-session-ctx-test.md   # depends_on: [session-ctx-001]
```

Can run 9.1 + 9.4 in parallel (no dependency), then 9.2, then 9.3.

---

## Success Criteria for Phase 9

- [ ] `decompose_task()` auto-splits specs >80 lines into unit sub-batches
- [ ] `learn_from_outcome()` fires on every dispatch completion, learnings queryable via MCP
- [ ] All 4 dormant libs have test suites (task-decomposer, learning-engine, react-loop, session-context)
- [ ] `orch-dashboard.sh learn` shows model × task_type win rates
- [ ] Phase 9 adds 60+ new tests to the suite (current: 136 → target: 196+)
- [ ] No regression in existing dispatch pipeline or MCP tools
- [ ] Each sub-phase can be dispatched via `task-dispatch.sh --parallel` (self-referential: the orchestration system builds itself)

---

## What we're NOT doing in Phase 9

- **Gibberlink / agent-to-agent protocol** — existing `depends_on` + `.out` chain is sufficient. Formal protocol is over-engineering for current scale.
- **Cross-project orchestration** — wire when a second project adopts the system.
- **Speculation buffer** — premature without concurrent file-editing agents.
- **Budget enforcement** (block dispatch when over budget) — config flag only, not active blocking.
- **Dollar-cost calculations** — no pricing API yet.
