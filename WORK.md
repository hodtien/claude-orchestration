# Work Log — Claude Orchestration

> Single source of truth for active work. Work-in-progress, icebox ideas, and completed task log.
> Inspired by the pattern: no new MD files for WIP (use this file instead).

---

## Active

Nothing pending.

Deferred (do when actually needed):
- [ ] Full `route_task` MCP round-trip test from live Claude Code session (when next mid-session delegation happens)
- [ ] `task-dispatch.sh --parallel` with real agents on 2-3 task fake batch (before next real batch run)
- [ ] `setup-router.sh apply` on `~/.claude/settings.json` (when ready to switch Claude Code to 9router)

---

## Icebox

- [ ] Wire consensus-vote.sh (trigger: `parallel_policy.pick_strategy: consensus` enabled in models.yaml)
- [ ] Wire dag-healer.sh (trigger: task-dispatch DAG execution is stable enough to self-check)
- [ ] Wire context-compressor.sh (trigger: context budget becomes a problem in real usage)
- [ ] **Deprecate state-conflict-resolver.sh** (speculation-layer feature, # TODO in code confirms incomplete, no active callers, belongs in lib/deprecated/)
- [ ] Move 9 deprecated libs to lib/deprecated/ (low priority, do after 1 month of usage)

---

## Archive

| Date | What | Where |
|------|------|-------|
| 2026-04-23 | Phase 5 wiring audit + add verify tasks to Active | PHASE5_IDEAS.md + WORK.md |
| 2026-04-22 | Refactor: 10 tasks (multi-model routing, CLI-first, hooks wired) | docs/archive/refactor-2026-04-22/ |
| 2026-04-22 | Phase 5 wiring status audit + lib/ audit | PHASE5_IDEAS.md + docs/archive/LIB_AUDIT_2026-04-22.md |
| 2026-04-22 | Add repo_analysis task_type (1M-token via gemini-cli) | config/models.yaml + mcp-server/9router-agent.mjs |
| 2026-04-22 | Fix cost.sh path + config/agents.json (out-of-box) | bin/_dashboard/cost.sh + config/agents.json |
| 2026-04-22 | Archive plan files, add WORK.md workflow | WORK.md + docs/archive/refactor-2026-04-22/ |
| 2026-04-23 | Smoke test refactor — PASSED. Found + fixed bash 3.2 incompat in triage-tiers/consensus-vote | commit 17cca11 |
| 2026-04-23 | Verify wiring: agent-failover + cost-tracker + intent-verifier (all confirmed at line-level). state-conflict-resolver reclassified Deprecated | PHASE5_IDEAS.md updated |
| 2026-04-23 | Runtime proof (smoke-wiring test): intent-verifier confirmed fired (verification-logs +1). Found regression: bash 3.2 missing function stubs in triage-tiers → fixed | commit 7ebf500 |
| 2026-04-23 | Runtime proof cost-tracker: ✅ confirmed fired. Dispatched real task via copilot → cost-tracking.jsonl +1 line, cost-summary by_agent task_count +1 (31→60 tokens_input, 308→384 tokens_output) | config/models.yaml + WORK.md |
| 2026-04-23 | Add minimax-code as backup fallback to all task types in models.yaml | config/models.yaml |
| 2026-04-15 | Phase 1-4 refactor batches (health beacon, SLAs, DAG, metrics, failover, scheduler, reports) | .orchestration/tasks/phase1-4/ |