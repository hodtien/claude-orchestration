#!/usr/bin/env bash
# _dashboard/budget.sh — Token budget dashboard
# Sourced by orch-dashboard.sh.
# Usage: budget [--json] [--since <Nh|Nd>] [--model <name>] [--dir <path>]
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Default paths
DEFAULT_AUDIT="$PROJECT_ROOT/.orchestration/audit.jsonl"
DEFAULT_COSTLOG="$HOME/.claude/orchestration/cost-tracking.jsonl"
DEFAULT_RESULTS="$PROJECT_ROOT/.orchestration/results"
DEFAULT_CONFIG="$PROJECT_ROOT/config/budget.yaml"
DEFAULT_MODELS="$PROJECT_ROOT/config/models.yaml"

# Env overrides (for testing)
AUDIT_FILE="${BUDGET_AUDIT_FILE:-$DEFAULT_AUDIT}"
COST_LOG="${BUDGET_COST_LOG:-$DEFAULT_COSTLOG}"
RESULTS_DIR="${BUDGET_RESULTS_DIR:-$DEFAULT_RESULTS}"
BUDGET_YAML="${BUDGET_CONFIG:-$DEFAULT_CONFIG}"
MODELS_YAML="${BUDGET_MODELS_YAML:-$DEFAULT_MODELS}"

# Flags
OUTPUT_JSON=false
SINCE_ARG=""
MODEL_FILTER="__none__"

while [ $# -gt 0 ]; do
  case "$1" in
    --json)   OUTPUT_JSON=true; shift ;;
    --since)  SINCE_ARG="$2"; shift 2 ;;
    --model)  MODEL_FILTER="$2"; shift 2 ;;
    --dir)    RESULTS_DIR="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: budget [--json] [--since <Nh|Nd>] [--model <name>] [--dir <path>]"
      exit 0 ;;
    *) shift ;;
  esac
done

# ── python aggregation ─────────────────────────────────────────────────────────
python3 - "$AUDIT_FILE" "$COST_LOG" "$RESULTS_DIR" "$BUDGET_YAML" "$MODELS_YAML" \
         "$OUTPUT_JSON" "$SINCE_ARG" "$MODEL_FILTER" <<'PYEOF'
import json, sys, os, re
from datetime import datetime, timezone, timedelta
from collections import defaultdict

audit_file   = sys.argv[1]
cost_log     = sys.argv[2]
results_dir  = sys.argv[3]
budget_yaml  = sys.argv[4]
models_yaml  = sys.argv[5]
output_json  = sys.argv[6].lower() == "true"
since_arg    = sys.argv[7]
model_filter = sys.argv[8] if sys.argv[8] != "__none__" else ""

# ── helpers ───────────────────────────────────────────────────────────────────
def parse_ts(s):
    if not s: return None
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None

def parse_since(s):
    if not s: return None
    val = s.replace("h","").replace("d","")
    try:
        h = int(val)
        if "d" in s: h *= 24
        return datetime.now(timezone.utc) - timedelta(hours=h)
    except ValueError:
        return None

def load_jsonl(path):
    records = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except (FileNotFoundError, OSError):
        pass
    return records

def load_budget_yaml(path):
    """Parse budget.yaml with simple regex (no PyYAML)."""
    cfg = {
        "daily_token_limit": 500000,
        "alert_threshold_pct": 80,
        "hard_cap_pct": 100,
        "per_model": {},
    }
    in_per_model = False
    current_model = None
    try:
        with open(path) as f:
            for line in f:
                ls = line.rstrip()
                if re.match(r'^\s*daily_token_limit:\s*(\d+)', ls):
                    cfg["daily_token_limit"] = int(re.search(r'\d+', ls).group())
                elif re.match(r'^\s*alert_threshold_pct:\s*(\d+)', ls):
                    cfg["alert_threshold_pct"] = int(re.search(r'\d+', ls).group())
                elif re.match(r'^\s*hard_cap_pct:\s*(\d+)', ls):
                    cfg["hard_cap_pct"] = int(re.search(r'\d+', ls).group())
                elif re.match(r'^per_model:', ls):
                    in_per_model = True
                elif re.match(r'^[a-z]', ls) and 'per_model' not in ls:
                    in_per_model = False; current_model = None
                elif in_per_model:
                    # Model name: line with 2-space indent ending in ":"
                    m = re.match(r'^  ([^#][^:]+):\s*$', ls)
                    if m:
                        current_model = m.group(1).strip()
                        cfg["per_model"][current_model] = {}
                        continue
                    # daily_limit under a model: 4-space indent
                    m = re.match(r'^\s{4}daily_limit:\s*(\d+)', ls)
                    if m and current_model:
                        cfg["per_model"][current_model]["daily_limit"] = int(m.group(1))
    except (FileNotFoundError, OSError):
        pass
    return cfg

