# Phase 8.2 — `orch-metrics.sh rollup` subcommand

**Date:** 2026-04-24
**Prereq:** Phase 8.1 landed (commit `ea0f2b6`). `.status.json` schema v1 is canonical.
**Scope:** Add `rollup` subcommand to `bin/orch-metrics.sh` that aggregates `.status.json` files.
**Out of scope:** Dashboard UI (8.3), lib audit (8.4), migration to `.status.json` as sole source for existing dashboard modes (separate phase).

---

## Context

Phase 8.1 introduced `.status.json` (schema v1) as the canonical terminal-state record for every dispatched task. Written atomically by `lib/task-status.sh:write_task_status` via helpers `_write_status_consensus` / `_write_status_first_success` in `bin/task-dispatch.sh`.

Current `orch-metrics.sh` reads `.orchestration/tasks.jsonl` (event audit log) — shows per-event stats (start/complete/retry), parallelization, per-agent duration. **It does not aggregate across `.status.json` files** and has no visibility into consensus-specific state (strategy_used, consensus_score, reflexion_iterations).

Phase 8.2 fills that gap by adding a **`rollup` subcommand** that reads all `.status.json` files under `.orchestration/results/` and emits an aggregated summary keyed by `task_type × strategy_used`.

---

## Schema reference — `.status.json` (v1)

Defined by `lib/task-status.sh:build_status_json`. Every terminal state writes exactly these fields:

```json
{
  "schema_version": 1,
  "task_id": "arch-test-001",
  "task_type": "architecture_analysis",
  "strategy_used": "consensus",
  "final_state": "done",
  "output_file": "arch-test-001.out",
  "output_bytes": 42,
  "winner_agent": "merged",
  "candidates_tried": ["gemini-pro", "cc/claude-sonnet-4-6", "minimax-code"],
  "successful_candidates": ["gemini-pro", "cc/claude-sonnet-4-6", "minimax-code"],
  "consensus_score": 0.429,
  "reflexion_iterations": 0,
  "markers": [],
  "duration_sec": 0.0,
  "started_at": "2026-04-24T09:49:23Z",
  "completed_at": "2026-04-24T09:49:23Z"
}
```

**Known `strategy_used` values** (from `bin/task-dispatch.sh` call sites L1068/L1118/L1198/L1246/L1730/L1805):
- `consensus` — consensus fan-out succeeded
- `consensus_exhausted` — consensus gave up (after reflexion retries)
- `first_success` — first-success dispatch succeeded
- `failed` — helper called from L1805 failover path (agent-DOWN)

**Known `final_state` values:**
- `done` — task completed successfully
- `exhausted` — consensus gave up but output merged best-effort (7.1d)
- `failed` — terminal failure
- `needs_revision` — disagreement marker (Phase 7.1c)

---

## CLI surface

Extend existing `orch-metrics.sh` with a new subcommand. Keep backward compat — running `orch-metrics.sh` with no subcommand or with existing `--json` / `--since` / `--agent` flags must work exactly as today.

```
# Existing (unchanged):
orch-metrics.sh                       # event-log dashboard
orch-metrics.sh --json                # event-log JSON
orch-metrics.sh --since 24h           # event-log filtered
orch-metrics.sh --agent gemini-pro    # event-log filtered

# New:
orch-metrics.sh rollup                # .status.json rollup (human-readable)
orch-metrics.sh rollup --json         # .status.json rollup (machine JSON)
orch-metrics.sh rollup --since 24h    # filter by completed_at
orch-metrics.sh rollup --dir <path>   # override results dir (default: .orchestration/results)
```

Implementation note: dispatch on `$1 == "rollup"` at top of arg parsing; shift and enter a new codepath (separate python block). Do not conflate with existing event-log aggregator.

---

## Rollup output — JSON schema

```json
{
  "schema_version": 1,
  "generated_at": "2026-04-24T10:15:00Z",
  "source_dir": ".orchestration/results",
  "filter": { "since": "24h", "task_type": null, "strategy": null },
  "totals": {
    "status_files_scanned": 142,
    "schema_v1_valid": 140,
    "schema_invalid_or_unreadable": 2,
    "unique_tasks": 140
  },
  "by_task_type": {
    "architecture_analysis": {
      "total": 35,
      "success_rate_pct": 91.4,
      "by_strategy": {
        "consensus":            { "count": 30, "success": 28, "avg_duration_sec": 12.4, "avg_consensus_score": 0.61 },
        "consensus_exhausted":  { "count":  3, "success":  0, "avg_duration_sec": 18.2, "avg_consensus_score": 0.05 },
        "first_success":        { "count":  2, "success":  2, "avg_duration_sec":  6.1, "avg_consensus_score": 0.0 }
      }
    },
    "implement_feature": { "...": "..." }
  },
  "consensus_score_distribution": {
    "buckets": [
      { "range": "0.0-0.2", "count": 5 },
      { "range": "0.2-0.4", "count": 12 },
      { "range": "0.4-0.6", "count": 45 },
      { "range": "0.6-0.8", "count": 55 },
      { "range": "0.8-1.0", "count": 23 }
    ],
    "note": "only tasks with strategy_used in {consensus, consensus_exhausted}"
  },
  "reflexion_iterations_histogram": {
    "0": 110,
    "1": 18,
    "2": 10,
    "3+": 2
  },
  "final_state_counts": {
    "done": 128,
    "exhausted": 8,
    "failed": 4,
    "needs_revision": 0
  }
}
```

### Definitions

