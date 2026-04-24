# Phase 8.1 Fix-Pass — Complete the Cleanup

## Context

Bạn là agent được giao task sửa 3 lỗi trong commit `1ac531b` (Phase 8.1 cleanup) của project `claude-orchestration`. Commit này nhắm fix 2 issue nhưng:
- Fix chỉ áp dụng cho 1 trong 2 helper functions (half-applied)
- Một fix vô tình xóa dòng `local` declaration → gây regression dưới `set -u`
- Test coverage không catch được regression vì thiếu test first_success dispatch path

Đọc trước:
- `CLAUDE.md`, `WORK.md`
- `bin/task-dispatch.sh` L795-862 (2 helpers `_write_status_consensus` và `_write_status_first_success`)
- Review notes dưới đây để hiểu rõ từng lỗi

## 3 lỗi cần sửa

### 🔴 Bug 1 (REGRESSION — critical)

**Vị trí**: `_write_status_first_success` tại L836-862 của `bin/task-dispatch.sh`.

**Vấn đề**: Commit `1ac531b` xóa nguyên dòng:
```
local score="${9:-0.0}" refl_iter="${10:-0}" markers_csv="${11:-}"
```

Intent là chỉ xóa `markers_csv` (dead code) nhưng lỡ xóa cả `score` + `refl_iter` — 2 biến được DÙNG THỰC SỰ. Sau xóa, code tại L859-860 vẫn reference `"$score"` và `"${refl_iter:-0}"`.

**Hậu quả**: `task-dispatch.sh` có `set -euo pipefail` ở đầu (L1). Với `-u` (nounset), reference `"$score"` trên unset variable → **script exit 1 với "score: unbound variable"**.

**Repro**:
```bash
bash -c '
  set -euo pipefail
  source lib/task-status.sh
  # copy _write_status_first_success từ task-dispatch.sh L836-862
  _write_status_first_success() {
      local tid="$1" task_type="$2" strategy="$3" final_state="$4"
      local start_epoch="$5" winner="${6:-}" cand_csv="${7:-}" succ_csv="${8:-}"
      local _end_epoch _completed_at _started_at _duration _out_bytes _status_json
      _end_epoch=$(date -u "+%s")
      # ... (bỏ qua date lines)
      _status_json=$(build_status_json \
          "$tid" "$task_type" "$strategy" "$final_state" "${tid}.out" "0" \
          "${winner:-}" "${cand_csv:-}" "${succ_csv:-}" "$score" \
          "${refl_iter:-0}" "" "0" "ts" "ts")
  }
  _write_status_first_success t001 code_review first_success done 1000000 gemini-pro gemini-pro gemini-pro "0.0" "0" ""
'
# → "score: unbound variable" → exit 1
```

**Production impact**: Mọi non-consensus task (`implement_feature`, `code_review`, `quick_answer`, v.v. — tức đa số task) sẽ crash dispatcher khi đến terminal state write. Task vẫn có `.out` (write trước đó), nhưng dispatcher exit 1 + không cleanup + `.status.json` không tạo ra.

**Fix**: Restore chỉ 2 biến đúng (không restore `markers_csv`):

```diff
 _write_status_first_success() {
     local tid="$1" task_type="$2" strategy="$3" final_state="$4"
     local start_epoch="$5" winner="${6:-}" cand_csv="${7:-}" succ_csv="${8:-}"
+    local score="${9:-0.0}" refl_iter="${10:-0}"

     local _end_epoch _completed_at _started_at _duration
     local _out_bytes _status_json
```

Nhớ remove param `""` thừa ở L860 tại call `build_status_json`? KHÔNG — vẫn giữ, đó là positional slot cho `markers_csv` field trong schema v1 (không phải param helper). Xem L857-860:

```
_status_json=$(build_status_json \
    "$tid" "$task_type" "$strategy" "$final_state" "${tid}.out" "$_out_bytes" \
    "${winner:-}" "${cand_csv:-}" "${succ_csv:-}" "$score" \
    "${refl_iter:-0}" "" "$_duration" "$_started_at" "$_completed_at")
```

`""` ở đây là markers_csv argument (positional thứ 12) của `build_status_json` — cần để preserve JSON schema. Không đụng.

### 🔴 Bug 2 (Issue 1 incomplete)

**Vị trí**: `_write_status_consensus` L808-812.

**Vấn đề**: Commit message nói "Both helpers fixed" nhưng diff chỉ sửa first_success. Consensus helper vẫn GNU-only date:

```bash
# Code hiện tại (BUG trên macOS):
_end_epoch=$(date -u '+%s')
_completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' -d "@$_end_epoch" 2>/dev/null || \
  date -u '+%Y-%m-%dT%H:%M:%SZ')
_started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' -d "@$start_epoch" 2>/dev/null || \
  date -u '+%Y-%m-%dT%H:%M:%SZ')
```

`date -d "@<epoch>"` là GNU-only. Trên macOS (BSD date), command đầu fail, rơi vào fallback `date -u` không có epoch → trả về **current time** → `started_at == completed_at == "now"`.