def load_cost_hints(path):
    """Load cost_hint per model from models.yaml."""
    hints = {}
    current_model = None
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r'^  ([a-zA-Z0-9_./-]+):\s*$', line)
                if m:
                    current_model = m.group(1)
                    continue
                hm = re.match(r'^\s+cost_hint:\s*(\S+)', line)
                if hm and current_model:
                    hints[current_model] = hm.group(1)
    except (FileNotFoundError, OSError):
        pass
    return hints

# ── load data ─────────────────────────────────────────────────────────────────
cutoff = parse_since(since_arg) if since_arg else None
now = datetime.now(timezone.utc)

budget_cfg = load_budget_yaml(budget_yaml)
has_budget_config = os.path.exists(budget_yaml)
cost_hints = load_cost_hints(models_yaml)

# Audit log
audit_records = load_jsonl(audit_file)
has_audit = bool(audit_records)

# Sum estimated tokens from audit.jsonl (within window)
audit_total_estimated = 0
audit_tid_tokens = defaultdict(int)
for rec in audit_records:
    if rec.get("event") != "tier_assigned": continue
    ts = parse_ts(rec.get("timestamp",""))
    if cutoff and (ts is None or ts < cutoff): continue
    tokens = int(rec.get("tokens_estimated") or 0)
    audit_total_estimated += tokens
    tid = rec.get("task_id","")
    if tid:
        audit_tid_tokens[tid] += tokens

# Cost tracking log
cost_records = load_jsonl(cost_log)
has_cost_log = bool(cost_records)

cost_by_model = defaultdict(lambda: {"tokens_actual": 0, "tokens_estimated": 0, "tasks": set()})

for rec in cost_records:
    ts = parse_ts(rec.get("timestamp",""))
    if cutoff and (ts is None or ts < cutoff): continue
    model = rec.get("agent","unknown")
    if model_filter and model != model_filter: continue
    tokens_in  = int(rec.get("tokens_input") or 0)
    tokens_out = int(rec.get("tokens_output") or 0)
    tid = rec.get("task_id","")
    cost_by_model[model]["tokens_actual"] += tokens_in + tokens_out
    cost_by_model[model]["tokens_estimated"] += audit_tid_tokens.get(tid, 0)
    if tid:
        cost_by_model[model]["tasks"].add(tid)

# ── totals ────────────────────────────────────────────────────────────────────
all_estimated = audit_total_estimated
all_actual = sum(v["tokens_actual"] for v in cost_by_model.values()) if has_cost_log else 0
used_for_budget = all_actual if has_cost_log else all_estimated

budget_limit = budget_cfg["daily_token_limit"]
alert_pct    = budget_cfg["alert_threshold_pct"]
hard_cap_pct = budget_cfg["hard_cap_pct"]
budget_pct   = round(used_for_budget / budget_limit * 100, 1) if budget_limit > 0 else 0.0

if budget_pct >= hard_cap_pct:
    overall_status = "OVER_BUDGET"
elif budget_pct >= alert_pct:
    overall_status = "WARNING"
else:
    overall_status = "OK"

# ── burn rate ─────────────────────────────────────────────────────────────────
window_start = cutoff if cutoff else (now - timedelta(hours=24))
hours_elapsed = max((now - window_start).total_seconds() / 3600.0, 0.1)
tokens_for_rate = all_actual if has_cost_log else all_estimated
tokens_per_hour = int(round(tokens_for_rate / hours_elapsed))
projected_daily = tokens_per_hour * 24

