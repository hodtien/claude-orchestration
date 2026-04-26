#!/usr/bin/env bash
# config-validator.sh — Config Schema Validation Library
# Validates config/models.yaml, config/budget.yaml, config/agents.json
# for structural correctness. JSON validation uses python3 stdlib only;
# YAML validation REQUIRES PyYAML (pip3 install pyyaml) — no fallback exists.
#
# Exit codes: 0 valid, 1 errors found, 2 file not found
# NOTE: Do NOT use set -e. This lib is SOURCEd by callers that manage their own error handling.

_CV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# Resolve PROJECT_ROOT: explicit env > this-repo-root > script-repo-root > pwd
# Script-repo-root derives from the script's own location, not the caller's pwd.
_CV_SCRIPT_REPO_ROOT="$(cd "$_CV_SCRIPT_DIR/.." 2>/dev/null && pwd)"
_CV_PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$_CV_SCRIPT_REPO_ROOT")}"

_cv_error() { echo "[ERROR] $*" >&2; }
_cv_warn()  { echo "[WARN]  $*" >&2; }
_cv_ok()    { echo "[OK]    $*"; }

# ─── models.yaml validation ────────────────────────────────────────────────────
#
# Schema (config/models.yaml):
#   channels:     map of channel-name → {base_url|binary, ...}
#   models:       map of model-name → {channel:str, tier:str, ...}
#   task_mapping: map of task-type → {parallel:[str,...], fallback:[str,...], ...}
#   parallel_policy: {pick_strategy, max_parallel, ...}  (optional)
#   react_policy:    optional
#   router_hints:    optional
#
validate_models_yaml() {
    local filepath="${1:-$_CV_PROJECT_ROOT/config/models.yaml}"
    local label="models.yaml"
    local errors=0

    if [[ ! -f "$filepath" ]]; then
        _cv_error "$label: file not found: $filepath"
        return 2
    fi
    if [[ ! -r "$filepath" ]]; then
        _cv_error "$label: file not readable: $filepath"
        return 2
    fi

    local result
    result=$(python3 - "$filepath" "$label" <<'PYEOF'
import sys

filepath = sys.argv[1]
label    = sys.argv[2]
errors   = []
warnings = []

with open(filepath, 'r') as f:
    content = f.read()

data = None
try:
    import yaml
    data = yaml.safe_load(content)
except ImportError:
    print(f"[ERROR] {label}: PyYAML not installed; cannot validate YAML. Install with: pip3 install pyyaml", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print(f"[ERROR] {label}: root is not a mapping")
    sys.exit(1)

# Required top-level keys
for key in ('channels', 'models', 'task_mapping'):
    if key not in data:
        errors.append(f"[ERROR] {label}: missing required key '{key}'")

# channels: non-empty map; each entry needs base_url or binary
channels = data.get('channels')
if channels and channels is not True:
    if not isinstance(channels, dict) or len(channels) == 0:
        errors.append(f"[ERROR] {label}: 'channels' must be a non-empty map")
    else:
        for ch_name, ch_cfg in channels.items():
            if isinstance(ch_cfg, dict):
                if 'binary' not in ch_cfg and 'base_url' not in ch_cfg:
                    warnings.append(f"[WARN]  {label}: channel '{ch_name}' has no binary or base_url")

# models: non-empty map; each entry requires channel + tier
models = data.get('models')
if models and models is not True:
    if not isinstance(models, dict) or len(models) == 0:
        errors.append(f"[ERROR] {label}: 'models' must be a non-empty map")
    else:
        for m_name, m_cfg in models.items():
            if not isinstance(m_cfg, dict):
                errors.append(f"[ERROR] {label}: model '{m_name}' must be a mapping")
                continue
            for field in ('channel', 'tier'):
                if not m_cfg.get(field):
                    errors.append(f"[ERROR] {label}: model '{m_name}' missing required field '{field}'")

# task_mapping: non-empty map; each entry needs parallel (non-empty list)
task_mapping = data.get('task_mapping')
if task_mapping and task_mapping is not True:
    if not isinstance(task_mapping, dict) or len(task_mapping) == 0:
        errors.append(f"[ERROR] {label}: 'task_mapping' must be a non-empty map")
    else:
        for t_name, t_cfg in task_mapping.items():
            if not isinstance(t_cfg, dict):
                errors.append(f"[ERROR] {label}: task_mapping '{t_name}' must be a mapping")
                continue
            parallel = t_cfg.get('parallel')
            if parallel is None:
                errors.append(f"[ERROR] {label}: task_mapping '{t_name}' missing 'parallel' list")
            elif not isinstance(parallel, list) or len(parallel) == 0:
                errors.append(f"[ERROR] {label}: task_mapping '{t_name}'.parallel must be non-empty list")
            fallback = t_cfg.get('fallback')
            if fallback is not None and not isinstance(fallback, list):
                errors.append(f"[ERROR] {label}: task_mapping '{t_name}'.fallback must be a list")

# parallel_policy (optional): validate max_parallel if present
pp = data.get('parallel_policy')
if pp and isinstance(pp, dict):
    mp = pp.get('max_parallel')
    if mp is not None and (not isinstance(mp, int) or mp < 1):
        errors.append(f"[ERROR] {label}: parallel_policy.max_parallel must be a positive integer")

for line in errors + warnings:
    print(line)

if errors:
    sys.exit(1)

# Emit counts for OK message
try:
    m_count = len(data.get('models', {})) if isinstance(data.get('models'), dict) else '?'
    t_count = len(data.get('task_mapping', {})) if isinstance(data.get('task_mapping'), dict) else '?'
except Exception:
    m_count = t_count = '?'
print(f"__COUNTS__={m_count},{t_count}")
sys.exit(0)
PYEOF
    )
    local py_exit=$?
    local m_count="?" t_count="?"

    if [[ -n "$result" ]]; then
        while IFS= read -r line; do
            case "$line" in
                \[ERROR\]*) echo "$line" >&2; errors=$((errors+1)) ;;
                \[WARN\]*)  echo "$line" >&2 ;;
                __COUNTS__=*) IFS=',' read -r m_count t_count <<< "${line#__COUNTS__=}" ;;
                *)           echo "$line" ;;
            esac
        done <<< "$result"
    fi

    if [[ $py_exit -ne 0 ]] || [[ $errors -gt 0 ]]; then
        return 1
    fi

    _cv_ok "$label: valid ($m_count models, $t_count task types)"
    return 0
}