- **`success`** per strategy bucket: `final_state == "done"` (not `exhausted`, not `failed`).
- **`success_rate_pct`** per task_type: `sum(success) / total * 100`, rounded to 1 decimal.
- **`avg_duration_sec`**: mean of `duration_sec` across files in that bucket, rounded to 1 decimal. If all are 0.0 (current seed data), report `0.0` — do not crash.
- **`avg_consensus_score`**: mean of `consensus_score`, only counted for files where `strategy_used ∈ {consensus, consensus_exhausted}`. For `first_success` / `failed`, set to `0.0`.
- **`consensus_score_distribution`**: half-open buckets `[0.0, 0.2)`, `[0.2, 0.4)`, `[0.4, 0.6)`, `[0.6, 0.8)`, `[0.8, 1.0]` (last bucket closed to catch 1.0). Only from consensus strategies.
- **`reflexion_iterations_histogram`**: exact counts for 0, 1, 2, then `3+` bucket for ≥3.
- **`schema_invalid_or_unreadable`**: files that fail `json.load` or miss `schema_version == 1`. Counted separately, never crash the rollup.

---

## Human-readable output (no `--json`)

```
============================================================
  ORCHESTRATION ROLLUP (.status.json)
============================================================
  Source: .orchestration/results
  Scanned: 142 files (140 valid schema v1, 2 skipped)
  Filter: last 24h

── Final State ──────────────────────────────────────────
  done:           128  (91.4%)
  exhausted:        8  ( 5.7%)
  failed:           4  ( 2.9%)
  needs_revision:   0  ( 0.0%)

── By Task Type × Strategy ──────────────────────────────
  architecture_analysis    n=35  success=91%
    consensus            30× │ ok 28 │ avg  12s │ score 0.61
    consensus_exhausted   3× │ ok  0 │ avg  18s │ score 0.05
    first_success         2× │ ok  2 │ avg   6s │ —
  implement_feature        n=78  success=94%
    ...

── Consensus Score Distribution ─────────────────────────
  0.0 – 0.2  [█░░░░░░░░░░░░░]   5
  0.2 – 0.4  [███░░░░░░░░░░░]  12
  0.4 – 0.6  [████████████░░]  45
  0.6 – 0.8  [██████████████]  55
  0.8 – 1.0  [██████░░░░░░░░]  23

── Reflexion Iterations ─────────────────────────────────
  0 iters: 110  1 iter: 18  2 iters: 10  3+: 2
============================================================
```

Keep the visual style consistent with the existing event-log dashboard (same box characters, 60-col width, emoji-free).

---

## Edge cases — MUST handle

1. **Empty results dir** — `0 files scanned`, emit valid JSON/dashboard with zeros, exit 0. Do not error.
2. **Malformed JSON** — count in `schema_invalid_or_unreadable`, skip. Never crash.
3. **Missing optional fields** — `consensus_score`/`reflexion_iterations` default 0; `markers` default `[]`. Use `.get(key, default)`, not `[key]`.
4. **`schema_version != 1`** — skip with warning to stderr, count as invalid. Forward-compat for future schema bumps.
5. **Unknown `strategy_used` or `final_state`** — bucket under the literal string. Do not drop.
6. **`--since` filter** — parse `completed_at` (ISO8601 Z-suffix, same format as existing code). Files with unparseable timestamps are included when no filter, excluded when filter is active.
7. **`duration_sec == 0.0` for all files** — current seed data has this. Reported avg must be `0.0`, not `NaN`, not crash on divide-by-zero.

---

## Acceptance criteria

- [ ] `orch-metrics.sh rollup --json` emits valid JSON matching the schema above.
- [ ] `orch-metrics.sh rollup` (no `--json`) produces human dashboard with same data.
- [ ] `orch-metrics.sh` (no subcommand) still works identically to today — no regression in event-log mode.
- [ ] Test script `bin/test-orch-metrics-rollup.sh` covers:
  1. Empty dir → valid empty rollup
  2. Seed 6 fixture files across all 4 strategies + all 4 final_states → counts match
  3. Malformed JSON file → counted in `schema_invalid_or_unreadable`, not crash
  4. `schema_version=2` file → skipped, counted invalid
  5. `--since 1h` filter excludes old completed_at
- [ ] Runtime < 2s for 100 status files (python3 in-process aggregation is fine, no subprocess per file).
- [ ] No new dependencies beyond python3 stdlib (already used by existing code).
- [ ] Fixture files under `test-fixtures/metrics/` (new dir), not in `.orchestration/results/` — tests must not pollute real results dir.

---

## Files to touch

| File | Role | Expected change |
|---|---|---|
| `bin/orch-metrics.sh` | add `rollup` subcommand dispatch + python aggregator block | +~150 lines |
| `bin/test-orch-metrics-rollup.sh` | **new** — 5+ unit tests per acceptance list | ~200 lines |
| `test-fixtures/metrics/*.status.json` | **new** — seeded fixtures | 6-8 files |

Do NOT modify `lib/task-status.sh` — schema is frozen in 8.1.

---

## Commit message template

```
Phase 8.2: orch-metrics.sh rollup — .status.json aggregation

Adds `rollup` subcommand to orch-metrics.sh that reads all .status.json
files under .orchestration/results/ and emits aggregation keyed by
task_type × strategy_used. Includes consensus_score distribution and
reflexion_iterations histogram.

Complements existing event-log dashboard (tasks.jsonl) — the two modes
now show event stream vs terminal state, respectively. No regression
in existing modes.

Tests: bin/test-orch-metrics-rollup.sh covers empty dir, malformed JSON,
schema-version mismatch, --since filter, and all strategy×final_state
combos from 8.1.
```

---

## Open icebox (not this phase)

- **Migrate event-log dashboard to also surface schema fields** (strategy, consensus_score) — needs schema in `tasks.jsonl` too. Later.
- **Time-series rollup** (daily/weekly buckets) — wait until we have volume.
- **Export to prometheus/json-lines for external dashboards** — wait until dashboard UI (8.3) dictates the shape.
