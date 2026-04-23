# Orchestration Roadmap — Phase 6–9

> Based on Phase 5 completion status + 2025–2026 agentic AI research.
> Maintains existing subagent architecture and model routing in `config/models.yaml`.
> **This is the master reference.** WORK.md holds the active task list.

---

## Research Basis

**Sources:**
- [From Conductor to Orchestrator: A Practical Guide to Multi-Agent Coding in 2026](https://htdocs.dev/posts/from-conductor-to-orchestrator-a-practical-guide-to-multi-agent-coding-in-2026/)
- [Multi-Agent Orchestration Patterns: Pattern Language 2026](https://www.digitalapplied.com/blog/multi-agent-orchestration-patterns-producer-consumer)
- [LLM Cost Optimization in 2026: Routing, Caching, and Batching](https://www.maviklabs.com/blog/llm-cost-optimization-2026)
- [LLMOps Guide 2026: Build Fast, Cost-Effective LLM Apps](https://redis.io/blog/large-language-model-operations-guide/)
- [HiveMind: OS-Inspired Scheduling for Concurrent LLM Agent Workloads](https://arxiv.org/html/2604.17111)
- Wikipedia: Agentic AI — orchestration patterns, 7-layer reference architecture (Ken Huang)
- Industry trends: MCP (done), Gibberlink (emerging), Reflexion, ReAct

**Key gaps identified:**
1. Self-healing (DAG healing + reflexion)
2. Quality governance (consensus + evaluation)
3. Observability (tool registry, trace viewer, token budget)
4. Advanced patterns (multi-turn, agent-to-agent, ReAct)
5. Cleanup (deprecate state-conflict-resolver, move deprecated libs)

---

## Phase 6: Self-Healing & Reflexion (P0)

**Objective:** Close Phase 5 gaps — wire the Drafted libs and add self-correction loop. Foundation for all later phases.

**Why now:** Phase 5 runtime proof confirmed intent-verifier + cost-tracker + failover fire correctly. Time to wire remaining Drafted libs before building new features on top.

### 6.1 Wire dag-healer.sh into task-dispatch.sh (P0) ✅ DONE 2026-04-23
- **Scope:** Source lib, call `heal_dag` when ≥1 task failed in parallel batch, before moving to DLQ
- **Acceptance:** 1 batch with 1 failed task → dag-healer attempts retry with adjusted spec → log entry in `~/.claude/orchestration/dag-heal.jsonl`
- **Implementation:** task-selfheal.sh now sources `lib/dag-healer.sh` at top. Falls back to local stubs if not loaded. main() calls `healer_detect_failure()` + `healer_get_strategy()`, writes to dag-heal.jsonl with MAX_HEAL_ATTEMPTS=3 tracking. Result (retry-modified/skip-dependents/abort) used as primary strategy, local classify_failure as fallback.
- **Rollback:** Revert sourcing block in task-selfheal.sh (2 lines)

### 6.2 Add Reflexion loop for failed agents (P0) ✅ DONE 2026-04-23
- **Scope:** When agent returns fail quality gate, create revision task with feedback from critic agent (gemini review of copilot output or vice versa). Max 2 iterations.
- **Acceptance:** 1 task with fake-bad output ("TODO: implement") → reflexion loop creates revision task with feedback → re-dispatch agent → success or escalate after 2 tries
- **Implementation:** Created `lib/quality-gate.sh` with `check_quality_gate()` (checks: output length >20 chars, no TODO/FIXME alone) + `trigger_reflexion()` (writes to `$ORCH_DIR/reflexions/<tid>.reflexion.json`, max 2 revisions, marks task as needs_revision). Wired into task-dispatch.sh success path after `run_reviewer`. Uses existing `memory-bank: create_revision` API pattern from CLAUDE.md.
- **Rollback:** Remove quality-gate.sh sourcing + quality gate block in task-dispatch.sh (~20 lines)

### 6.3 Wire context-compressor.sh with token budget check (P0) ✅ DONE 2026-04-23
- **Scope:** Before dispatching task with `prior_artifacts > 50k tokens`, call `compress_context`. Record compression ratio in cost-tracking.
- **Acceptance:** Dispatch task with 80k token prior artifacts → compressor fires → task receives <50k tokens → `cost-tracking.jsonl` has `context_compressed: true` and `ratio: 0.6`
- **Trigger gate:** Only activate when `config/models.yaml` has `context_budget_threshold` set (default off)
- **Implementation:** Context compression check added in `dispatch_task()` after context merge block. Fires when `ctx_tokens > CONTEXT_BUDGET_THRESHOLD` (default 50000). Calls `compress_session()` from context-compressor.sh. Resulting compressed prompt replaces ctx_block. Compression ratio logged to dispatch output.
- **Rollback:** Remove context-compressor.sh sourcing + compression check block (~25 lines)

### 6.4 Deprecate state-conflict-resolver.sh (P1) ✅ DONE 2026-04-23
- **Scope:** `git mv lib/state-conflict-resolver.sh lib/deprecated/`, update `docs/archive/LIB_AUDIT_2026-04-22.md` reference
- **Acceptance:** File moved, `grep -r` finds no active caller
- **Implementation:** Moved to `lib/deprecated/state-conflict-resolver.sh`. grep confirmed no active callers. docs/archive/LIB_AUDIT_2026-04-22.md and docs/archive/PHASE5_IDEAS_2026-04-23.md updated with DEPRECATED status.
- **Quick win:** ~5 minutes

**Phase 6 Success Criteria:** 3 Drafted libs wired or deprecated. 1 reflexion demo pass. No more "Drafted, not wired" in PHASE5_IDEAS.md.

---

## Phase 7: Consensus & Evaluation (P1)

**Objective:** Add planner-critic pattern and eval-first workflow. Switch from `first_success` to quality-governed parallel dispatch.

**Why:** Currently `parallel_policy.pick_strategy: first_success` — not leveraging multiple models in parallel. Consensus + eval-harness turns race into quality gate.

### 7.1 Wire consensus-vote.sh + switch pick_strategy (P1)
- **Scope:** Implement real consensus logic: if ≥2 models return output, call `consensus_vote` (semantic similarity via gemini-low + majority), return merged result. Add task_type `design_api` + `architecture_analysis` to consensus list.
- **Acceptance:** Dispatch task `design_api` with parallel=[gemini-pro, cc/claude-sonnet-4-6] → both return → consensus-vote selects/merges → output has `consensus_score: 0.85`
- **Config flag:** `parallel_policy.pick_strategy: consensus` in models.yaml

### 7.2 Build eval-harness.sh (P1)
- **Scope:** CLI to run golden-set eval for 1 task_type. Input: `.orchestration/evals/<task_type>/*.yaml` (each with `input`, `expected_properties`, no exact match needed). Output: per-model pass rate, avg cost, avg latency.
- **Acceptance:** `eval-harness.sh code_review` runs 5 golden cases → report table: `gemini-medium 4/5 pass, $0.02, 12s avg | gh/gpt-5.3-codex 5/5, $0.05, 18s avg` → writes to `.orchestration/evals/results/<date>.json`
- **Use case:** Before wiring new model into models.yaml, run eval-harness to verify quality

### 7.3 Add quality gates in task-dispatch output phase (P1)
- **Scope:** After agent returns, run basic assertions: output length >20 chars, no "TODO/FIXME alone", JSON valid if task_type requires. Fail → revision loop (with 6.2).
- **Acceptance:** Task with output "TODO: fix later" fails gate → trigger revision (6.2) → retry with critic feedback
- **Cheap:** Use local regex + jq, no LLM call

**Phase 7 Success Criteria:** consensus-vote active for ≥2 task_types. eval-harness runs for `code_review` and `implement_feature`. Quality gates catch ≥1 bad output in integration test.

---

## Phase 8: Tool Registry & Observability (P1)

**Objective:** Close research finding #2 (7-layer: eval/observability layer) and #4 (tool registry). Enable Claude PM to see the whole system vs. grepping logs.

**Why:** After consensus + eval, need observability to tune. Currently `orch-dashboard.sh` only covers cost — missing quality/latency/trace.

### 8.1 Central tool-registry.yaml (P1)
- **Scope:** Single source of truth for **tools** (not models). List: MCP servers available, shell tools (gemini, copilot, curl, jq), skill files. Each entry has `auth_env`, `health_check_cmd`, `capabilities[]`.
- **Acceptance:** `bin/tool-check.sh` reads registry → verifies each tool reachable → reports green/red table. Ready for agent dynamic tool selection in Phase 9.
- **Related:** Merge with `config/agents.json` or keep separate? → propose keep separate: models.yaml (which to call), tool-registry.yaml (which connectors exist), agents.json (cost/tier lookup)

### 8.2 Execution trace viewer via orch-notify MCP (P1)
- **Scope:** Extend `orch-notify` MCP with tool `get_trace(task_id)` returning: timeline events (verify → dispatch → agent call → cost record → completion), timestamps + duration per stage. Format: chronological JSON.
- **Acceptance:** `get_trace("smoke-t1")` → 8-12 events with durations. Trace visible in Claude Code MCP inspector.
- **Hint:** Data already exists in `cost-tracking.jsonl` + `verification-logs/` + `failover.jsonl` — just needs aggregator.

### 8.3 Token budget dashboard in orch-dashboard.sh (P1)
- **Scope:** Add subcommand `orch-dashboard.sh budget` — show spent_today/limit_today per model, burn rate trend 7 days, near-limit warnings.
- **Acceptance:** `orch-dashboard.sh budget` outputs: `minimax-code: $0.43/$5 (9%) 🟢 | gemini-pro: $2.10/$3 (70%) 🟡 | cc/claude-opus: $0/$10 (0%) ⚪`. Warning when >75%.
- **Config:** Budget limits in `config/models.yaml` → `budget.daily_usd_per_model`

**Phase 8 Success Criteria:** Tool registry has ≥8 entries health-checked. Trace viewer returns full timeline for any task_id. Budget dashboard catches model near limit before throttle.

---

## Phase 9: Advanced Patterns (P2, trigger-based)

**Objective:** Optional features — only do when there is real need. Based on research finding #3 (protocols) and #5 (real-world maturity).

**Trigger rule:** Only pick 1 task from Phase 9 when usage data proves the need. Default: skip if Phase 6-8 are sufficient.

### 9.1 Multi-turn orchestration sessions (P2)
- **Trigger:** When ≥3 use cases require manual task chaining
- **Scope:** Allow 1 batch to have multiple "rounds" — round 1 design, round 2 implement based on round 1 output, round 3 test. Use DAG deps in task spec (field `depends_on` already exists).
- **Acceptance:** Batch spec with 3 tasks and depends_on chain → dispatch auto-orders correctly → round 2 receives round 1 output as prior_artifact

### 9.2 Gibberlink/agent-to-agent protocol stub (P2)
- **Trigger:** When need for agent to share context without PM orchestrator
- **Scope:** Research spike — read Gibberlink spec, write 1-2 page POC `docs/DESIGN_AGENT_PROTOCOL.md` with: use case for solo-dev, vs alternatives (is MCP enough?), effort estimate. Decide "adopt/defer/skip" with rationale.
- **Anti-pattern warning:** Easy to over-engineer for solo-dev. Default skip.

### 9.3 Cross-project orchestration (P2)
- **Trigger:** When using orchestration for ≥2 projects
- **Scope:** Allow `task-dispatch.sh` to run from any project directory, auto-detect or create `.orchestration/`. Memory-bank shared across projects via symlink or central store.
- **Acceptance:** `cd ~/other-project && task-dispatch.sh .orchestration/tasks/batch-x/` works end-to-end

### 9.4 ReAct pattern for orchestration agents (P2)
- **Trigger:** When gemini-pro output for BA/arch tasks has uneven quality
- **Scope:** Replace one-shot prompt with ReAct loop: Thought → Action → Observation → Thought. Apply to `analyze_requirements` and `architecture_analysis` task types.
- **Acceptance:** Task `analyze_requirements` with ReAct prompt has ≥3 Thought-Action cycles in output → quality 20% higher than baseline (measured via eval-harness 7.2)
- **Dependency:** Needs eval-harness from 7.2 to measure improvement

**Phase 9 Success Criteria:** Not required to implement. Design doc for each task is sufficient. Implement only when trigger is real.

---

## Deferred (trigger-based, not timeline-based)

### D.1 Move 9 deprecated libs → lib/deprecated/
Cleanup cosmetic, 1 month after Phase 6 stable.

### D.2 setup-router.sh apply
When ready to switch Claude Code to 9router officially.

---

## Priority Summary

| Phase | Priority | Tasks | Estimated effort |
|-------|----------|-------|------------------|
| Phase 6 | P0 | 6.1, 6.2, 6.3, 6.4 | 1–1.5 weeks |
| Phase 7 | P1 | 7.1, 7.2, 7.3 | 1–2 weeks |
| Phase 8 | P1 | 8.1, 8.2, 8.3 | 1 week |
| Phase 9 | P2 | 9.1, 9.2, 9.3, 9.4 | On-demand, skip OK |

**Execution order:** Phase 6 → 7 → 8 → 9.
- Reason: 7 needs eval-harness to wire consensus confidently
- 8 needs data from 7 to show trace/budget
- 9 needs eval-harness (7.2) to measure ReAct improvement

**Rollback plan:** Each P0/P1 task has rollback ≤5 lines. Keep fallback flags in `config/models.yaml` to disable feature when needed.

---

## Related Documents

- `CLAUDE.md` — system instructions
- `PHASE5_IDEAS.md` — Phase 5 implementation details
- `TASK_ROUTING.md` — task routing reference
- `config/models.yaml` — model routing (do not change task_type → model mappings)
- `WORK.md` — active task list (paste into ## Active, pin Phase 6 only)
