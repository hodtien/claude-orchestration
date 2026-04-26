---
id: config-validator-001
agent: oc-medium
reviewer: copilot
timeout: 600
retries: 1
task_type: implement_feature
depends_on: [verify-runner-001]
context_cache: [project-overview, architecture]
read_files: [config/models.yaml, config/budget.yaml, config/agents.json, bin/task-dispatch.sh, lib/react-loop.sh, lib/learning-engine.sh]
---

# Task: Phase 10.3 Config schema validation

## Objective
Create `lib/config-validator.sh` — validates `config/models.yaml`, `config/budget.yaml`, and `config/agents.json` structural correctness using python3 stdlib only. Bad configs fail early with clear errors.

## Existing config files

### `config/models.yaml`
- `default_model:` (string)
- `task_routing:` (map task_type → config object)
- Each task_type has: `model`, optional `parallel_policy`, `fallback`, `timeout_s`
- `parallel_policy`: `models` (list >= 2), `strategy` (first_success | consensus | fan_out), optional `threshold`

### `config/budget.yaml`
- `budget_limit_tokens:` (positive integer)
- `alert_threshold_pct:` (float 0-100)
- `cost_per_1k_tokens:` (map model → positive float)
- `tracking_enabled:` (boolean)

### `config/agents.json`
- JSON array of agent objects with `name` (non-empty) and `type`

## Design constraints

- bash 3.2 compatible
- Python3 stdlib only; no jq/yq/bc; PyYAML optional with regex fallback
- No source-time side effects
- Exit codes: 0 valid, 1 errors, 2 file not found
- Library + standalone CLI

## Deliverable: `lib/config-validator.sh`

### Public functions

#### `validate_models_yaml <filepath>`
Checks: file readable; `default_model` non-empty; `task_routing` present; each task_type has `model`; `parallel_policy.models` >= 2 items; `parallel_policy.strategy` in allowed set; `fallback` non-empty if present.

#### `validate_budget_yaml <filepath>`
Checks: `budget_limit_tokens` positive int; `alert_threshold_pct` 0-100 float; `cost_per_1k_tokens` non-empty map of positive floats; `tracking_enabled` boolean.

#### `validate_agents_json <filepath>`
Checks: valid JSON; is array; each entry has non-empty `name` + `type`.

#### `validate_all_configs [--strict]`
Runs all three against default paths. `--strict` exits on first error. Default paths under `$PROJECT_ROOT/config/`.

### Python YAML parsing

Try `import yaml`, fall back to a minimal regex parser for our flat/one-level structures (no anchors, no multi-line strings).

### Source guard / standalone CLI

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    models)  validate_models_yaml "${2:-$PROJECT_ROOT/config/models.yaml}" ;;
    budget)  validate_budget_yaml "${2:-$PROJECT_ROOT/config/budget.yaml}" ;;
    agents)  validate_agents_json "${2:-$PROJECT_ROOT/config/agents.json}" ;;
    all)     validate_all_configs "${@:2}" ;;
    *)       echo "Usage: config-validator.sh {models|budget|agents|all} [path] [--strict]"; exit 2 ;;
  esac
fi
```

### Error output format

```
[ERROR] models.yaml: missing required key 'default_model'
[ERROR] budget.yaml: 'budget_limit_tokens' must be positive integer
[WARN]  models.yaml: unknown task_type 'foo_bar'
[OK]    agents.json: valid (5 agents)
```

## Verification

```bash
bash lib/config-validator.sh all
bash lib/config-validator.sh models config/models.yaml
bash lib/config-validator.sh budget config/budget.yaml
bash lib/config-validator.sh agents config/agents.json
```

All exit 0 with current known-good config files.

## Non-goals

- Do not modify config files
- Do not implement full YAML parser
- Do not validate health endpoints
- No new dependencies

## Acceptance criteria

- All public functions exposed
- `bash lib/config-validator.sh all` validates all three files
- Clear errors on bad config
- No false positives on current good config
- Standalone + source modes work
- bash 3.2 compatible
- No source-time side effects