# ─── budget.yaml validation ────────────────────────────────────────────────────
#
# Schema (config/budget.yaml):
#   global:
#     daily_token_limit:  positive integer
#     alert_threshold_pct: float 0-100
#     hard_cap_pct:       float 0-100  (optional)
#   per_model: optional map of model → {daily_limit: positive int}
#   reporting:
#     rollup_window: string
#     history_days:  positive int
#
validate_budget_yaml() {
    local filepath="${1:-$_CV_PROJECT_ROOT/config/budget.yaml}"
    local label="budget.yaml"
    local errors=0

    if [[ ! -f "$filepath" ]]; then
        _cv_error "$label: file not found: $filepath"
        return 2
    fi
    if [[ ! -r "$filepath" ]]; then
        _cv_error "$label: file not readable: $filepath"
        return 2
    fi

    local result
    result=$(python3 - "$filepath" "$label" <<'PYEOF'
import sys

filepath = sys.argv[1]
label    = sys.argv[2]
errors   = []
warnings = []

with open(filepath, 'r') as f:
    content = f.read()

data = None
try:
    import yaml
    data = yaml.safe_load(content)
except ImportError:
    print(f"[ERROR] {label}: PyYAML not installed; cannot validate YAML. Install with: pip3 install pyyaml", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print(f"[ERROR] {label}: root is not a mapping")
    sys.exit(1)

if 'global' not in data:
    errors.append(f"[ERROR] {label}: missing required key 'global'")
else:
    glob = data['global']
    if glob is True:
        pass  # regex-parsed: presence only confirmed
    elif not isinstance(glob, dict):
        errors.append(f"[ERROR] {label}: 'global' must be a mapping")
    else:
        # daily_token_limit
        dtl = glob.get('daily_token_limit')
        if dtl is None:
            errors.append(f"[ERROR] {label}: global.daily_token_limit is required")
        elif not isinstance(dtl, int) or dtl <= 0:
            errors.append(f"[ERROR] {label}: global.daily_token_limit must be positive integer (got {dtl!r})")

        # alert_threshold_pct
        atp = glob.get('alert_threshold_pct')
        if atp is None:
            errors.append(f"[ERROR] {label}: global.alert_threshold_pct is required")
        else:
            try:
                if not (0.0 <= float(atp) <= 100.0):
                    errors.append(f"[ERROR] {label}: global.alert_threshold_pct must be 0-100 (got {atp})")
            except (TypeError, ValueError):
                errors.append(f"[ERROR] {label}: global.alert_threshold_pct must be numeric (got {atp!r})")

        # hard_cap_pct (optional)
        hcp = glob.get('hard_cap_pct')
        if hcp is not None:
            try:
                if not (0.0 <= float(hcp) <= 100.0):
                    errors.append(f"[ERROR] {label}: global.hard_cap_pct must be 0-100 (got {hcp})")
            except (TypeError, ValueError):
                errors.append(f"[ERROR] {label}: global.hard_cap_pct must be numeric (got {hcp!r})")

# per_model (optional): each entry may have daily_limit (positive int)
per_model = data.get('per_model')
if per_model and per_model is not True and isinstance(per_model, dict):
    for m_name, m_cfg in per_model.items():
        if not isinstance(m_cfg, dict):
            errors.append(f"[ERROR] {label}: per_model.{m_name} must be a mapping")
            continue
        dl = m_cfg.get('daily_limit')
        if dl is not None and (not isinstance(dl, int) or dl <= 0):
            errors.append(f"[ERROR] {label}: per_model.{m_name}.daily_limit must be positive integer")

# reporting (optional): history_days must be positive int if present
reporting = data.get('reporting')
if reporting and reporting is not True and isinstance(reporting, dict):
    hd = reporting.get('history_days')
    if hd is not None and (not isinstance(hd, int) or hd <= 0):
        errors.append(f"[ERROR] {label}: reporting.history_days must be a positive integer")

for line in errors + warnings:
    print(line)

if errors:
    sys.exit(1)

# Emit token limit for OK message
limit = '?'
try:
    g = data.get('global')
    if isinstance(g, dict):
        limit = g.get('daily_token_limit', '?')
except Exception:
    pass
print(f"__LIMIT__={limit}")
sys.exit(0)
PYEOF
    )
    local py_exit=$?
    local limit="?"

    if [[ -n "$result" ]]; then
        while IFS= read -r line; do
            case "$line" in
                \[ERROR\]*) echo "$line" >&2; errors=$((errors+1)) ;;
                \[WARN\]*)  echo "$line" >&2 ;;
                __LIMIT__=*) limit="${line#__LIMIT__=}" ;;
                *)           echo "$line" ;;
            esac
        done <<< "$result"
    fi

    if [[ $py_exit -ne 0 ]] || [[ $errors -gt 0 ]]; then
        return 1
    fi

    _cv_ok "$label: valid (daily_token_limit=$limit)"
    return 0
}

