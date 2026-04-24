# Work Log — Claude Orchestration

> Single source of truth for active work. Work-in-progress, icebox ideas, and completed task log.
> Inspired by the pattern: no new MD files for WIP (use this file instead).

---

## Active

**Phase 7: Consensus & Evaluation Harness (P1)**

Phase 7 order: **7.2 first → 7.1 second** (eval-harness needed to measure consensus quality)

- [x] `7.2` Build `bin/eval-harness.sh` (P1) ✅ DONE 2026-04-23
  - **Scope:** CLI to run golden-set eval for 1 task_type. Input: `.orchestration/evals/<task_type>/*.yaml`. Output: per-model pass rate, avg cost, avg latency
  - **Acceptance:** `eval-harness.sh code_review` runs golden cases → report table → writes to `.orchestration/evals/results/<date>.json`
  - ✅ DONE: `bin/eval-harness.sh` (439 lines), 2 golden cases (unused_variable.yaml, fizzbuzz.yaml), subcommands: list, results, --model filter, --verbose

- [ ] `7.1` Wire `lib/consensus-vote.sh` + switch `pick_strategy` to `consensus` (P1)
  - **Scope:** Implement real consensus logic: if ≥2 models return output, call `consensus_vote` (semantic similarity via gemini-low + majority), return merged result
  - **Acceptance:** Dispatch `design_api` task with parallel=[gemini-pro, cc/claude-sonnet-4-6] → both return → consensus-vote selects/merges → output has `consensus_score: 0.85`
  - **Config flag:** `parallel_policy.pick_strategy: consensus` in models.yaml
  - **Note:** Consensus fail → reflexion retry (Bug #3 deferred — resolve together)
  - **7.1a DONE** (2026-04-24): All scaffold done. 4 layers: bash 3.2 stubs, real-model keys, no subshell leak, source guard. 6 tests PASS on bash 4+.
  - **7.1d DONE** (2026-04-24): reflexion loop on consensus failure. Externalized sim_threshold to models.yaml (0.3). On consensus fail (no survivors OR score=0 with 2+ candidates): trigger reflexion + re-dispatch with peer-output enriched prompt. Max 2 iterations. Exhausted marker + consensus_exhausted strategy. 11 unit tests PASS, 9 dispatch tests PASS. All Phase 7.1 subtasks CLOSED.

- [x] `7.3` Add quality gates in task-dispatch output phase (P1) ✅ DONE 2026-04-24
  - ✅ DONE: `lib/quality-gate.sh` wired into task-dispatch.sh success path after `run_reviewer`. See Phase 6.2.
  - ✅ 2026-04-24: `bin/test-compressor.sh` added (150 lines) — confirms compress_summary() ratios 0.301/0.500/0.700 match target levels on real 57KB payload. Commit `7ce4e22`.

**Phase 7 Success Criteria:** consensus-vote active for architecture_analysis, design_api, security_audit (≥2 task_types ✅). eval-harness runs for code_review and implement_feature ✅. Quality gates in place ✅. Phase 7 COMPLETE.

**Status: MET** — consensus-vote ACTIVE for `architecture_analysis`, `design_api`, `security_audit`. eval-harness running for `code_review` and `implement_feature`. Quality gates in place. All Phase 7.1 subtasks CLOSED.

---

## Roadmap (next up)

**Phase 8: Tool Registry & Observability (P1)**
- [x] `8.1` Unified task status JSON — canonical terminal state (P1) ✅ DONE 2026-04-24
  - `lib/task-status.sh` (~50 lines), `bin/test-task-status.sh` (5 tests)
  - schema v1: 15 fields, strategy/final_state/candidates/markers/duration
  - 7 terminal points wired (4 consensus + 3 first_success)
  - macOS BSD date fix applied, dead markers_csv param removed
  - 5/5 tests PASS, no regression
- [x] `8.2` `orch-metrics.sh rollup` — .status.json aggregation (P1) ✅ DONE 2026-04-24
  - `bin/orch-metrics.sh` +~180 lines (rollup subcommand, python in-process aggregator)
  - 9 fixtures in `test-fixtures/metrics/` covering 4 strategies × 4 final_states + malformed + schema_v2 + old timestamp
  - `bin/test-orch-metrics-rollup.sh` — 27 tests PASS, runtime 0.046s (<2s budget)
  - JSON matches spec schema (totals, by_task_type, consensus_score_distribution, reflexion_histogram, final_state_counts)
  - No regression in event-log mode
- [x] `8.3` Execution trace viewer via orch-notify MCP (P1) ✅ DONE 2026-04-24
  - `lib/trace-query.sh` (~220 lines, python3 in-process, 3 ops: get_task_trace / get_trace_waterfall / recent_failures)
  - `test-fixtures/trace/` (7 files: tasks.jsonl, 3×.status.json, 3×reflexion blobs, audit.jsonl)
  - `bin/test-trace-query.sh` — 36 tests PASS covering all 8 spec edge cases (0-lane waterfall, limit clamp, malformed JSONL skip, shell-unsafe task_id, etc.)
  - `mcp-server/server.mjs` — 3 new tool handlers (get_task_trace / get_trace_waterfall / recent_failures) added, thin delegation to lib/trace-query.sh
  - No regression in existing 6 tools, no new deps beyond python3 stdlib
- [ ] `8.4` Token budget dashboard in orch-dashboard.sh (P1)

**Phase 9: Advanced Patterns (P2, trigger-based)**
- [ ] `9.1` Multi-turn orchestration sessions (P2)
- [ ] `9.2` Gibberlink/agent-to-agent protocol stub (P2)
- [ ] `9.3` Cross-project orchestration (P2)
- [ ] `9.4` ReAct pattern for orchestration agents (P2)

---

## Icebox

- [ ] Phase 8 remaining tasks (tool-registry, trace viewer, budget dashboard)
- [ ] Phase 9 tasks (multi-turn, agent protocol, cross-project, ReAct)
- [ ] Move 9 deprecated libs → `lib/deprecated/` (cleanup cosmetic)
- [ ] `D.2` `setup-router.sh apply` to `~/.claude/settings.json`

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

**Rollback plan:** Each P0/P1 task has rollback ≤5 lines. Keep fallback flags in `config/models.yaml` to disable feature when needed.

---

## Archive

| Date | What | Where |
|------|------|-------|
| 2026-04-24 | **Phase 8.3 DONE** — orch-notify trace viewer: 3 new MCP tools (get_task_trace, get_trace_waterfall, recent_failures), lib/trace-query.sh (python3 in-process, 3 ops), test-fixtures/trace/ (7 files), bin/test-trace-query.sh (36 tests PASS), server.mjs updated. Thin delegation pattern, no new deps, no regression. | lib/trace-query.sh, bin/test-trace-query.sh, mcp-server/server.mjs, test-fixtures/trace/*, docs/PROMPT_phase8.3.md |
| 2026-04-24 | **Phase 8.2 DONE** — orch-metrics.sh rollup subcommand: .status.json aggregation by task_type × strategy_used, consensus score distribution, reflexion histogram. 27 tests PASS, 0.046s runtime, no regression in event-log mode. Spec archived. | bin/orch-metrics.sh, bin/test-orch-metrics-rollup.sh, test-fixtures/metrics/*, docs/archive/PROMPT_phase8.2_2026-04-24.md |
| 2026-04-24 | **Phase 8.1 DONE** — unified task status JSON: lib/task-status.sh, 7 terminal points wired, schema v1, 5 tests PASS, macOS BSD date fix | commit 7f59a73, 1ac531b |
| 2026-04-24 | **Phase 7.1 COMPLETE** — consensus-vote wired: 7.1a scaffold, 7.1b fan-out dispatch, 7.1c Jaccard similarity merge, 7.1d reflexion loop. 11+9 tests PASS, integration smoke PASS | commits d2a3214, 0c30527, 641a8db, eb2ea71, 12a57fd, d72aa95 |
| 2026-04-24 | **Phase 7.1b DONE** — consensus fan-out dispatch: helpers, dispatch_task_consensus (368 lines), test-consensus-dispatch.sh (6 tests PASS), integration smoke PASS, rollback 1-line config flip verified | commits 641a8db, eb2ea71 |
| 2026-04-24 | **Phase 7.1a DONE** — consensus-vote scaffold: bash 3.2 stubs, AGENT_WEIGHTS remap (raw keys), find_winner subshell fix (process substitution), source guard (BASH_SOURCE guard), 6-test harness PASS | commits 24bb3fd, d72aa95, 12a57fd |
| 2026-04-24 | **Phase 7.1a DONE** — consensus-vote.sh scaffolded: bash 3.2 no-op stubs, AGENT_WEIGHTS remapped to current model names, consensus_merge() placeholder added, bin/test-consensus.sh written | lib/consensus-vote.sh + bin/test-consensus.sh |
| 2026-04-24 | **Phase 7.3 DONE** — `bin/test-compressor.sh` (150 lines) confirms compress_summary() ratios 0.301/0.500/0.700 on 57KB structured payload. `smoke-test-context-compressor.sh` removed (redundant). | commit 7ce4e22, fbbaf9a |
| 2026-04-23 | **Phase 7.2 DONE** — eval-harness.sh (439 lines) + 2 golden cases + context-compressor set -e fix | commit 0a60645 |
| 2026-04-23 | **Phase 6 CLOSED** — 6.1 dag-healer wire, 6.2 reflexion loop, 6.3 context-compressor, 6.4 deprecated. 5 bugs fixed via code review + smoke test | commit 4f86075 |
| 2026-04-23 | **Phase 6 COMPLETE** (6.1-6.4): dag-healer + quality-gate + context-compressor wired, state-conflict-resolver deprecated | bin/task-dispatch.sh + bin/task-selfheal.sh + lib/quality-gate.sh + lib/deprecated/ |
| 2026-04-23 | Phase 6-9 roadmap v2 — with acceptance criteria (from Claude app) | WORK.md + docs/ORCHESTRATION_ROADMAP.md |
| 2026-04-23 | Phase 5 wiring audit + add verify tasks to Active | PHASE5_IDEAS.md + WORK.md |
| 2026-04-23 | Smoke test refactor — PASSED. Found + fixed bash 3.2 incompat in triage-tiers/consensus-vote | commit 17cca11 |
| 2026-04-23 | Verify wiring: agent-failover + cost-tracker + intent-verifier (all confirmed at line-level) | PHASE5_IDEAS.md updated |
| 2026-04-23 | Runtime proof: intent-verifier, cost-tracker, task-dispatch --parallel all confirmed | commit 7ebf500 |
| 2026-04-23 | Route_task MCP round-trip test via 9router | mcp-server/9router-agent.mjs |
| 2026-04-23 | Add minimax-code as backup fallback to all task types | config/models.yaml |

---

## Notes (self-discovery during Phase 6-7)

### ZSH glob nullglob issue when lib sourced
- `shopt -s nullglob` inside a function sourced by zsh doesn't expand globs correctly when PID (`$$`) in path
- Root cause: zsh treats `*.reflexion.json` differently from bash when nullglob is set inside sourced function
- **Fix:** Use `find ... -name "*.reflexion.json" | wc -l` instead of glob arrays for portable cross-shell
- **Applies to:** All libs that do file counting with glob patterns

### Reflesion v1/v2 naming vs single file
- `<tid>.vN.reflexion.json` (v1, v2) overwrites single `<tid>.reflexion.json` — correct decision
- Preserves audit trail for max 2 iterations
- Required for re-dispatch loop (Bug #3 deferred) to track iteration precisely

### Context-compressor is summarization-based
- `compress_summary()` keeps first N lines based on `level` (0.3/0.5/0.7)
- NOT a byte-level compressor — ratio depends on content structure
- Ratio=0 in smoke test because 60k of repeated `X` chars compresses to ~45 bytes of summary
- Real payload (code, docs) → ratio ~0.3-0.7 as expected
- **Also fixed:** `set -euo pipefail` removed (same Bug #1 pattern as quality-gate.sh)

### Consensus sim_threshold tuning observation
- Real LLM outputs score below Jaccard 0.2 for identical tasks — current global threshold (0.3) may be too high for some task types
- Consider per-task_type sim_threshold tuning: `architecture_analysis: 0.15`, `security_audit: 0.3`, `design_api: 0.2`
- LLM outputs are structurally diverse even when semantically equivalent — Jaccard on raw text penalizes formatting differences
- **Action:** Track consensus_score distribution per task_type in production, then calibrate thresholds from real data

### Consensus voting design
- Current dispatch_parallel() uses `agent.sh` once per spec — each parallel model is a single agent call, not multiple
- To implement consensus: need to intercept the parallel results BEFORE they're written to single `results/<tid>.out`
- Approach: modify parallel dispatch to collect N outputs, pass to consensus-vote.sh, write merged result
- Config: `parallel_policy.pick_strategy: consensus` in models.yaml
- Consensus fail → trigger reflexion (resolves Bug #3 deferred)