**Hậu quả trên macOS**: Mọi consensus terminal state (architecture_analysis, security_audit, design_api) có timestamps sai. Linux CI xanh nhưng macOS production bug.

**Fix**: Apply cùng 3-fallback pattern như first_success đã fix (L846-851):

```diff
     _end_epoch=$(date -u '+%s')
-    _completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' -d "@$_end_epoch" 2>/dev/null || \
+    # macOS (BSD date): date -u -r <epoch>
+    # Linux (GNU date):   date -u -d "@<epoch>"
+    _completed_at=$(date -u -r "$_end_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
+      date -u -d "@$_end_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
       date -u '+%Y-%m-%dT%H:%M:%SZ')
-    _started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' -d "@$start_epoch" 2>/dev/null || \
+    _started_at=$(date -u -r "$start_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
+      date -u -d "@$start_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
       date -u '+%Y-%m-%dT%H:%M:%SZ')
```

### 🟡 Bug 3 (Issue 2 incomplete)

**Vị trí**: `_write_status_consensus` L803.

**Vấn đề**: Cleanup commit đã remove `markers_csv` khỏi first_success helper nhưng để lại trong consensus helper:

```bash
# Hiện tại (dead param):
local score="${9:-0.0}" refl_iter="${10:-0}" markers_csv="${11:-}"
```

Biến `markers_csv` declared nhưng không bao giờ dùng — L822-826 compute `_markers` fresh từ filesystem và overwrite. Cosmetic bug nhưng cần remove cho nhất quán.

**Fix**:

```diff
-    local score="${9:-0.0}" refl_iter="${10:-0}" markers_csv="${11:-}"
+    local score="${9:-0.0}" refl_iter="${10:-0}"
```

Header comment L799 đã update (xóa `[markers_csv]`), chỉ cần sửa code.

## Test gap — phải bổ sung

Hiện tại không có test nào exercise first_success dispatch terminal path. Bug 1 thoát qua test vì vậy. Thêm **Test 11** vào `bin/test-consensus-dispatch.sh`:

Chèn ngay trước khối `# ── Summary ─────` (khoảng L366 hoặc cuối Test 10):

```bash
# ── Test 11: first_success path produces .status.json ─────────────────────────
# Regression guard for fix-pass: `set -u` + unset score/refl_iter in
# _write_status_first_success would crash dispatcher silently.
echo ""
echo "Test 11: first_success dispatch writes .status.json (regression guard)"

setup_batch "test-first-success-status"
cat > "$BATCH_DIR/task-fs-001.md" <<'TASKEOF'
---
id: fs-status-001
agent: gemini-pro
task_type: implement_feature
---
Implement a foo() function.
TASKEOF

cat > "$BATCH_DIR/batch.conf" <<'CONFEOF'
failure_mode: skip-failed
CONFEOF

export MOCK_OUTPUT_gemini_pro="def foo():\n    pass"
export MOCK_EXIT_gemini_pro=0
export AGENT_SH_MOCK="$MOCK_AGENT"

rm -f "$RESULTS_DIR/fs-status-001.status.json" \
  "$RESULTS_DIR/fs-status-001.out" \
  "$RESULTS_DIR/fs-status-001.log" 2>/dev/null || true

bash "$BIN_DISPATCH" "$BATCH_DIR" --sequential 2>&1 > /tmp/dispatch-fs.$$.log || true
[[ "$VERBOSE" == "true" ]] && cat /tmp/dispatch-fs.$$.log
rm -f /tmp/dispatch-fs.$$.log

if [ -f "$RESULTS_DIR/fs-status-001.status.json" ]; then
  strategy=$(python3 -c "
import json
d=json.load(open('$RESULTS_DIR/fs-status-001.status.json'))
assert d['schema_version']==1
print(d['strategy_used'])
" 2>/dev/null || echo "?")
  if [[ "$strategy" == "first_success" ]]; then
    assert_pass "first_success .status.json written (strategy=$strategy)"
  else
    assert_fail "first_success: strategy was '$strategy', expected 'first_success'"
  fi
else
  assert_fail "first_success: .status.json missing" \
    "dispatcher may have crashed on set -u"
fi

# Cleanup
rm -f "$RESULTS_DIR/fs-status-001.status.json" \
  "$RESULTS_DIR/fs-status-001.out" \
  "$RESULTS_DIR/fs-status-001.log" \
  "$RESULTS_DIR/fs-status-001.report.json" 2>/dev/null || true
unset MOCK_OUTPUT_gemini_pro MOCK_EXIT_gemini_pro
```

**Kiểm tra thứ tự**: Test này phải chạy SAU Tests 1-10 (đã cleanup mocks). Nếu Test 10 leave state, thêm `unset` trước Test 11.

**Note**: `implement_feature` trong `config/models.yaml` không có `consensus: true` → sẽ rơi vào `dispatch_task_first_success` path. Verify bằng `yq -r ".task_mapping.implement_feature.consensus // false" config/models.yaml` (phải trả `false`).

