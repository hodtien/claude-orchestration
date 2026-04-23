# Phase 5 Ideas — Claude Orchestration

> These are forward-looking feature ideas. Only add code if there's a real need.
> Do not pre-build features that sit unwired.

---

## Phase 5 — Code Drafted, Wiring Status

Code for these features exists in `lib/` or `bin/`, but whether they're
actually integrated into the main flow (`bin/task-dispatch.sh`) varies.

| Feature | Code Location | Status | Notes |
|---|---|---|---|
| Agent Swap Protocol | `lib/agent-failover.sh`, `bin/agent-swap.sh` | **Wired** | Sourced in task-dispatch.sh; triggered on agent error |
| Real-Time Cost Dashboard | `lib/cost-tracker.sh`, `bin/orch-cost-dashboard.sh` | **Wired** | Sourced in task-dispatch.sh and _dashboard/cost.sh |
| Intent Verification | `lib/intent-verifier.sh` | **Wired** | Sourced in task-dispatch.sh; runs before dispatch |
| Budget & Triage Tiers | `lib/triage-tiers.sh` | **Wired** | Sourced in task-dispatch.sh |
| Self-Healing DAG | `lib/dag-healer.sh` | Drafted, not wired | No call site in dispatch yet |
| Context Compression | `lib/context-compressor.sh` | Drafted, not wired | No call site in dispatch yet |
| Consensus Voting | `lib/consensus-vote.sh` | Drafted, not wired | Referenced in parallel_policy comment; lib/deprecated/ callers |
| Task Decomposer | `lib/task-decomposer.sh` + bin helpers | **Deprecated** | bin scripts moved to bin/deprecated/; lib orphan |
| Autonomous Learning | `lib/learning-engine.sh` + bin helpers | **Deprecated** | bin scripts moved; not enough data to learn from yet |
| Cross-Project Transfer | `lib/cross-project.sh` + bin helpers | **Deprecated** | bin scripts moved; solo-dev use case doesn't need this |
| Parallel Sprint | `lib/sprint-queue.sh` + bin helpers | **Deprecated** | bin scripts moved; complexity exceeds solo-dev need |
| Speculation Buffer | `lib/speculation-buffer.sh` + bin helpers | **Deprecated** | bin scripts moved; only in breakthrough-ideas docs |
| State Conflict Resolver | `lib/state-conflict-resolver.sh` | **DEPRECATED** → `lib/deprecated/` | No callers found
| Discarded Alternatives | `lib/discarded-alternatives.sh` | **Deprecated** | Only in bin/deprecated/consensus-trigger.sh (commented) |
| Style Memory | `lib/style-memory.sh` | **Deprecated** | Only in bin/deprecated/style-memory-*.sh (commented) |
| Provenance Tracker | `lib/provenance-tracker.sh` | **Deprecated** | Only in bin/deprecated/provenance-*.sh (commented) |

---

## Wiring Priority (active work)

Ordered by impact for solo-dev workflow:

1. **Agent Failover** — `lib/agent-failover.sh` already wired; verify it fires on error
2. **Cost Tracker** — `lib/cost-tracker.sh` already wired; verify rows appear in metrics.db
3. **Intent Verifier** — `lib/intent-verifier.sh` already wired; verify it runs before dispatch
4. **State Conflict Resolver** — ~~needs review: wire or shelve~~ → **DEPRECATED 2026-04-23**: Moved to `lib/deprecated/state-conflict-resolver.sh`. No active callers. No further action needed.
5. **Context Compression** — wire into task-dispatch when context budget becomes an issue
6. **Self-Healing DAG** — wire when task-dispatch DAGs are stable enough to self-check
7. **Consensus Voting** — wire when `parallel_policy.pick_strategy: consensus` is enabled

Everything else — reconsider after 1 month of real usage.

---

## Future Feature Ideas (not yet code)

These are concepts. Only add code if there's a real need; don't pre-build features.

### 1. Intent Forks
When a task has ambiguous requirements, dispatch to multiple specialized agents in parallel
(e.g., one for security-first, one for performance-first), then merge the results.
**Trigger:** task spec contains `?` or "or" in the acceptance criteria.

### 2. Self-Improvement Loop
After each batch, the orchestrator reviews its own routing decisions and updates
model preferences based on success/failure patterns.
**Trigger:** batch DLQ rate > 20%.

### 3. Cost-Aware Batching
Group tasks by cost-tier before dispatching. Run cheap tasks in bulk to amortize
context-switch overhead. Run expensive tasks (Opus) last, after cheap tasks validate the approach.
**Trigger:** budget remaining < 50%.

### 4. Learned Routing
Track which model produces the best output for which task type over time.
Build a simple lookup table (model → task_type → score) from batch results.
**Trigger:** after 10+ batches with consistent scoring.

### 5. Cross-Project Context Transfer
When starting a new project, import relevant lib/ and skill/ configurations
from similar past projects.
**Trigger:** new project detected (empty .orchestration/).

### 6. Autonomous Sprint Decomposition
Given a high-level goal, decompose into tasks, assign models, and run autonomously.
PM reviews results, not process.
**Trigger:** explicit `/autonomous` flag.

---

## Archived From

This file was rewritten from `plan.txt` (2026-04-22). The original claimed
"Phase 5 Completed" for all 10 features — this was inaccurate. Most features
had code drafted but were never wired into `bin/task-dispatch.sh`. The status
table above reflects actual wiring state as of 2026-04-23.
