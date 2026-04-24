# Phase 8.1 — Unified Task Status (`<tid>.status.json`)

## Context

Bạn là agent được giao task implement Phase 8.1 cho project `claude-orchestration`. Phase 7 (consensus engine) vừa đóng với commit `346afe4`. Phase 8 = Observability & Cost Accounting, chia 4 sub-phases; đây là sub-phase 8.1 (foundation cho 8.2/8.3/8.4).

Đọc `CLAUDE.md`, `WORK.md`, và các file bên dưới trước khi code.

## Vấn đề

Hiện tại, mỗi task để lại rất nhiều file trên disk:

```
.orchestration/results/
  <tid>.out                    # stdout (may be empty if failed)
  <tid>.log                    # stderr log
  <tid>.cancelled              # marker (empty file)
  <tid>.failed                 # marker (empty file, 7.1d consensus)
  <tid>.exhausted              # marker (empty file, 7.1d consensus)
  <tid>.needs_revision         # quality-gate side-effect
  <tid>.consensus.json         # 7.1b-d consensus metadata
  <tid>.report.json            # 6.2 dispatch report
  <tid>.candidates/            # 7.1b raw candidate outputs
```

Downstream consumers (dashboard, inbox MCP, 6 metrics scripts) đều tự implement lại logic "task này kết thúc state gì?" bằng cách check sự hiện diện của các marker files. Fragile, duplicate, khó mở rộng.

## Giải pháp

Thêm **1 file canonical per task**: `<tid>.status.json`. Ghi ở mọi terminal point trong `dispatch_task` (cả first_success và consensus path). Downstream chỉ cần đọc 1 file là biết chuyện gì đã xảy ra.

**Không xóa** các marker files hiện có — giữ backward compat.

## Schema (stable v1)

```json
{
  "schema_version": 1,
  "task_id": "smoke-7.1d-001",
  "task_type": "design_api",
  "strategy_used": "consensus_exhausted",
  "final_state": "exhausted",
  "output_file": "smoke-7.1d-001.out",
  "output_bytes": 147246,
  "winner_agent": "merged",
  "candidates_tried": ["gemini-pro", "cc/claude-sonnet-4-6", "minimax-code"],
  "successful_candidates": ["gemini-pro", "minimax-code"],
  "consensus_score": 0.0,
  "reflexion_iterations": 2,
  "markers": [".exhausted"],
  "duration_sec": 128.4,
  "started_at": "2026-04-24T13:34:00Z",
  "completed_at": "2026-04-24T13:36:06Z"
}
```

### Enum values

| Field | Allowed values |
|---|---|
| `strategy_used` | `first_success`, `consensus`, `consensus_exhausted`, `cancelled`, `failed` |
| `final_state` | `done`, `exhausted`, `failed`, `cancelled`, `needs_revision` |
| `markers` | subset of `[".cancelled", ".failed", ".exhausted", ".needs_revision"]` |

### Field rules

- `output_bytes`: 0 if `.out` missing or empty
- `winner_agent`: `"merged"` cho consensus multi-winner, tên agent cho single-winner, `null` cho `failed`/`cancelled`
- `consensus_score`: 0.0 cho non-consensus path, float cho consensus path
- `reflexion_iterations`: count của `${tid}.v*.reflexion.json` trong `$REFLEXION_DIR` tại thời điểm terminal
- `duration_sec`: `completed_at - started_at`, float
- `candidates_tried` / `successful_candidates`: empty array nếu không phải consensus path

## Pre-baked decisions (đã chốt, không discuss lại)

1. **File location**: `$RESULTS_DIR/${tid}.status.json` (cạnh `.out`, `.consensus.json`).
2. **Write timing**: AT terminal state only — không partial writes, không live updates. Ghi atomically bằng `write to .tmp → mv .tmp .status.json` để reader không bao giờ thấy file truncated.
3. **Schema version**: hardcode `schema_version: 1`. Nếu cần v2 sau này thì bump + add migration logic. Không bắt đầu với flexible schema.
4. **Kill switch**: biến env `STATUS_JSON_DISABLED=1` → `write_task_status()` trở thành no-op. Useful cho rollback hoặc test isolation.
5. **Implementation style**: viết bằng `python3` heredoc (JSON construction), không `jq -n` (dễ sai quote). Pattern giống `write_consensus_json_exhausted` trong `bin/task-dispatch.sh:1167`.
6. **Lib location**: `lib/task-status.sh` (new file). Source'd by `task-dispatch.sh`. Stubbed (no-op) nếu file không có (graceful degrade).

## Implementation plan (6 bước)

### Step 1: Create `lib/task-status.sh`