proj_exhaust = None
if tokens_per_hour > 0 and (budget_limit - used_for_budget) > 0:
    proj_exhaust = round((budget_limit - used_for_budget) / tokens_per_hour, 1)

# Trend: compare last 3h vs prior 3h
trend = "stable"
if has_cost_log:
    last3h_start = now - timedelta(hours=3)
    prev3h_start = now - timedelta(hours=6)
    last3h_tok = sum(
        int(r.get("tokens_input",0)) + int(r.get("tokens_output",0))
        for r in cost_records
        if (not model_filter or r.get("agent","") == model_filter)
        and (t := parse_ts(r.get("timestamp",""))) is not None
        and t >= last3h_start
    )
    prev3h_tok = sum(
        int(r.get("tokens_input",0)) + int(r.get("tokens_output",0))
        for r in cost_records
        if (not model_filter or r.get("agent","") == model_filter)
        and (t := parse_ts(r.get("timestamp",""))) is not None
        and prev3h_start <= t < last3h_start
    )
    if prev3h_tok > 0:
        delta = (last3h_tok - prev3h_tok) / prev3h_tok
        if delta > 0.2: trend = "increasing"
        elif delta < -0.2: trend = "decreasing"

# ── by_model ──────────────────────────────────────────────────────────────────
by_model_out = {}
for model, c in sorted(cost_by_model.items(), key=lambda x: x[1]["tokens_actual"], reverse=True):
    if model_filter and model != model_filter: continue
    model_limit = budget_cfg["per_model"].get(model, {}).get("daily_limit")
    actual = c["tokens_actual"]
    est    = c["tokens_estimated"] if c["tokens_estimated"] > 0 else None
    used_pct = round(actual / model_limit * 100, 1) if model_limit and model_limit > 0 else None
    by_model_out[model] = {
        "tokens_estimated": est,
        "tokens_actual": actual,
        "tasks": len(c["tasks"]),
        "model_limit": model_limit,
        "model_used_pct": used_pct,
        "cost_hint": cost_hints.get(model, "unknown"),
    }

# ── alerts ────────────────────────────────────────────────────────────────────
alerts = []
if overall_status == "OVER_BUDGET":
    alerts.append({"level": "CRITICAL",
        "message": f"Budget OVER_LIMIT: {budget_pct}% used ({used_for_budget:,}/{budget_limit:,} tokens)"})
elif overall_status == "WARNING":
    alerts.append({"level": "WARNING",
        "message": f"Budget at {budget_pct}% — approaching {alert_pct}% alert threshold"})

for model, m in by_model_out.items():
    pct = m.get("model_used_pct")
    if pct is None: continue
    if pct >= hard_cap_pct:
        alerts.append({"level": "CRITICAL", "message": f"{model} at {pct}% of model daily limit"})
    elif pct >= alert_pct:
        alerts.append({"level": "WARNING",  "message": f"{model} at {pct}% of model daily limit"})

# ── data quality ──────────────────────────────────────────────────────────────
degraded = not has_cost_log
note = None
if not has_cost_log and not has_audit:
    degraded = True
    note = "no token data sources found"
elif not has_cost_log:
    note = "cost-log absent — using estimated tokens only from audit.jsonl"

# ── tasks_counted ─────────────────────────────────────────────────────────────
tasks_counted = sum(
    len(v["tasks"]) for v in cost_by_model.values()
) if has_cost_log else len(audit_tid_tokens)

# ── assemble ──────────────────────────────────────────────────────────────────
result = {
    "schema_version": 1,
    "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "window": since_arg or "24h",
    "config": {
        "daily_token_limit": budget_limit,
        "alert_threshold_pct": alert_pct,
        "hard_cap_pct": hard_cap_pct,
        "source": budget_yaml if has_budget_config else "defaults",
    },
    "totals": {
        "tokens_estimated": all_estimated,
        "tokens_actual": all_actual if has_cost_log else None,
        "tasks_counted": tasks_counted,
        "budget_used_pct": budget_pct,
        "status": overall_status,
    },
    "by_model": by_model_out,
    "burn_rate": {
        "tokens_per_hour": tokens_per_hour,
        "projected_daily_total": projected_daily,
        "projected_exhaustion_h": proj_exhaust,
        "trend": trend,
    },
    "alerts": alerts,
    "data_quality": {
        "has_cost_log": has_cost_log,
        "has_audit_log": has_audit,
        "has_budget_config": has_budget_config,
        "degraded": degraded,
        "note": note,
    },
}

