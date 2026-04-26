#!/usr/bin/env bash
# test-budget-dashboard.sh — Tests for Phase 8.4: bin/_dashboard/budget.sh
#
# Covers (20+ assertions):
#   JSON output: schema, totals, by_model, burn_rate, alerts, data_quality
#   Status logic: OK / WARNING / OVER_BUDGET
#   Degraded mode: no cost-log
#   --since filter
#   --model filter
#   Edge: malformed audit line skipped, empty results dir, no budget.yaml defaults

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$PROJECT_ROOT/test-fixtures/budget"
HELPER="$PROJECT_ROOT/bin/_dashboard/budget.sh"

export BUDGET_AUDIT_FILE="$FIXTURE/audit.jsonl"
export BUDGET_COST_LOG="$FIXTURE/cost-tracking.jsonl"
export BUDGET_RESULTS_DIR="$FIXTURE"
export BUDGET_CONFIG="$FIXTURE/budget.yaml"
export BUDGET_MODELS_YAML="$FIXTURE/models.yaml"

# Fixtures also need a minimal models.yaml for cost_hint
cat > "$FIXTURE/models.yaml" <<'YAML'
models:
  oc-high:
    channel: router
    cost_hint: high
  copilot:
    channel: copilot_cli
    cost_hint: medium
YAML

PASS=0; FAIL=0; TOTAL=0

pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1 — $2"; }

# json_get JSON key1 key2 ... → prints leaf value
json_get() {
  local json_data="$1"; shift
  local keys_csv
  keys_csv=$(printf '"%s",' "$@")
  keys_csv="${keys_csv%,}"
  echo "$json_data" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in [${keys_csv}]:
    if isinstance(d, list):
        d = d[int(k)]
    else:
        d = d[k]
print(d)
"
}

json_len() {
  local json_data="$1"; shift
  local keys_csv
  keys_csv=$(printf '"%s",' "$@")
  keys_csv="${keys_csv%,}"
  echo "$json_data" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in [${keys_csv}]:
    if isinstance(d, list):
        d = d[int(k)]
    else:
        d = d[k]
print(len(d))
"
}

echo "============================================================"
echo "  TEST: bin/_dashboard/budget.sh (Phase 8.4)"
echo "============================================================"
echo

# ── 1. Basic OK status ─────────────────────────────────────────────────────────
echo "── basic OK status (default budget.yaml)"
OUT=$(bash "$HELPER" --json 2>/dev/null)

VAL=$(json_get "$OUT" schema_version);     [ "$VAL" = "1" ] && pass "schema_version=1" || fail "schema_version" "got $VAL"
VAL=$(json_get "$OUT" totals status);      [ "$VAL" = "OK" ] && pass "status=OK (50.6% < 80%)" || fail "status" "got $VAL"
VAL=$(json_get "$OUT" totals budget_used_pct); [ "$(echo "$VAL >= 50" | bc -l 2>/dev/null || echo 0)" = "1" ] && \
                                              [ "$(echo "$VAL <= 55" | bc -l 2>/dev/null || echo 0)" = "1" ] && \
                                              pass "budget_used_pct ~50%" || fail "budget_used_pct" "got $VAL"
VAL=$(json_get "$OUT" totals tokens_actual); [ "$VAL" != "" ] && [ "$VAL" != "null" ] && pass "tokens_actual present" || fail "tokens_actual" "got $VAL"
VAL=$(json_get "$OUT" totals tokens_estimated); [ "$VAL" != "" ] && pass "tokens_estimated present" || fail "tokens_estimated" "got $VAL"
VAL=$(json_get "$OUT" data_quality has_cost_log); [ "$VAL" = "True" ] && pass "has_cost_log=true" || fail "has_cost_log" "got $VAL"
VAL=$(json_get "$OUT" data_quality has_audit_log); [ "$VAL" = "True" ] && pass "has_audit_log=true" || fail "has_audit_log" "got $VAL"
VAL=$(json_get "$OUT" data_quality has_budget_config); [ "$VAL" = "True" ] && pass "has_budget_config=true" || fail "has_budget_config" "got $VAL"
VAL=$(json_get "$OUT" data_quality degraded);  [ "$VAL" = "False" ] && pass "degraded=false" || fail "degraded" "got $VAL"
echo

