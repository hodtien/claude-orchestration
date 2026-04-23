# Work Log — Claude Orchestration

> Single source of truth for active work. Work-in-progress, icebox ideas, and completed task log.
> Inspired by the pattern: no new MD files for WIP (use this file instead).

---

## Active

**Phase 6: Self-Healing & Reflexion (P0)**
- [x] `6.1` Wire `lib/dag-healer.sh` into `bin/task-dispatch.sh` (P0)
  - **Scope:** Source lib, call `heal_dag` when ≥1 task failed in parallel batch, before moving to DLQ
  - **Acceptance:** 1 batch with 1 failed task → dag-healer attempts retry with adjusted spec → log entry in `~/.claude/orchestration/dag-heal.jsonl`
  - **Rollback:** Revert source line + `heal_dag` call (2 lines)
  - ✅ DONE 2026-04-23: task-selfheal.sh now sources dag-healer.sh + calls healer_detect_failure() + healer_get_strategy(), logs to dag-heal.jsonl with MAX_HEAL_ATTEMPTS tracking

- [x] `6.2` Add Reflexion loop for failed agent output (P0)
  - **Scope:** When agent returns fail quality gate, create revision task with feedback from critic agent. Max 2 iterations.
  - **Acceptance:** 1 task with fake-bad output ("TODO: implement") → reflexion loop creates revision task with feedback → re-dispatch → success or escalate after 2 tries
  - **Implementation:** Use existing `memory-bank: create_revision` API (from CLAUDE.md line ~53)
  - ✅ DONE 2026-04-23: Created `lib/quality-gate.sh` with `check_quality_gate()` + `trigger_reflexion()`, wired into task-dispatch.sh success path

- [x] `6.3` Wire `lib/context-compressor.sh` into task-dispatch with token budget check (P0)
  - **Scope:** Before dispatching task with `prior_artifacts > 50k tokens`, call `compress_context`. Record compression ratio in cost-tracking.
  - **Acceptance:** Dispatch task with 80k token prior artifacts → compressor fires → task receives <50k tokens → `cost-tracking.jsonl` has `context_compressed: true` and `ratio: 0.6`
  - **Trigger gate:** Only activate when `config/models.yaml` has `context_budget_threshold` set (default off)
  - ✅ DONE 2026-04-23: Context compression check wired in dispatch_task() — fires when ctx_tokens > CONTEXT_BUDGET_THRESHOLD (default 50000), compress_session from context-compressor.sh called, ratio logged

- [x] `6.4` Deprecate `lib/state-conflict-resolver.sh` → `lib/deprecated/` (P1)
  - **Scope:** `git mv lib/state-conflict-resolver.sh lib/deprecated/`, update `docs/archive/LIB_AUDIT_2026-04-22.md` reference
  - **Acceptance:** File moved, `grep -r` finds no active caller
  - **Quick win:** ~5 minutes
  - ✅ DONE 2026-04-23: Moved to `lib/deprecated/state-conflict-resolver.sh`, docs updated

**Phase 6 Success Criteria:** 3 Drafted libs wired or deprecated. 1 reflexion demo pass. No more "Drafted, not wired" in PHASE5_IDEAS.md.

---

## Roadmap (next up)

**Phase 7: Consensus & Evaluation Harness (P1)** — see `docs/DESIGN_PHASE_7.md` if expanded
- [ ] `7.1` Wire `lib/consensus-vote.sh` + switch `pick_strategy` to `consensus` (P1)
  - **Scope:** Implement real consensus logic: if ≥2 models return output, call `consensus_vote` (semantic similarity via gemini-low + majority), return merged result
  - **Acceptance:** Dispatch `design_api` task with parallel=[gemini-pro, cc/claude-sonnet-4-6] → both return → consensus-vote selects/merges → output has `consensus_score: 0.85`
  - **Config flag:** `parallel_policy.pick_strategy: consensus` in models.yaml

