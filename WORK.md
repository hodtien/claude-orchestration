# Work Log — Claude Orchestration

> Single source of truth for active work. Work-in-progress, icebox ideas, and completed task log.
> Inspired by the pattern: no new MD files for WIP (use this file instead).

---

## Active

Nothing pending — refactor complete.

---

## Icebox

- [ ] Wire consensus-vote.sh (trigger: `parallel_policy.pick_strategy: consensus` enabled in models.yaml)
- [ ] Wire dag-healer.sh (trigger: task-dispatch DAG execution is stable enough to self-check)
- [ ] Wire context-compressor.sh (trigger: context budget becomes a problem in real usage)
- [ ] Review state-conflict-resolver.sh (trigger: determine purpose, wire or shelve)
- [ ] Move 9 deprecated libs to lib/deprecated/ (low priority, do after 1 month of usage)

---

## Archive

| Date | What | Where |
|------|------|-------|
| 2026-04-22 | Refactor: 10 tasks (multi-model routing, CLI-first, hooks wired) | docs/archive/refactor-2026-04-22/ |
| 2026-04-22 | Phase 5 wiring status audit + lib/ audit | PHASE5_IDEAS.md + docs/archive/LIB_AUDIT_2026-04-22.md |
| 2026-04-22 | Add repo_analysis task_type (1M-token via gemini-cli) | config/models.yaml + mcp-server/9router-agent.mjs |
| 2026-04-22 | Fix cost.sh path + config/agents.json (out-of-box) | bin/_dashboard/cost.sh + config/agents.json |
| 2026-04-15 | Phase 1-4 refactor batches (health beacon, SLAs, DAG, metrics, failover, scheduler, reports) | .orchestration/tasks/phase1-4/ |