```bash
#!/usr/bin/env bash
# task-status.sh — unified terminal-state JSON for every dispatched task
#
# Phase 8.1: Writes ${tid}.status.json atomically at terminal state.
# Single source of truth for downstream consumers (dashboards, metrics, inbox).
#
# NOTE: Do NOT use set -e in this file. Sourced by callers that manage errors.

# Kill switch: STATUS_JSON_DISABLED=1 → no-op
if [ "${STATUS_JSON_DISABLED:-0}" = "1" ]; then
  write_task_status() { return 0; }
  return 0 2>/dev/null || exit 0
fi

# write_task_status <tid> <json_blob>
#
# Atomic write: tmp file → rename.
# json_blob must already be a valid JSON string (caller builds it).
write_task_status() {
  local tid="$1"
  local json_blob="$2"
  local results_dir="${RESULTS_DIR:-.orchestration/results}"
  local out_path="$results_dir/${tid}.status.json"
  local tmp_path="$results_dir/.${tid}.status.json.tmp"

  mkdir -p "$results_dir"
  printf '%s' "$json_blob" > "$tmp_path" || return 1
  mv "$tmp_path" "$out_path"
}

# build_status_json — Python heredoc accepting CLI args, prints JSON to stdout.
# Fields order (positional): tid task_type strategy final_state output_file
#   output_bytes winner_agent candidates_tried_csv successful_candidates_csv
#   consensus_score reflexion_iterations markers_csv duration_sec started_at completed_at
#
# CSV fields: comma-separated, empty string → empty array.
build_status_json() {
  python3 - "$@" <<'PYEOF'
import sys, json
(_, tid, task_type, strategy, final_state, output_file, output_bytes,
 winner_agent, cand_csv, succ_csv, score, refl_iter, markers_csv,
 duration, started_at, completed_at) = sys.argv

def split_csv(s):
    return [t for t in s.split(",") if t]

obj = {
  "schema_version": 1,
  "task_id": tid,
  "task_type": task_type,
  "strategy_used": strategy,
  "final_state": final_state,
  "output_file": output_file,
  "output_bytes": int(output_bytes) if output_bytes else 0,
  "winner_agent": winner_agent if winner_agent else None,
  "candidates_tried": split_csv(cand_csv),
  "successful_candidates": split_csv(succ_csv),
  "consensus_score": float(score) if score else 0.0,
  "reflexion_iterations": int(refl_iter) if refl_iter else 0,
  "markers": split_csv(markers_csv),
  "duration_sec": float(duration) if duration else 0.0,
  "started_at": started_at,
  "completed_at": completed_at,
}
print(json.dumps(obj, indent=2))
PYEOF
}
```

### Step 2: Source it in `bin/task-dispatch.sh`

Thêm vào khu source block (quanh L30-42):

```bash
# shellcheck source=../lib/task-status.sh
if [ -f "$SCRIPT_DIR/../lib/task-status.sh" ]; then
  . "$SCRIPT_DIR/../lib/task-status.sh"
else
  write_task_status() { return 0; }
  build_status_json() { echo '{}'; }
fi
```

### Step 3: Hook into terminal points

**In `dispatch_task_consensus()`** — có 4 terminal paths, mỗi path write status với final_state khác:

| Path | Location (approx) | final_state | strategy_used |
|---|---|---|---|
| No survivors + exhausted (v2) | ~L980 | `failed` | `failed` |
| Single candidate success | ~L1027 | `done` | `consensus` |
| Multi-candidate merged success | ~L1129 | `done` | `consensus` |
| Disagreement + exhausted (v2) | ~L1090 (fix vừa commit) | `exhausted` | `consensus_exhausted` |

Cho mỗi path: ngay trước `return 0` / `return 1`, build json và gọi `write_task_status`. Pattern:

```bash
local _status_json _markers=""
[ -f "$RESULTS_DIR/${tid}.exhausted" ] && _markers="${_markers}.exhausted,"
[ -f "$RESULTS_DIR/${tid}.failed" ] && _markers="${_markers}.failed,"
[ -f "$RESULTS_DIR/${tid}.needs_revision" ] && _markers="${_markers}.needs_revision,"
_markers="${_markers%,}"

local _cand_csv _succ_csv
_cand_csv=$(IFS=,; echo "${candidates_list[*]}")
_succ_csv=$(IFS=,; echo "${successful_candidates[*]:-}")

local _output_bytes=0
[ -f "$RESULTS_DIR/${tid}.out" ] && \
  _output_bytes=$(wc -c < "$RESULTS_DIR/${tid}.out" | tr -d ' ')

local _refl_iter
_refl_iter=$(consensus_iteration_count "$tid")

local _completed_at
_completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

_status_json=$(build_status_json \
  "$tid" "$task_type" "<strategy>" "<final_state>" "${tid}.out" \
  "$_output_bytes" "<winner>" "$_cand_csv" "$_succ_csv" \
  "<score>" "$_refl_iter" "$_markers" \
  "<duration>" "${_started_at:-}" "$_completed_at")
write_task_status "$tid" "$_status_json"
```

Lưu ý: cần record `_started_at` ở đầu `dispatch_task_consensus` để tính `duration_sec`.