- [ ] `7.2` Build `bin/eval-harness.sh` (P1)
  - **Scope:** CLI to run golden-set eval for 1 task_type. Input: `.orchestration/evals/<task_type>/*.yaml` (each with `input`, `expected_properties`). Output: per-model pass rate, avg cost, avg latency
  - **Acceptance:** `eval-harness.sh code_review` runs 5 golden cases → report table → writes to `.orchestration/evals/results/<date>.json`
  - **Use case:** Before wiring new model into models.yaml, run eval-harness to verify quality

- [ ] `7.3` Add quality gates in task-dispatch output phase (P1)
  - **Scope:** After agent returns, run basic assertions: output length >20 chars, no "TODO/FIXME alone", JSON valid if task_type requires. Fail → revision loop (with 6.2)
  - **Acceptance:** Task with output "TODO: fix later" fails gate → trigger revision (6.2) → retry with critic feedback
  - **Cheap:** Use local regex + jq, no LLM call

**Phase 7 Success Criteria:** consensus-vote active for ≥2 task_types. eval-harness runs for `code_review` and `implement_feature`. Quality gates catch ≥1 bad output in integration test.

---

**Phase 8: Tool Registry & Observability (P1)**
- [ ] `8.1` Central `config/tool-registry.yaml` (P1)
  - **Scope:** Single source of truth for tools (not models). List: MCP servers, shell tools (gemini, copilot, curl, jq), skill files. Each entry has `auth_env`, `health_check_cmd`, `capabilities[]`
  - **Acceptance:** `bin/tool-check.sh` reads registry → verifies each tool reachable → reports green/red
  - **Note:** Keep separate from models.yaml (which to call) and agents.json (cost/tier lookup)

- [ ] `8.2` Execution trace viewer via orch-notify MCP (P1)
  - **Scope:** Extend `orch-notify` MCP with tool `get_trace(task_id)` returning: timeline events (verify → dispatch → agent call → cost record → completion), timestamps + duration per stage
  - **Acceptance:** `get_trace("smoke-t1")` → 8-12 events with durations. Trace visible in Claude Code MCP inspector
  - **Hint:** Data already exists in `cost-tracking.jsonl` + `verification-logs/` + `failover.jsonl` — just needs aggregator

- [ ] `8.3` Token budget dashboard in orch-dashboard.sh (P1)
  - **Scope:** Add subcommand `orch-dashboard.sh budget` — show spent_today/limit_today per model, burn rate trend 7 days, near-limit warnings
  - **Acceptance:** `orch-dashboard.sh budget` outputs: `minimax-code: $0.43/$5 (9%) 🟢 | gemini-pro: $2.10/$3 (70%) 🟡`. Warning when >75%
  - **Config:** Budget limits in `config/models.yaml` → `budget.daily_usd_per_model`

**Phase 8 Success Criteria:** Tool registry has ≥8 entries health-checked. Trace viewer returns full timeline for any task_id. Budget dashboard catches model near limit before throttle.

---

**Phase 9: Advanced Patterns (P2, trigger-based)**
- [ ] `9.1` Multi-turn orchestration sessions (P2)
  - **Trigger:** When ≥3 use cases require manual task chaining
  - **Scope:** Allow 1 batch to have multiple "rounds" — round 1 design, round 2 implement based on round 1 output, round 3 test. Use DAG deps in task spec (field `depends_on` already exists)

- [ ] `9.2` Gibberlink/agent-to-agent protocol stub (P2)
  - **Trigger:** When need for agent sharing context without PM orchestrator
  - **Scope:** Research spike — read Gibberlink spec, write 1-page POC `docs/DESIGN_AGENT_PROTOCOL.md` with use case, vs alternatives, effort estimate. Default skip for solo-dev.

- [ ] `9.3` Cross-project orchestration (P2)
  - **Trigger:** When using orchestration for ≥2 projects
  - **Scope:** Allow `task-dispatch.sh` to run from any project directory, auto-detect or create `.orchestration/`