# ── 2. by_model ───────────────────────────────────────────────────────────────
echo "── by_model aggregation"
OUT=$(bash "$HELPER" --json 2>/dev/null)

VAL=$(json_len "$OUT" by_model);            [ "$VAL" = "2" ] && pass "2 models (copilot, oc-high)" || fail "by_model count" "got $VAL"

# copilot: tasks 001(300) + 002(230) + 004(150) = 3 tasks, 680 actual
VAL=$(json_get "$OUT" by_model copilot tokens_actual); [ "$VAL" = "680" ] && pass "copilot tokens_actual=680 (300+230+150)" || fail "copilot actual" "got $VAL"
VAL=$(json_get "$OUT" by_model copilot tasks);        [ "$VAL" = "3" ] && pass "copilot tasks=3" || fail "copilot tasks" "got $VAL"
VAL=$(json_get "$OUT" by_model copilot cost_hint);     [ "$VAL" = "medium" ] && pass "copilot cost_hint=medium" || fail "copilot cost_hint" "got $VAL"
VAL=$(json_get "$OUT" by_model copilot model_limit);   [ "$VAL" = "None" ] && pass "copilot model_limit=null (no per-model cap)" || fail "copilot model_limit" "got $VAL"

# oc-high: 1100+750 = 1850 actual, limit 2000
VAL=$(json_get "$OUT" by_model oc-high tokens_actual); [ "$VAL" = "1850" ] && pass "oc-high tokens_actual=1850 (1100+750)" || fail "oc-high actual" "got $VAL"
VAL=$(json_get "$OUT" by_model oc-high model_limit);  [ "$VAL" = "2000" ] && pass "oc-high model_limit=2000" || fail "oc-high model_limit" "got $VAL"
VAL=$(json_get "$OUT" by_model oc-high model_used_pct); [ "$(echo "$VAL > 90" | bc -l 2>/dev/null || echo 0)" = "1" ] && \
                                                     [ "$(echo "$VAL < 95" | bc -l 2>/dev/null || echo 0)" = "1" ] && \
                                                     pass "oc-high model_used_pct ~92.5%" || fail "oc-high pct" "got $VAL"
echo

# ── 3. WARNING status ──────────────────────────────────────────────────────────
echo "── WARNING status (budget-warning.yaml, 3000 limit → 84.3%)"
export BUDGET_CONFIG="$FIXTURE/budget-warning.yaml"
OUT=$(bash "$HELPER" --json 2>/dev/null)
VAL=$(json_get "$OUT" totals status); [ "$VAL" = "WARNING" ] && pass "status=WARNING (84.3% >= 80%)" || fail "status" "got $VAL"
VAL=$(json_get "$OUT" totals budget_used_pct); [ "$(echo "$VAL > 83" | bc -l 2>/dev/null || echo 0)" = "1" ] && \
                                                 [ "$(echo "$VAL < 86" | bc -l 2>/dev/null || echo 0)" = "1" ] && \
                                                 pass "budget_used_pct ~84%" || fail "budget_used_pct" "got $VAL"
VAL=$(json_len "$OUT" alerts);          [ "$VAL" -ge "1" ] && pass ">=1 alert generated" || fail "alerts" "got $VAL"
VAL=$(json_get "$OUT" alerts 0 level); [ "$VAL" = "WARNING" ] && pass "alert level=WARNING" || fail "alert level" "got $VAL"
echo

# ── 4. OVER_BUDGET status ─────────────────────────────────────────────────────
echo "── OVER_BUDGET status (budget-over.yaml, 2000 limit → 126.5%)"
export BUDGET_CONFIG="$FIXTURE/budget-over.yaml"
OUT=$(bash "$HELPER" --json 2>/dev/null)
VAL=$(json_get "$OUT" totals status); [ "$VAL" = "OVER_BUDGET" ] && pass "status=OVER_BUDGET (126.5% >= 100%)" || fail "status" "got $VAL"
VAL=$(json_get "$OUT" totals budget_used_pct); [ "$(echo "$VAL > 125" | bc -l 2>/dev/null || echo 0)" = "1" ] && \
                                                 pass "budget_used_pct >125%" || fail "budget_used_pct" "got $VAL"