**In `dispatch_task_first_success()`** — có 3 terminal paths (success, cancelled, failed). Cùng pattern, nhưng:
- `candidates_tried` = danh sách agent thử (failover order)
- `successful_candidates` = single element (winner) hoặc empty
- `consensus_score` = 0.0
- `strategy_used` = `first_success` / `cancelled` / `failed`
- `reflexion_iterations` = count của `${tid}.v*.reflexion.json` (same count function)

### Step 4: Write test — `bin/test-task-status.sh`

4 scenarios, mỗi cái dispatch 1 task + assert `.status.json` tồn tại + schema đúng:

```
Test 1: first_success path → final_state=done, strategy=first_success
Test 2: consensus success → final_state=done, strategy=consensus, cand=3, succ>=1
Test 3: consensus exhausted → final_state=exhausted, strategy=consensus_exhausted, markers contains .exhausted
Test 4: consensus no_survivors → final_state=failed, strategy=failed, markers contains .failed
```

Mỗi test: parse `.status.json` bằng `python3 -c "import json; d=json.load(open(...)); assert d['schema_version']==1; ..."`.

Thêm: **Test 5** — `STATUS_JSON_DISABLED=1` → no `.status.json` written (kill switch works).

### Step 5: Smoke test trên data thật

Chạy 1 consensus task thật (mock agents), verify `.status.json` sinh ra đúng schema. Diff với existing `.consensus.json` để đảm bảo không miss field nào.

### Step 6: Update WORK.md + docs

- Mark 8.1 DONE trong WORK.md Active section
- Thêm note trong `docs/` (hoặc inline comment) về schema v1
- Optional: short Markdown table in commit message summarizing 4 terminal paths

## Acceptance criteria

- [ ] `lib/task-status.sh` tồn tại, source'd bởi `task-dispatch.sh`
- [ ] Cả 4 consensus terminal paths ghi `.status.json` với schema v1 đúng
- [ ] Cả 3 first_success terminal paths ghi `.status.json`
- [ ] Atomic write (tmp + rename) — không có partial files
- [ ] `STATUS_JSON_DISABLED=1` tắt được (kill switch)
- [ ] `bin/test-task-status.sh`: 5/5 PASS
- [ ] No regression: `bin/test-consensus.sh` 11/11, `bin/test-consensus-dispatch.sh` 10/10
- [ ] Smoke test 1 real dispatch: `.status.json` sinh ra, parse được bằng `python3 -c "import json; json.load(open(...))"`
- [ ] Backward compat: existing markers (`.exhausted`, `.failed`, `.out`, `.consensus.json`) vẫn được ghi

## Constraints

- **KHÔNG** xóa/modify existing marker files — only ADD `.status.json`.
- **KHÔNG** thay đổi `.out` format hoặc `.consensus.json` format.
- **KHÔNG** thêm deps mới (không mới yq/jq usage nếu không cần — đã có).
- **KHÔNG** dùng `set -e` trong `lib/task-status.sh` (sourced lib convention).
- Bash 3.2 compat cho stub (`write_task_status() { return 0; }` nếu source fail).
- Viết inline comment tiếng Anh; commit message có thể tiếng Anh hoặc Việt.

## Rollback plan

1 line: export `STATUS_JSON_DISABLED=1` trong `.env` hoặc inline trước `task-dispatch.sh`. Mọi path trở về không write `.status.json`. Existing markers không đổi nên downstream legacy không break.

Full revert: `git revert <8.1 commit>` — removes lib + source line + test. Nothing else depends on it yet (8.2 là phase sau).

## Deliverable checklist

- [ ] `lib/task-status.sh` (~60 lines)
- [ ] `bin/task-dispatch.sh` edits (source + 7 terminal-point writes)
- [ ] `bin/test-task-status.sh` (~150 lines, 5 tests)
- [ ] WORK.md update: 8.1 moved to Archive with commit hash
- [ ] Commit message: `Phase 8.1: unified task status JSON — <tid>.status.json canonical terminal state`

## Out of scope (cho phase sau)

- 8.2: `bin/orch-metrics.sh` reads `.status.json` for rollup → DO NOT ship trong PR này
- 8.3: Dashboard rewrite → phase sau
- 8.4: Lib audit + registry.yaml → phase sau
- Schema migrations (v2) → chưa cần, v1 đủ
- Inbox MCP migration to `.status.json` → opt-in sau khi 8.1 ổn định

## Reference files

- `bin/task-dispatch.sh` L781-1131 (dispatch_task_consensus, 7.1b-d)
- `bin/task-dispatch.sh` L1206-1220 (dispatch_task router, 7.1b)
- `bin/task-dispatch.sh` L1167-1181 (write_consensus_json_exhausted, pattern reference)
- `lib/consensus-vote.sh` (7.1a-d)
- `lib/quality-gate.sh` L57-121 (trigger_reflexion, sibling lib reference)
- `docs/DESIGN_consensus_7.1b.md` (format reference for this prompt)

---

Khi hoàn thành, trả lời với:
1. Commit hash
2. Tests output (last 20 lines mỗi file)
3. Sample `.status.json` dán vào reply
4. Smoke test result