# ─── agents.json validation ────────────────────────────────────────────────────
#
# Schema (config/agents.json):
#   Layout A (current): {"agents": {"<name>": {cost_tier:int, cost_per_1k_tokens:float,
#                                               capabilities:[str], channel:str}}}
#   Layout B (legacy):  [{name:str, type:str}, ...]
#
validate_agents_json() {
    local filepath="${1:-$_CV_PROJECT_ROOT/config/agents.json}"
    local label="agents.json"
    local errors=0

    if [[ ! -f "$filepath" ]]; then
        _cv_error "$label: file not found: $filepath"
        return 2
    fi
    if [[ ! -r "$filepath" ]]; then
        _cv_error "$label: file not readable: $filepath"
        return 2
    fi

    local result
    result=$(python3 - "$filepath" "$label" <<'PYEOF'
import sys, json

filepath = sys.argv[1]
label    = sys.argv[2]
errors   = []

try:
    with open(filepath, 'r') as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"[ERROR] {label}: invalid JSON: {e}")
    sys.exit(1)
except Exception as e:
    print(f"[ERROR] {label}: cannot read file: {e}")
    sys.exit(1)

agent_count = 0

if isinstance(data, dict) and 'agents' in data:
    # Layout A
    agents_map = data['agents']
    if not isinstance(agents_map, dict) or len(agents_map) == 0:
        errors.append(f"[ERROR] {label}: 'agents' must be a non-empty mapping")
    else:
        for a_name, a_cfg in agents_map.items():
            agent_count += 1
            if not str(a_name).strip():
                errors.append(f"[ERROR] {label}: agent entry has empty name")
                continue
            if not isinstance(a_cfg, dict):
                errors.append(f"[ERROR] {label}: agent '{a_name}' config must be a mapping")
                continue
            if 'channel' not in a_cfg:
                errors.append(f"[ERROR] {label}: agent '{a_name}' missing required field 'channel'")
            cpt = a_cfg.get('cost_per_1k_tokens')
            if cpt is not None and (not isinstance(cpt, (int, float)) or cpt <= 0):
                errors.append(f"[ERROR] {label}: agent '{a_name}'.cost_per_1k_tokens must be positive number")
            ct = a_cfg.get('cost_tier')
            if ct is not None and (not isinstance(ct, int) or ct < 1):
                errors.append(f"[ERROR] {label}: agent '{a_name}'.cost_tier must be positive integer")

elif isinstance(data, list):
    # Layout B
    if len(data) == 0:
        errors.append(f"[ERROR] {label}: agents array is empty")
    for i, entry in enumerate(data):
        agent_count += 1
        if not isinstance(entry, dict):
            errors.append(f"[ERROR] {label}: entry [{i}] must be an object")
            continue
        name = str(entry.get('name', '')).strip()
        if not name:
            errors.append(f"[ERROR] {label}: entry [{i}] has empty or missing 'name'")
        if 'type' not in entry:
            errors.append(f"[ERROR] {label}: entry [{i}] (name={name!r}) missing required field 'type'")

else:
    errors.append(f"[ERROR] {label}: root must be an object with 'agents' key, or an array")

for line in errors:
    print(line)

if errors:
    sys.exit(1)

print(f"__AGENT_COUNT__={agent_count}")
sys.exit(0)
PYEOF
    )
    local py_exit=$?
    local agent_count="?"

    if [[ -n "$result" ]]; then
        while IFS= read -r line; do
            case "$line" in
                \[ERROR\]*) echo "$line" >&2; errors=$((errors+1)) ;;
                \[WARN\]*)  echo "$line" >&2 ;;
                __AGENT_COUNT__=*) agent_count="${line#__AGENT_COUNT__=}" ;;
                *)           echo "$line" ;;
            esac
        done <<< "$result"
    fi

    if [[ $py_exit -ne 0 ]] || [[ $errors -gt 0 ]]; then
        return 1
    fi

    _cv_ok "$label: valid ($agent_count agents)"
    return 0
}