if output_json:
    print(json.dumps(result, indent=2))
    sys.exit(0)

# ── human-readable ────────────────────────────────────────────────────────────
r = result
gen = r["generated_at"]
win = r["window"]
cfg = r["config"]
tot = r["totals"]
br  = r["burn_rate"]
dq  = r["data_quality"]
bm  = r["by_model"]

print("=" * 60)
print("  TOKEN BUDGET DASHBOARD")
print("=" * 60)
print(f"  Window:  last {win} (generated {gen})")
print(f"  Budget:  {cfg['daily_token_limit']:,} tokens/day ({cfg['source']})")
print(f"  Status:  {tot['status']} ({tot['budget_used_pct']}% used)")
print()
print("── Totals ───────────────────────────────────────────────")
est_str = f"{tot['tokens_estimated']:,}" if tot["tokens_estimated"] else "0"
act_str = f"{tot['tokens_actual']:,}" if tot["tokens_actual"] is not None else "n/a (estimated)"
print(f"  Estimated: {est_str} tokens ({tot['tasks_counted']} tasks)")
print(f"  Actual:     {act_str}")
remaining = cfg["daily_token_limit"] - (tot["tokens_actual"] or tot["tokens_estimated"] or 0)
print(f"  Remaining:  {remaining:,} tokens")
print()

bar_w = 20
if bm:
    print("── By Model ─────────────────────────────────────────────")
    for model, m in bm.items():
        actual = m.get("tokens_actual", 0)
        pct    = m.get("model_used_pct")
        lim    = m.get("model_limit")
        lim_s  = f"{lim:,}" if lim else "global"
        pct_s  = f"{pct:.1f}%" if pct is not None else "—"
        if pct is not None and pct > 0:
            filled = min(int(pct / 5), bar_w)
            bar = " [" + "█" * filled + "░" * (bar_w - filled) + "]"
        else:
            bar = ""
        print(f"  {model:28s} {actual:>10,} / {lim_s:<10} {bar:22s} {pct_s:>6s}")
    print()
else:
    print("── By Model ─────────────────────────────────────────────")
    print("  (no cost data)")
    print()

print("── Burn Rate ────────────────────────────────────────────")
tph = br.get("tokens_per_hour")
if tph is not None:
    print(f"  Current: ~{tph:,} tokens/hour")
    proj = br.get("projected_daily_total")
    if proj:
        print(f"  Projected daily: ~{proj:,} tokens")
    print(f"  Trend: {br.get('trend') or 'unknown'}")
    ex = br.get("projected_exhaustion_h")
    if ex:
        print(f"  Exhaustion: ~{ex:.1f}h remaining")
    else:
        print(f"  Exhaustion: not projected within window")
else:
    print("  (no cost data for burn rate)")
print()

print("── Alerts ────────────────────────────────────────────────")
if r["alerts"]:
    for a in r["alerts"]:
        print(f"  [{a['level']}] {a['message']}")
else:
    print("  (none)")
print()

print("── Data Quality ─────────────────────────────────────────")
cl = "✓" if dq["has_cost_log"] else "✗"
al = "✓" if dq["has_audit_log"] else "✗"
bc = "✓" if dq["has_budget_config"] else "✗"
print(f"  cost-tracking.jsonl: {cl} {'found' if dq['has_cost_log'] else 'absent'}")
print(f"  audit.jsonl:         {al} {'found' if dq['has_audit_log'] else 'absent'}")
print(f"  budget.yaml:         {bc} {'found' if dq['has_budget_config'] else 'absent'}")
if dq.get("note"):
    print(f"  Note: {dq['note']}")
print("=" * 60)
PYEOF