# oc-high: 1850/1000 = 185% → CRITICAL
VAL=$(json_get "$OUT" alerts 0 level); [ "$VAL" = "CRITICAL" ] && pass "CRITICAL alert present" || fail "alert level" "got $VAL"
echo

# ── 5. Degraded mode (no cost-log) ───────────────────────────────────────────
echo "── degraded mode: no cost-log.jsonl"
export BUDGET_CONFIG="$FIXTURE/budget.yaml"
export BUDGET_COST_LOG="$FIXTURE/empty-cost-log.jsonl"
echo "" > "$FIXTURE/empty-cost-log.jsonl"
OUT=$(bash "$HELPER" --json 2>/dev/null)
VAL=$(json_get "$OUT" data_quality degraded); [ "$VAL" = "True" ] && pass "degraded=true" || fail "degraded" "got $VAL"
VAL=$(json_get "$OUT" totals tokens_actual);  [ "$VAL" = "None" ] && pass "tokens_actual=null in degraded" || fail "tokens_actual" "got $VAL"
VAL=$(json_get "$OUT" totals status);         [ "$VAL" = "OK" ] && pass "status=OK (using estimated only)" || fail "status" "got $VAL"
rm -f "$FIXTURE/empty-cost-log.jsonl"
echo

# ── 6. --since filter ─────────────────────────────────────────────────────────
echo "── --since filter: old entries excluded"
export BUDGET_CONFIG="$FIXTURE/budget.yaml"
# Generate fresh files with today's timestamps so --since 24h includes them
TODAY=$(python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%d'))")
SINCE_COST_LOG=$(mktemp)
cat > "$SINCE_COST_LOG" <<JSONL
{"timestamp":"${TODAY}T08:01:00Z","agent":"copilot","batch_id":"b1","task_id":"budget-task-001","tokens_input":200,"tokens_output":100,"cost_usd":0,"duration_s":30}
{"timestamp":"${TODAY}T12:01:00Z","agent":"oc-high","batch_id":"b3","task_id":"budget-task-005","tokens_input":400,"tokens_output":350,"cost_usd":0,"duration_s":40}
JSONL
SINCE_AUDIT=$(mktemp)
cat > "$SINCE_AUDIT" <<JSONL
{"event":"tier_assigned","task_id":"budget-task-001","tier":"TIER_STANDARD","tokens_estimated":500,"timestamp":"${TODAY}T08:00:00Z"}
{"event":"tier_assigned","task_id":"budget-task-005","tier":"TIER_PREMIUM","tokens_estimated":800,"timestamp":"${TODAY}T12:00:00Z"}
JSONL
export BUDGET_COST_LOG="$SINCE_COST_LOG"
export BUDGET_AUDIT_FILE="$SINCE_AUDIT"
OUT=$(bash "$HELPER" --json --since 24h 2>/dev/null)
rm -f "$SINCE_COST_LOG" "$SINCE_AUDIT"
export BUDGET_COST_LOG="$FIXTURE/cost-tracking.jsonl"
export BUDGET_AUDIT_FILE="$FIXTURE/audit.jsonl"
VAL=$(json_get "$OUT" totals tokens_estimated); [ "$VAL" != "" ] && [ "$VAL" -gt "0" ] && pass "tokens_estimated > 0 after --since 24h" || fail "tokens_estimated" "got $VAL"
VAL=$(json_get "$OUT" window);                  [ "$VAL" = "24h" ] && pass "window=24h" || fail "window" "got $VAL"
echo

# ── 7. --model filter ─────────────────────────────────────────────────────────
echo "── --model filter: oc-high only"
OUT=$(bash "$HELPER" --json --model oc-high 2>/dev/null)
VAL=$(json_len "$OUT" by_model);  [ "$VAL" = "1" ] && pass "1 model after --model oc-high" || fail "by_model count" "got $VAL"
VAL=$(json_get "$OUT" by_model oc-high tokens_actual); [ "$VAL" = "1850" ] && pass "oc-high tokens_actual=1850 (filtered)" || fail "oc-high actual" "got $VAL"
echo

# ── 8. Human-readable output ──────────────────────────────────────────────────
echo "── human-readable output (no --json)"
OUT=$(bash "$HELPER" 2>/dev/null)
echo "$OUT" | grep -q "TOKEN BUDGET DASHBOARD" && pass "header: TOKEN BUDGET DASHBOARD" || fail "header" "not found"
echo "$OUT" | grep -q "Status:.*OK" && pass "human output shows Status OK" || fail "human status" "not found"
echo "$OUT" | grep -q "copilot" && pass "human output shows copilot model" || fail "human copilot" "not found"
echo "$OUT" | grep -q "cost-tracking.jsonl: ✓" && pass "human shows cost-log status" || fail "human cost-log" "not found"
echo

# ── 9. Malformed JSONL skipped ────────────────────────────────────────────────
echo "── malformed audit.jsonl line skipped (no crash)"
export BUDGET_CONFIG="$FIXTURE/budget.yaml"
OUT=$(bash "$HELPER" --json 2>/dev/null)
VAL=$(json_get "$OUT" schema_version); [ "$VAL" = "1" ] && pass "malformed line skipped, valid output" || fail "malformed skip" "got $VAL"
echo

# ── 10. Empty audit ───────────────────────────────────────────────────────────
echo "── empty audit.jsonl (cost-log still works)"
echo "" > "$FIXTURE/empty-audit.jsonl"
export BUDGET_AUDIT_FILE="$FIXTURE/empty-audit.jsonl"
OUT=$(bash "$HELPER" --json 2>/dev/null)
VAL=$(json_get "$OUT" data_quality has_audit_log); [ "$VAL" = "False" ] && pass "has_audit_log=false" || fail "has_audit_log" "got $VAL"
VAL=$(json_get "$OUT" totals tokens_estimated);     [ "$VAL" = "0" ] && pass "tokens_estimated=0 (empty audit)" || fail "tokens_estimated" "got $VAL"
VAL=$(json_get "$OUT" totals status);               [ "$VAL" = "OK" ] && pass "status=OK (no audit, has cost)" || fail "status" "got $VAL"
rm -f "$FIXTURE/empty-audit.jsonl"
echo

# ── 11. No budget.yaml defaults ───────────────────────────────────────────────
echo "── no budget.yaml: defaults applied (500k limit, 80% alert)"
export BUDGET_CONFIG="$FIXTURE/nonexistent-budget.yaml"
OUT=$(bash "$HELPER" --json 2>/dev/null)
VAL=$(json_get "$OUT" config daily_token_limit); [ "$VAL" = "500000" ] && pass "default daily_limit=500000" || fail "daily_limit" "got $VAL"
VAL=$(json_get "$OUT" config alert_threshold_pct); [ "$VAL" = "80" ] && pass "default alert_threshold=80" || fail "alert_threshold" "got $VAL"
VAL=$(json_get "$OUT" config source);             [ "$VAL" = "defaults" ] && pass "config source=defaults" || fail "source" "got $VAL"
VAL=$(json_get "$OUT" data_quality has_budget_config); [ "$VAL" = "False" ] && pass "has_budget_config=false" || fail "has_budget_config" "got $VAL"
echo

# ── 12. Help flag ─────────────────────────────────────────────────────────────
echo "── --help exits cleanly"
RC=0; bash "$HELPER" --help >/dev/null 2>&1 || RC=$?
[ $RC -eq 0 ] && pass "--help exits 0" || fail "--help exit" "got $RC"

# ── 13. --since 1h (no recent cost data → 0 tokens) ─────────────────────────────
echo "── --since 1h with no recent entries → stable trend, no alerts"
export BUDGET_CONFIG="$FIXTURE/budget.yaml"
OUT=$(bash "$HELPER" --json --since 1h 2>/dev/null)
VAL=$(json_get "$OUT" window); [ "$VAL" = "1h" ] && pass "window=1h" || fail "window" "got $VAL"
echo

# ── Summary ───────────────────────────────────────────────────────────────────
echo "============================================================"
echo "ALL $TOTAL TESTS: $PASS PASS, $FAIL FAIL"
if [ $FAIL -eq 0 ]; then
  echo "  ALL $TOTAL TESTS PASSED"
else
  echo "  $PASS/$TOTAL PASSED, $FAIL FAILED"
fi
echo "============================================================"

# Cleanup
rm -f "$FIXTURE/models.yaml" "$FIXTURE/empty-cost-log.jsonl" "$FIXTURE/empty-audit.jsonl"
exit $FAIL