# ─── validate_all_configs ──────────────────────────────────────────────────────

validate_all_configs() {
    local strict=0
    for arg in "$@"; do
        [[ "$arg" == "--strict" ]] && strict=1
    done

    local overall=0
    local r

    validate_models_yaml "$_CV_PROJECT_ROOT/config/models.yaml"
    r=$?
    if [[ $r -ne 0 ]]; then
        overall=1
        [[ $strict -eq 1 ]] && return 1
    fi

    validate_budget_yaml "$_CV_PROJECT_ROOT/config/budget.yaml"
    r=$?
    if [[ $r -ne 0 ]]; then
        overall=1
        [[ $strict -eq 1 ]] && return 1
    fi

    validate_agents_json "$_CV_PROJECT_ROOT/config/agents.json"
    r=$?
    if [[ $r -ne 0 ]]; then
        overall=1
        [[ $strict -eq 1 ]] && return 1
    fi

    return $overall
}

# ─── Source guard / standalone CLI ────────────────────────────────────────────

if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        models) validate_models_yaml "${2:-$_CV_PROJECT_ROOT/config/models.yaml}" ;;
        budget) validate_budget_yaml "${2:-$_CV_PROJECT_ROOT/config/budget.yaml}" ;;
        agents) validate_agents_json "${2:-$_CV_PROJECT_ROOT/config/agents.json}" ;;
        all)    validate_all_configs "${@:2}" ;;
        *)
            echo "Usage: config-validator.sh {models|budget|agents} [path] | config-validator.sh all [--strict]" >&2
            exit 2
            ;;
    esac
    exit $?
fi
