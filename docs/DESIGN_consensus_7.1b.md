# Design: Phase 7.1b — Consensus Fan-Out Dispatch

## 1. Goal & Scope

Extend `task-dispatch.sh` to fan out a single task to N candidate models
(from `task_mapping.<type>.parallel`), collect N outputs, and merge via
`consensus_merge()` into a single result. This replaces the current
implicit `first_success` path **only for whitelisted task types**.

**In scope (7.1b):** fan-out, candidate collection, invoke `consensus_merge`,
write single result, keep audit trail, flag-gated opt-in.

**Out of scope (deferred to 7.1c/7.1d):**
- Real similarity scoring (7.1c — Jaccard + merge rule)
- Consensus-fail → reflexion re-dispatch loop (7.1d; closes Bug #3)
- Per-spec front-matter override (future; global+type flags sufficient for now)

## 2. Opt-In Model

Two layers of opt-in, both must be true for consensus path to activate.

**Layer 1 — Global (models.yaml):**
```yaml
parallel_policy:
  pick_strategy: consensus       # was: first_success
  max_parallel: 3
  timeout_per_model_sec: 120
```

**Layer 2 — Per task_type (models.yaml):**
```yaml
task_mapping:
  architecture_analysis:
    parallel: [gemini-pro, cc/claude-sonnet-4-6, minimax-code]
    consensus: true              # NEW — explicit opt-in
    ...
  quick_answer:
    parallel: [gemini-low, minimax-code]
    # consensus field omitted → defaults to false → first_success path
```

Initial whitelist (7.1b ship): `architecture_analysis`, `design_api`,
`security_audit`. All other task_types keep first_success behavior unchanged.

**Why two layers:** global flag acts as kill switch (set `first_success` to
disable entirely); per-type flag avoids paying 3× cost on trivial tasks.

## 3. Fan-Out Dispatch Flow

New function `dispatch_task_consensus(spec, task_type)` in `task-dispatch.sh`:

```
1. Resolve candidates = parallel[] intersect max_parallel (cap 3)
2. For each candidate in parallel (up to cap):
     Launch agent.sh <candidate> <tid> <prompt> in background
     Record pid → candidate mapping
     Redirect stdout to results/<tid>.candidates/<candidate>.out
3. Wait all pids, timeout per-candidate = timeout_per_model_sec
4. Collect successful candidates (exit 0 AND file non-empty)
   - If count < 2 → fallback: pick first successful → write results/<tid>.out → return
   - If count == 0 → return rc=1 (task failed; reflexion picks up in 7.1d)
5. Build candidates JSON: [{agent_id, output, confidence:1.0}, ...]
6. Call consensus_merge (currently returns first; 7.1c: real merge)
7. Write merged to results/<tid>.out with front-matter:
     consensus_score: <avg_similarity>   # 7.1c; 7.1b writes 1.0 placeholder
     candidate_count: N
     winner_agent: <id or 'merged'>
```

Dispatcher entry point in `dispatch_task()`:

```bash
if [ "$pick_strategy" = "consensus" ] && is_consensus_type "$task_type"; then
    dispatch_task_consensus "$spec" "$task_type"
else
    dispatch_task_first_success "$spec" "$agent"   # existing path, renamed
fi
```

## 4. Data Model

Per-task audit trail preserved for debug and post-hoc analysis:

```
.orchestration/results/
  <tid>.out                    # merged winner (single source of truth)
  <tid>.candidates/
    gemini-pro.out             # raw candidate 1
    cc_claude-sonnet-4-6.out   # raw candidate 2 (slashes → underscores in filename)
    minimax-code.out           # raw candidate 3
  <tid>.consensus.json         # metadata: {candidates, scores, winner, timestamp}
```

`<tid>.consensus.json` format:
```json
{
  "task_id": "task-017",
  "task_type": "architecture_analysis",
  "candidates": [
    {"agent": "gemini-pro", "chars": 2340, "exit_code": 0, "duration_s": 45},
    {"agent": "cc/claude-sonnet-4-6", "chars": 1890, "exit_code": 0, "duration_s": 38},
    {"agent": "minimax-code", "chars": 0, "exit_code": 124, "duration_s": 120}
  ],
  "successful_count": 2,
  "winner_agent": "gemini-pro",
  "consensus_score": 1.0,
  "strategy_used": "consensus",
  "timestamp": "2026-04-24T10:30:00Z"
}
```

## 5. Cost Controls

- `max_parallel: 3` hard cap (ignore parallel[] entries beyond index 2)
- `timeout_per_model_sec: 120` per candidate — slow models killed, counted as fail
- Budget tracking: existing `cost-tracker.sh` records each candidate as
  separate invocation (so consensus task logs 3 rows, not 1)
- Expected amortized cost multiplier: 3× baseline for whitelisted types only

**Whitelist is the cost lever.** 3 task_types × roughly 10% of total volume
× 3× cost = ~1.3× total bill worst case. Acceptable for P1 quality gain.

## 6. Failure Modes

| Scenario                                  | Behavior                                            |
|-------------------------------------------|-----------------------------------------------------|
| All N candidates succeed                  | Merge, write result, exit 0                         |
| N-1 succeed, 1 timeout                    | Merge over N-1, write result, exit 0                |
| Only 1 candidate succeeds                 | Write that output as result (fallback), exit 0      |
| 0 candidates succeed                      | No result file, exit 1 (reflexion picks up in 7.1d) |
| `consensus_merge` itself errors           | Fallback: write first successful candidate verbatim |
| `pick_strategy` != consensus              | Skip fan-out entirely, use existing first_success   |
| Task type not in whitelist                | Skip fan-out entirely, use existing first_success   |

## 7. Config Flags & Rollback

**Enable consensus for one type (activate feature):**
```yaml
# config/models.yaml
parallel_policy:
  pick_strategy: consensus
task_mapping:
  architecture_analysis:
    consensus: true
```

**Disable globally (kill switch — 1-line rollback):**
```yaml
parallel_policy:
  pick_strategy: first_success   # was: consensus
```
Effect: all dispatch paths revert to existing behavior; candidate
directories not created; no other code changes required.

**Disable for one type (surgical rollback):**
```yaml
task_mapping:
  architecture_analysis:
    consensus: false             # or remove field entirely
```

**Full revert (if 7.1b itself broken):**
```
git revert <7.1b commit>
```
Removes `dispatch_task_consensus`, reverts `dispatch_task` branching.
`lib/consensus-vote.sh` (7.1a) remains untouched — safe.

## 8. Test Plan

**Unit (bin/test-consensus-dispatch.sh — new):**
- Mock 3 agents echoing fixed strings → verify all 3 `.out` files exist
- Mock 2 succeed + 1 timeout → verify merged result + consensus.json records failure
- Mock 0 succeed → verify rc=1, no result file
- `pick_strategy: first_success` → verify fan-out skipped

**Integration:**
- Real dispatch: task-type `architecture_analysis` with 3-model parallel
- Verify `<tid>.candidates/*.out` populated
- Verify `<tid>.consensus.json` has 3 candidate records
- Verify `<tid>.out` exists and non-empty

**Smoke (no code, config only):**
- Flip `pick_strategy` to `first_success`, re-run same task — confirm
  candidate directory NOT created (rollback proof)

## 9. Implementation Checklist

- [ ] Add `consensus: true` field support to models.yaml parser (yq query)
- [ ] `is_consensus_type()` helper reading task_mapping.<type>.consensus
- [ ] `dispatch_task_consensus()` — fan-out, wait, collect, merge
- [ ] Rename current `dispatch_task` body → `dispatch_task_first_success`
- [ ] Branch `dispatch_task` on pick_strategy
- [ ] Write `.consensus.json` metadata
- [ ] `bin/test-consensus-dispatch.sh` with mock agents
- [ ] Whitelist in models.yaml: architecture_analysis, design_api, security_audit
- [ ] Update `WORK.md` — mark 7.1b DONE, note whitelist scope

## 10. Decisions (chốt trước khi code)

1. **Mock agent interface — env var `AGENT_SH_MOCK`.**
   In `dispatch_task_consensus()`, before invoking `agent.sh`:
   ```bash
   local agent_cmd="${AGENT_SH_MOCK:-$SCRIPT_DIR/agent.sh}"
   "$agent_cmd" "$candidate" "$tid" "$prompt" ...
   ```
   Test harness sets `AGENT_SH_MOCK=/path/to/tests/fixtures/mock-agent.sh`.
   Mock script reads env vars `MOCK_OUTPUT_<agent_normalized>` and
   `MOCK_EXIT_<agent_normalized>` to control per-candidate behavior.
   Production code path unchanged when env var unset.

2. **Candidate filename — replace only `/` → `_`.**
   ```bash
   local safe_name="${agent//\//_}"
   # cc/claude-sonnet-4-6 → cc_claude-sonnet-4-6.out
   # gh/gpt-5.3-codex     → gh_gpt-5.3-codex.out
   # minimax-code         → minimax-code.out (unchanged)
   ```
   Keeps dashes/dots for readability; filesystem on macOS/Linux accepts them.
   Reverse lookup: replace first `_` after `cc`/`gh`/`cursor` prefix with `/`.

3. **`confidence: 1.0` placeholder in candidates JSON for 7.1b.**
   `find_winner()` in consensus-vote.sh already expects this field
   (line 61). Keep schema stable; 7.1c replaces the literal 1.0 with
   a computed `weight × avg_similarity` score without changing format.
   Document in JSON comment: `"confidence": 1.0` means "not yet scored".
