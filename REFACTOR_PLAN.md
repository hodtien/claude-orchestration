# Refactor Plan — Claude Orchestration

**Goal:** Simplify the orchestration system to fit its actual use (solo dev)
and align with the multi-model routing architecture via 9router.

**Scope (this refactor):** Dọn dẹp + wiring (Week 1–3).
No new features. No new agents.

---

## Architecture (what we're keeping)

```
┌────────────────────────────────────────────────────────────┐
│  Claude Code (CLI) — acts as PM orchestrator               │
│  settings.json → ANTHROPIC_BASE_URL = http://localhost:20128│
│  All Claude requests go through 9router.                   │
└────┬────────────────────────────┬──────────────────────────┘
     │ (subagent via MCP or shell)│ (subagent via shell)
     ▼                            ▼
┌──────────────────────┐   ┌──────────────────────────────┐
│  9router (external)  │   │  gemini-cli / copilot CLI    │
│  - Round-robin       │   │  - Invoked via shell exec    │
│    Claude accounts   │   │  - Each CLI manages its own  │
│  - Minimax adapter   │   │    auth/model                │
│  - Quota tracker     │   │  - Used for: long-context    │
│  - Circuit breaker   │   │    analysis, repo-aware      │
│                      │   │    review                    │
└──────┬─────────┬─────┘   └──────────────────────────────┘
       │         │
       ▼         ▼
  Claude API  Minimax API
  (múltiple)  (single)
```

**Critical change:** Claude Code itself is configured to talk to 9router.
This means Claude's own tokens get cost-optimized and load-balanced too —
not just subagent calls.

---

## What we're cutting

### 1. Stale docs
- `README.md` references to `beeknoee` (lines 12, 25, 162) — removed
- `CLAUDE.md` reference to `workflows/` directory (line 321) — directory doesn't exist, removed
- `docs/upgrade/` (7 files, ~85KB) from 15/4 — moved to `docs/archive/`
- `docs/MCP_Cross_Platform_Setup.md` — check relevance, likely archive
- Model names verified (gemini-3.1-pro-preview, gpt-5.3-codex) — replaced with actual working names

### 2. Orphan scripts (29 in bin/)
Scripts that nothing references — either delete, or explicitly wire them in.

**Delete list** (after confirmation):
- `consensus-trigger.sh`, `decompose.sh`, `intent-detect.sh`, `learn-from-batch.sh`
- `orch-trace.sh`, `parallel-run.sh`
- `provenance-blame.sh`, `provenance-commit.sh`, `provenance-query.sh`
- `routing-advisor.sh`, `share-learnings.sh`, `speculation-detector.sh`
- `sprint-manager.sh`, `style-diff.sh`, `style-memory-query.sh`, `style-memory-sync.sh`
- `task-dlq.sh`, `task-gen.sh`, `task-init.sh`, `task-new.sh`, `transfer-context.sh`

**Keep** (will be wired in Task #6):
- `agent-swap.sh` → wire into task-dispatch.sh for failover
- `orch-cost-dashboard.sh` → merge into orch-dashboard.sh
- `orch-scheduler.sh` + `scheduled-run.sh` → keep, document usage
- `orch-selftest.sh` → CI/health
- `orch-slo-report.sh` → merge into orch-dashboard.sh
- `orch-metrics-db.sh` → merge
- `orch-report.sh` → merge

### 3. Consolidate duplicates

| Before | After |
|---|---|
| `agent-cost.sh`, `orch-cost-dashboard.sh`, `orch-metrics.sh`, `orch-metrics-db.sh`, `orch-report.sh`, `orch-slo-report.sh` | `orch-dashboard.sh` with subcommands: `cost`, `metrics`, `slo`, `report` |
| `orch-scheduler.sh`, `scheduled-run.sh`, `task-schedule.sh` | `orch-scheduler.sh` with subcommands |
| `task-new.sh`, `task-init.sh`, `task-gen.sh` | Already marked for delete (orphan) |

**Target:** from 58 scripts → ~25.

### 4. Delete `mcp-server/9router-agent.mjs`
The real 9router runs externally (separate repo). This local MCP wrapper is
dead code — Claude Code talks to 9router via `ANTHROPIC_BASE_URL`, no MCP
wrapper needed.

---

## What we're adding (minimal)

### 1. `config/models.yaml`
Task type → model mapping with fallback chains. Single source of truth for
what model handles what task. 9router does actual routing; this file tells
the dispatcher which model name to request.

### 2. `bin/setup-router.sh`
One-shot script to:
- Back up `~/.claude/settings.json`
- Set `ANTHROPIC_BASE_URL=http://localhost:20128`
- Add revert flag (`--revert`) to restore backup

### 3. `bin/orch-dashboard.sh`
Consolidated metrics/cost/SLO reporting with subcommands.

### 4. Wiring in `task-dispatch.sh`
Three hooks (using existing lib/ code):
- `lib/intent-verifier.sh` → before dispatch (verify task spec against reality)
- `lib/cost-tracker.sh` → on each agent response (log tokens used per model)
- `lib/agent-failover.sh` → on agent error (try fallback from models.yaml)

---

## Order of work

| Step | What | Risk | Done when |
|---|---|---|---|
| 1 | Write this plan + models.yaml | Low | You read it, approve or adjust |
| 2 | Remove stale docs, legacy refs | Low | README/CLAUDE.md clean, archive/ created |
| 3 | Delete orphan scripts | Low (reversible via git) | bin/ has ~30 scripts |
| 4 | Consolidate metrics → orch-dashboard.sh | Medium | old commands still work as thin aliases |
| 5 | Write setup-router.sh | Low | settings.json can be set/reverted |
| 6 | Wire intent/cost/failover into task-dispatch | Medium | --status dispatch still works |
| 7 | Rewrite CLAUDE.md for 2-mode arch | Low | CLAUDE.md reflects reality |
| 8 | Verify: orch-health + --status dispatch | Low | All green |

---

## Non-goals (for this refactor)

- Building 9router itself (that's a separate repo)
- Adding new agent types
- Implementing Phase 6 features (autonomous learning, etc.)
- Touching the `everything-claude-code/` plugin

## Rollback

Every commit is atomic. If any step breaks something, `git revert <sha>`
the specific commit. No rewrites of history.