- [ ] `9.4` ReAct pattern for orchestration agents (P2)
  - **Trigger:** When gemini-pro output for BA/arch tasks has uneven quality
  - **Scope:** Replace one-shot prompt with ReAct loop: Thought → Action → Observation → Thought. Apply to `analyze_requirements` and `architecture_analysis` task types
  - **Dependency:** Needs eval-harness from 7.2 to measure improvement

**Phase 9 Success Criteria:** Not required to implement. Design doc for each task is sufficient. Implement only when trigger is real.

---

## Icebox

- [ ] Wire consensus-vote.sh (trigger: `parallel_policy.pick_strategy: consensus` enabled in models.yaml)
- [ ] Wire dag-healer.sh (trigger: task-dispatch DAG execution is stable enough to self-check)
- [ ] Wire context-compressor.sh (trigger: context budget becomes a problem in real usage)
- [ ] **Deprecate state-conflict-resolver.sh** (speculation-layer feature, # TODO in code confirms incomplete, no active callers, belongs in lib/deprecated/)
- [ ] Move 9 deprecated libs to lib/deprecated/ (low priority, do after 1 month of usage)

---

## Deferred (trigger-based, not timeline-based)

- [ ] `D.1` Move 9 deprecated libs → `lib/deprecated/` (cleanup cosmetic, 1 month after Phase 6 stable)
- [ ] `D.2` `setup-router.sh apply` to `~/.claude/settings.json` (when ready to switch Claude Code to 9router officially)

---

## Priority Summary

| Phase | Priority | Tasks | Estimated effort |
|-------|----------|-------|------------------|
| Phase 6 | P0 | 6.1, 6.2, 6.3, 6.4 | 1–1.5 weeks |
| Phase 7 | P1 | 7.1, 7.2, 7.3 | 1–2 weeks |
| Phase 8 | P1 | 8.1, 8.2, 8.3 | 1 week |
| Phase 9 | P2 | 9.1, 9.2, 9.3, 9.4 | On-demand, skip OK |

**Execution order:** Phase 6 → 7 → 8 → 9. Reason: 7 needs eval-harness to wire consensus confidently; 8 needs data from 7 to show trace/budget; 9 needs eval-harness (7.2) to measure ReAct improvement.

**Rollback plan:** Each P0/P1 task has rollback ≤5 lines. Keep fallback flags in `config/models.yaml` to disable feature when needed.

---

## Archive

| Date | What | Where |
|------|------|-------|
| 2026-04-23 | Phase 6-9 roadmap v2 — with acceptance criteria (from Claude app) | WORK.md + docs/ORCHESTRATION_ROADMAP.md |
| 2026-04-23 | Phase 6.4 done: deprecate state-conflict-resolver.sh → lib/deprecated/ | lib/deprecated/state-conflict-resolver.sh + docs/archive/ |
| 2026-04-23 | Phase 6 COMPLETE: 6.1 dag-healer wire, 6.2 reflexion loop, 6.3 context-compressor, 6.4 deprecate state-conflict-resolver | bin/task-dispatch.sh + bin/task-selfheal.sh + lib/quality-gate.sh + lib/deprecated/ |
| 2026-04-23 | Phase 6-9 roadmap research + plan (agentic AI 2025-2026) | docs/ORCHESTRATION_ROADMAP.md |
| 2026-04-23 | Phase 5 wiring audit + add verify tasks to Active | PHASE5_IDEAS.md + WORK.md |
| 2026-04-23 | Smoke test refactor — PASSED. Found + fixed bash 3.2 incompat in triage-tiers/consensus-vote | commit 17cca11 |
| 2026-04-23 | Verify wiring: agent-failover + cost-tracker + intent-verifier (all confirmed at line-level) | PHASE5_IDEAS.md updated |
| 2026-04-23 | Runtime proof: intent-verifier, cost-tracker, task-dispatch --parallel all confirmed | commit 7ebf500 |
| 2026-04-23 | Route_task MCP round-trip test via 9router | mcp-server/9router-agent.mjs |
| 2026-04-23 | Add minimax-code as backup fallback to all task types | config/models.yaml |