## Pre-baked decisions

1. **Fix nhỏ gọn, 1 commit**. Không refactor, không đổi API, không thêm helper. Chỉ 3 diffs + 1 test block.
2. **Commit message**: `fix(8.1): complete cleanup — restore first_success locals, apply BSD date to consensus helper`
3. **KHÔNG** touch `lib/task-status.sh` — file này đúng rồi.
4. **KHÔNG** touch schema v1 — ổn định, không đổi field nào.
5. **KHÔNG** đổi signature `_write_status_*` — helper vẫn nhận 11 args (arg 11 chỉ bị ignore cho cả 2 helpers sau fix).

## Implementation checklist

- [ ] Sửa `bin/task-dispatch.sh` L803: xóa `markers_csv="${11:-}"` khỏi consensus helper
- [ ] Sửa `bin/task-dispatch.sh` L808-812: apply BSD → GNU → fallback date pattern cho consensus helper
- [ ] Sửa `bin/task-dispatch.sh` L836-838: add back `local score="${9:-0.0}" refl_iter="${10:-0}"` ở first_success helper
- [ ] Thêm Test 11 vào `bin/test-consensus-dispatch.sh` (ngay trước Summary section)
- [ ] Verify Test 11 cần yq + bash 4+ (kế thừa skip guards đã có đầu file — không cần thêm check)
- [ ] Chạy full test suite: `test-task-status.sh` 5/5, `test-consensus.sh` 11/11, `test-consensus-dispatch.sh` 11/11 (thêm 1)
- [ ] Smoke test: dispatch 1 task `implement_feature` với mock agent → verify `.status.json` sinh ra
- [ ] Cập nhật `WORK.md`: move archive entry "Phase 8.1 cleanup" sang kèm 2 commits (1ac531b + fix hash mới)

## Acceptance criteria

- [ ] Consensus helper (`_write_status_consensus`) và first_success helper (`_write_status_first_success`) đều có BSD → GNU → fallback date pattern
- [ ] Cả 2 helpers đều KHÔNG còn `markers_csv` param declaration
- [ ] first_success helper có `local score=...` và `local refl_iter=...` declarations (đủ đúng)
- [ ] Test 11 NEW: first_success dispatch → `.status.json` tồn tại với `strategy_used="first_success"`
- [ ] Run `bash bin/test-consensus-dispatch.sh` → **11/11 PASS** (thêm Test 11 so với 10 trước)
- [ ] Run `bash bin/test-task-status.sh` → 5/5 PASS (no regression)
- [ ] Run `bash bin/test-consensus.sh` → 11/11 PASS (no regression)
- [ ] `grep -n 'markers_csv' bin/task-dispatch.sh` → không còn match nào trong 2 helpers
- [ ] Repro script Bug 1 (xem phần Bug 1 phía trên) KHÔNG còn trả `unbound variable`

## Constraints

- **KHÔNG** xóa/modify existing marker files hoặc schema.
- **KHÔNG** thêm deps mới.
- **KHÔNG** dùng `set -e` trong `lib/task-status.sh`.
- Bash 3.2 compat: đã handled ở lib level, không cần đụng.
- Commit message tiếng Anh; inline comments tiếng Anh là preferred.
- Diff tổng ~15 dòng (3 fixes + test block ~50 dòng) — **very minimal PR**.

## Rollback plan

1 dòng: `git revert <fix commit>`. Trở về state 1ac531b (có regression và Issue 1/2 half-applied). Nếu revert, phải fallback về 7f59a73 (original 8.1 commit) để tránh regression on first_success.

Alternative: `export STATUS_JSON_DISABLED=1` — tắt status write hoàn toàn. Không address bug root nhưng unblock dispatcher trên macOS production.

## Out of scope

- Phase 8.2 (orch-metrics rollup) — đợi 8.1 hoàn toàn xanh mới bắt đầu
- Refactor hợp nhất 2 helpers thành 1 (tempting nhưng out of scope)
- Support subsecond duration precision (đã logged icebox)
- Cumulative duration across reflexion loop (đã logged icebox)

## Reference

- `bin/task-dispatch.sh` L795-862 (2 helpers)
- `bin/task-dispatch.sh` L1068, L1118, L1189, L1237 (consensus call sites — không sửa)
- `bin/task-dispatch.sh` L1721, L1796 (first_success call sites — không sửa)
- `lib/task-status.sh` (reference only, không sửa)
- Commit `1ac531b` (commit đang được fix)
- Commit `7f59a73` (commit 8.1 gốc — để tham chiếu nếu cần xem original declarations)

---

Khi hoàn thành, trả lời với:
1. Commit hash
2. Diff của fix (khoảng 15 dòng)
3. Output 3 test runs (last 10 lines mỗi file)
4. Output của `grep -n 'markers_csv' bin/task-dispatch.sh` (phải empty trong 2 helpers)
5. Output của repro Bug 1 (phải không còn "unbound variable" error)
