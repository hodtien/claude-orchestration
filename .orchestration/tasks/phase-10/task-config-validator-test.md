---
id: config-validator-test-001
agent: claude-review
timeout: 400
retries: 1
task_type: write_tests
depends_on: [config-validator-001]
read_files: [lib/config-validator.sh, config/models.yaml, config/budget.yaml, config/agents.json, bin/test-react-loop.sh]
---

# Task: Phase 10.3 Config validator test suite

## Objective
Create `bin/test-config-validator.sh` — test suite for `lib/config-validator.sh`.

## Patterns to follow

Follow `bin/test-react-loop.sh` exactly. No real agent dispatch. No network calls.

## Test setup

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PROJECT_ROOT/lib/config-validator.sh"
MODELS="$PROJECT_ROOT/config/models.yaml"
BUDGET="$PROJECT_ROOT/config/budget.yaml"
AGENTS="$PROJECT_ROOT/config/agents.json"
TMPTEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT
```

## Test cases (30)

### Group 1: Library structure (4)
1. `lib/config-validator.sh exists`
2. `source has zero side effects`
3. `double source ok`
4. `no jq/bc dependencies`

### Group 2: models.yaml — good (4)
5. `real models.yaml passes`
6. `validate_models_yaml returns 0`
7. `valid file with parallel_policy accepted`
8. `valid file with fallback accepted`

### Group 3: models.yaml — bad (6)
9. `missing default_model fails`
10. `missing task_routing fails`
11. `task_type without model fails`
12. `parallel_policy with <2 models fails`
13. `parallel_policy with bad strategy fails`
14. `nonexistent file returns exit 2`

### Group 4: budget.yaml — good (3)
15. `real budget.yaml passes`
16. `validate_budget_yaml returns 0`
17. `valid budget with multiple cost entries accepted`

### Group 5: budget.yaml — bad (4)
18. `negative budget_limit_tokens fails`
19. `alert_threshold_pct > 100 fails`
20. `missing cost_per_1k_tokens fails`
21. `non-numeric cost entry fails`

### Group 6: agents.json (4)
22. `real agents.json passes`
23. `agent without name fails`
24. `non-array JSON fails`
25. `invalid JSON fails`

### Group 7: validate_all_configs (3)
26. `passes with real config files`
27. `--strict stops on first error`
28. `standalone CLI mode works`

### Group 8: Error output format (2)
29. `error output has [ERROR] prefix`
30. `valid output has [OK] prefix`

## Bad fixture creation

```bash
# Bad models.yaml — missing default_model
cat > "$TMPTEST_DIR/bad-models.yaml" <<'EOF'
task_routing:
  quick_answer:
    model: oc-low
EOF

# Bad budget.yaml — negative limit
cat > "$TMPTEST_DIR/bad-budget.yaml" <<'EOF'
budget_limit_tokens: -100
alert_threshold_pct: 50
cost_per_1k_tokens:
  oc-medium: 0.003
tracking_enabled: true
EOF

# Bad agents.json — missing name
cat > "$TMPTEST_DIR/bad-agents.json" <<'EOF'
[{"type": "cli"}]
EOF
```

## Final block

```bash
echo
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

## Acceptance criteria

- All 30 assertions pass
- Isolated temp state for bad fixtures
- Real config files validated as good
- Bad fixtures produce clear errors
- No real agent or network calls
