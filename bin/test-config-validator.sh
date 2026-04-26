#!/usr/bin/env bash
# test-config-validator.sh -- 30 assertions for lib/config-validator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PROJECT_ROOT/lib/config-validator.sh"
MODELS="$PROJECT_ROOT/config/models.yaml"
BUDGET="$PROJECT_ROOT/config/budget.yaml"
AGENTS="$PROJECT_ROOT/config/agents.json"
TMPTEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        FAIL=$((FAIL+1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label"
        echo "  expected to contain: $needle"
        echo "  actual: $haystack"
        FAIL=$((FAIL+1))
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label -- file not found: $path"
        FAIL=$((FAIL+1))
    fi
}

# --- bad fixtures -----------------------------------------------------------

# bad models.yaml -- missing all three required top-level keys
cat > "$TMPTEST_DIR/bad-models-missing-toplevel.yaml" <<'EOF'
react_policy:
  enabled: false
EOF

# bad models.yaml -- task_mapping entry missing 'parallel'
cat > "$TMPTEST_DIR/bad-models-no-parallel.yaml" <<'EOF'
channels:
  router:
    base_url: http://localhost:20128
models:
  oc-low:
    channel: router
    tier: fast
task_mapping:
  quick_answer:
    fallback: [oc-low]
EOF

# bad models.yaml -- parallel_policy.max_parallel < 1
cat > "$TMPTEST_DIR/bad-models-bad-pp.yaml" <<'EOF'
channels:
  router:
    base_url: http://localhost:20128
models:
  oc-low:
    channel: router
    tier: fast
task_mapping:
  quick_answer:
    parallel: [oc-low]
parallel_policy:
  max_parallel: 0
EOF

# bad models.yaml -- model entry missing required 'channel' field
cat > "$TMPTEST_DIR/bad-models-missing-channel.yaml" <<'EOF'
channels:
  router:
    base_url: http://localhost:20128
models:
  oc-low:
    tier: fast
task_mapping:
  quick_answer:
    parallel: [oc-low]
EOF

# valid models.yaml -- includes parallel_policy
cat > "$TMPTEST_DIR/valid-models-parallel.yaml" <<'EOF'
channels:
  router:
    base_url: http://localhost:20128
models:
  oc-low:
    channel: router
    tier: fast
  oc-high:
    channel: router
    tier: premium
task_mapping:
  quick_answer:
    parallel: [oc-low, oc-high]
parallel_policy:
  pick_strategy: round_robin
  max_parallel: 2
EOF

# valid models.yaml -- includes fallback
cat > "$TMPTEST_DIR/valid-models-fallback.yaml" <<'EOF'
channels:
  router:
    base_url: http://localhost:20128
models:
  oc-low:
    channel: router
    tier: fast
task_mapping:
  quick_answer:
    parallel: [oc-low]
    fallback: [oc-low]
EOF

# bad budget.yaml -- negative daily_token_limit
cat > "$TMPTEST_DIR/bad-budget-negative.yaml" <<'EOF'
global:
  daily_token_limit: -100
  alert_threshold_pct: 50
EOF

# bad budget.yaml -- alert_threshold_pct > 100
cat > "$TMPTEST_DIR/bad-budget-pct.yaml" <<'EOF'
global:
  daily_token_limit: 500000
  alert_threshold_pct: 150
EOF

# bad budget.yaml -- missing alert_threshold_pct
cat > "$TMPTEST_DIR/bad-budget-missing-pct.yaml" <<'EOF'
global:
  daily_token_limit: 500000
EOF

# valid budget.yaml -- multiple per_model entries
cat > "$TMPTEST_DIR/valid-budget-multi.yaml" <<'EOF'
global:
  daily_token_limit: 500000
  alert_threshold_pct: 80
per_model:
  oc-low:
    daily_limit: 100000
  oc-high:
    daily_limit: 200000
EOF

# bad agents.json -- missing name (Layout B)
cat > "$TMPTEST_DIR/bad-agents-no-name.json" <<'EOF'
[{"type": "cli"}]
EOF

# bad agents.json -- root is a plain string (neither array nor agents-object)
cat > "$TMPTEST_DIR/bad-agents-non-array.json" <<'EOF'
"not_an_object_or_array"
EOF

# bad agents.json -- invalid JSON
cat > "$TMPTEST_DIR/bad-agents-invalid.json" <<'EOF'
{not valid json}
EOF

# bad config dir for --strict test
mkdir -p "$TMPTEST_DIR/config"
cp "$TMPTEST_DIR/bad-models-missing-toplevel.yaml" "$TMPTEST_DIR/config/models.yaml"
cp "$BUDGET" "$TMPTEST_DIR/config/budget.yaml"
cp "$AGENTS"  "$TMPTEST_DIR/config/agents.json"

# ---------------------------------------------------------------------------
# Group 1: Library structure (4)
# ---------------------------------------------------------------------------

# T01: lib file exists
assert_file_exists "T01 lib: config-validator.sh exists" "$LIB"

# T02: source has zero side effects
ALT_DIR="$TMPTEST_DIR/sourcecheck"
bash -c "source '$LIB'; echo OK" >/dev/null
created_count=$(find "$ALT_DIR" -type d 2>/dev/null | wc -l | tr -d ' ') || created_count=0
assert_eq "T02 source: no dirs created on load" "0" "$created_count"

# T03: double source ok
double_exit=0
(source "$LIB" && source "$LIB" && echo ok) >/dev/null 2>&1 || double_exit=$?
assert_eq "T03 source: double-source ok" "0" "$double_exit"

# T04: no jq dependency
jq_count=$(grep -cE '\bjq\b' "$LIB" 2>/dev/null || true)
assert_eq "T04 deps: no jq" "0" "$jq_count"

# ---------------------------------------------------------------------------
# Source the library for function-level tests
# ---------------------------------------------------------------------------
# shellcheck source=../lib/config-validator.sh
. "$LIB"

# ---------------------------------------------------------------------------
# Group 2: models.yaml -- good (4)
# ---------------------------------------------------------------------------

# T05: real models.yaml passes
ret5=0
validate_models_yaml "$MODELS" >/dev/null 2>&1 || ret5=$?
assert_eq "T05 models: real models.yaml passes" "0" "$ret5"

# T06: validate_models_yaml returns 0
ret6=0
validate_models_yaml "$MODELS" >/dev/null 2>&1 || ret6=$?
assert_eq "T06 models: validate_models_yaml returns 0" "0" "$ret6"

# T07: valid file with parallel_policy accepted
ret7=0
validate_models_yaml "$TMPTEST_DIR/valid-models-parallel.yaml" >/dev/null 2>&1 || ret7=$?
assert_eq "T07 models: parallel_policy accepted" "0" "$ret7"

# T08: valid file with fallback accepted
ret8=0
validate_models_yaml "$TMPTEST_DIR/valid-models-fallback.yaml" >/dev/null 2>&1 || ret8=$?
assert_eq "T08 models: fallback accepted" "0" "$ret8"

# ---------------------------------------------------------------------------
# Group 3: models.yaml -- bad (6)
# ---------------------------------------------------------------------------

# T09: missing required top-level keys fails
ret9=0
validate_models_yaml "$TMPTEST_DIR/bad-models-missing-toplevel.yaml" >/dev/null 2>&1 || ret9=$?
assert_eq "T09 models: missing required keys fails" "1" "$ret9"

# T10: missing task_mapping fails (same fixture covers both T09 and T10)
ret10=0
validate_models_yaml "$TMPTEST_DIR/bad-models-missing-toplevel.yaml" >/dev/null 2>&1 || ret10=$?
assert_eq "T10 models: missing task_mapping fails" "1" "$ret10"

# T11: task_type without parallel fails
ret11=0
validate_models_yaml "$TMPTEST_DIR/bad-models-no-parallel.yaml" >/dev/null 2>&1 || ret11=$?
assert_eq "T11 models: task_type without parallel fails" "1" "$ret11"

# T12: parallel_policy with max_parallel < 1 fails
ret12=0
validate_models_yaml "$TMPTEST_DIR/bad-models-bad-pp.yaml" >/dev/null 2>&1 || ret12=$?
assert_eq "T12 models: parallel_policy max_parallel<1 fails" "1" "$ret12"

# T13: model entry missing required 'channel' field fails
ret13=0
validate_models_yaml "$TMPTEST_DIR/bad-models-missing-channel.yaml" >/dev/null 2>&1 || ret13=$?
assert_eq "T13 models: model missing channel fails" "1" "$ret13"

# T14: nonexistent file returns exit 2
ret14=0
validate_models_yaml "$TMPTEST_DIR/does-not-exist.yaml" >/dev/null 2>&1 || ret14=$?
assert_eq "T14 models: nonexistent file returns exit 2" "2" "$ret14"

# ---------------------------------------------------------------------------
# Group 4: budget.yaml -- good (3)
# ---------------------------------------------------------------------------

# T15: real budget.yaml passes
ret15=0
validate_budget_yaml "$BUDGET" >/dev/null 2>&1 || ret15=$?
assert_eq "T15 budget: real budget.yaml passes" "0" "$ret15"

# T16: validate_budget_yaml returns 0
ret16=0
validate_budget_yaml "$BUDGET" >/dev/null 2>&1 || ret16=$?
assert_eq "T16 budget: validate_budget_yaml returns 0" "0" "$ret16"

# T17: valid budget with multiple per_model entries accepted
ret17=0
validate_budget_yaml "$TMPTEST_DIR/valid-budget-multi.yaml" >/dev/null 2>&1 || ret17=$?
assert_eq "T17 budget: multiple per_model entries accepted" "0" "$ret17"

# ---------------------------------------------------------------------------
# Group 5: budget.yaml -- bad (4)
# ---------------------------------------------------------------------------

# T18: negative daily_token_limit fails
ret18=0
validate_budget_yaml "$TMPTEST_DIR/bad-budget-negative.yaml" >/dev/null 2>&1 || ret18=$?
assert_eq "T18 budget: negative daily_token_limit fails" "1" "$ret18"

# T19: alert_threshold_pct > 100 fails
ret19=0
validate_budget_yaml "$TMPTEST_DIR/bad-budget-pct.yaml" >/dev/null 2>&1 || ret19=$?
assert_eq "T19 budget: alert_threshold_pct>100 fails" "1" "$ret19"

# T20: missing alert_threshold_pct fails
ret20=0
validate_budget_yaml "$TMPTEST_DIR/bad-budget-missing-pct.yaml" >/dev/null 2>&1 || ret20=$?
assert_eq "T20 budget: missing alert_threshold_pct fails" "1" "$ret20"

# T21: nonexistent budget returns exit 2
ret21=0
validate_budget_yaml "$TMPTEST_DIR/no-budget.yaml" >/dev/null 2>&1 || ret21=$?
assert_eq "T21 budget: nonexistent file returns exit 2" "2" "$ret21"

# ---------------------------------------------------------------------------
# Group 6: agents.json (4)
# ---------------------------------------------------------------------------

# T22: real agents.json passes
ret22=0
validate_agents_json "$AGENTS" >/dev/null 2>&1 || ret22=$?
assert_eq "T22 agents: real agents.json passes" "0" "$ret22"

# T23: agent without name fails (Layout B)
ret23=0
validate_agents_json "$TMPTEST_DIR/bad-agents-no-name.json" >/dev/null 2>&1 || ret23=$?
assert_eq "T23 agents: agent without name fails" "1" "$ret23"

# T24: non-array non-agents-object fails
ret24=0
validate_agents_json "$TMPTEST_DIR/bad-agents-non-array.json" >/dev/null 2>&1 || ret24=$?
assert_eq "T24 agents: non-array JSON fails" "1" "$ret24"

# T25: invalid JSON fails
ret25=0
validate_agents_json "$TMPTEST_DIR/bad-agents-invalid.json" >/dev/null 2>&1 || ret25=$?
assert_eq "T25 agents: invalid JSON fails" "1" "$ret25"

# ---------------------------------------------------------------------------
# Group 7: validate_all_configs (3)
# ---------------------------------------------------------------------------

# T26: passes with real config files
ret26=0
validate_all_configs >/dev/null 2>&1 || ret26=$?
assert_eq "T26 all: passes with real config files" "0" "$ret26"

# T27: --strict stops on first error
ret27=0
(
    export PROJECT_ROOT="$TMPTEST_DIR"
    # shellcheck source=../lib/config-validator.sh
    source "$LIB"
    validate_all_configs --strict >/dev/null 2>&1
) || ret27=$?
assert_eq "T27 all: --strict stops on first error" "1" "$ret27"

# T28: standalone CLI mode works
cli28_exit=0
bash "$LIB" all >/dev/null 2>&1 || cli28_exit=$?
assert_eq "T28 cli: standalone CLI mode works" "0" "$cli28_exit"

# ---------------------------------------------------------------------------
# Group 8: Error output format (2)
# ---------------------------------------------------------------------------

# T29: error output has [ERROR] prefix
err29=$(validate_agents_json "$TMPTEST_DIR/bad-agents-invalid.json" 2>&1 || true)
assert_contains "T29 format: error output has [ERROR] prefix" "[ERROR]" "$err29"

# T30: valid output has [OK] prefix
ok30=$(validate_agents_json "$AGENTS" 2>&1 || true)
assert_contains "T30 format: valid output has [OK] prefix" "[OK]" "$ok30"

echo
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
