---
id: learning-wire-001
agent: oc-medium
reviewer: copilot
timeout: 600
retries: 1
task_type: implement_feature
context_cache: [project-overview, architecture]
read_files: [lib/learning-engine.sh, bin/task-dispatch.sh, mcp-server/server.mjs, bin/orch-dashboard.sh, bin/_dashboard/cost.sh, docs/PLAN_phase9.md]
---

# Task: Wire learning-engine.sh into dispatch + MCP + dashboard

## Objective
Five deliverables:
1. Fix bugs in `lib/learning-engine.sh` (ORCH_DIR, jq dependency, mkdir at load time, bc dependency)
2. Wire `learn_from_outcome()` into dispatch success/failure paths in `bin/task-dispatch.sh`
3. Wire `analyze_batch()` into batch-completion handler (after inbox notification)
4. Add `get_routing_advice` MCP tool to `mcp-server/server.mjs`
5. Add `learn` subcommand to `bin/orch-dashboard.sh` via new `bin/_dashboard/learn.sh`

This is Phase 9.2 of the orchestration roadmap. Full plan at `docs/PLAN_phase9.md`.

Closes the feedback loop: `dispatch → execute → observe → learn → better dispatch`.

## Context

`lib/learning-engine.sh` (259 lines) exists with 6 functions: `init_routing_rules()`, `learn_from_outcome()`, `update_routing_for_success()`, `get_agent_recommendation()`, `analyze_batch()`, `get_routing_advice()`. All implemented but **NOT wired** into dispatch and contain 4 bugs (same pattern as Phase 9.1 task-decomposer fix).

Patterns to follow EXACTLY (already proven in Phase 9.1):
- `lib/task-decomposer.sh` (post-fix) — env-overridable paths, no jq, no mkdir at load
- `lib/task-status.sh` — source-guard pattern in task-dispatch.sh (line 44-49)
- `mcp-server/server.mjs` `runBudgetDashboard()` (line 401) and `runDecomposePreview()` — thin spawnSync delegation
- `bin/orch-dashboard.sh` (line 11) `case "$cmd" in budget) source ... ;;` — subcommand dispatch
- `bin/_dashboard/cost.sh`, `bin/_dashboard/budget.sh` — subcommand body pattern

## Deliverable 1: Fix bugs in `lib/learning-engine.sh`

### Bug 1: Wrong ORCH_DIR default (CRITICAL)
**Current** (line 7):
```bash
ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
```
**Fix:**
```bash
ORCH_DIR="${ORCH_DIR:-${PROJECT_ROOT:-.}/.orchestration}"
LEARN_DIR="${LEARN_DIR:-$ORCH_DIR/learnings}"
CONFIG_DIR="${CONFIG_DIR:-$ORCH_DIR/config}"
LEARN_DB="${LEARN_DB:-$LEARN_DIR/learnings.jsonl}"
ROUTING_RULES="${ROUTING_RULES:-$LEARN_DIR/routing-rules.json}"
```
This matches `bin/task-dispatch.sh` line 69 (`ORCH_DIR="$PROJECT_ROOT/.orchestration"`) and the post-fix `lib/task-decomposer.sh` pattern.

### Bug 2: jq dependency (HIGH)
Lines 89, 94, 99, 103, 111-115, 124-126, 137-139, 198-201, 203, 239-241 use `jq`. All other Phase 6-9 code uses python3 stdlib. Replace **every** `jq` invocation with python3 one-liners that read JSON via stdin or file path.

Recommended approach for `update_routing_for_success()` upsert:
```bash
python3 - "$ROUTING_RULES" "$task_type" "$agent" "$cost_per_min" <<'PY'
import json, sys, os, datetime
path, tt, ag, cpm = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
data = json.load(open(path)) if os.path.exists(path) else {"rules":[], "last_updated":"none", "version":1}
found = False
for r in data["rules"]:
    if r["task_type"] == tt:
        found = True
        if cpm < r.get("cost_per_min", 1e18):
            r["best_agent"] = ag
            r["cost_per_min"] = cpm
            r["success_count"] = r.get("success_count", 0) + 1
        break
if not found:
    data["rules"].append({"task_type":tt,"best_agent":ag,"cost_per_min":cpm,"success_count":1})
data["last_updated"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
tmp = path + ".tmp"
json.dump(data, open(tmp,"w"))
os.replace(tmp, path)
PY
```

Apply analogous python rewrites to:
- `get_agent_recommendation()` (line 137-139) — read rule for `task_type`, fallback to default mapping
- `analyze_batch()` (line 173-203) — iterate `LEARN_DB` lines filtering by `batch_id`, aggregate stats
- `get_routing_advice()` (line 239-241) — sort top-3 rules by `cost_per_min`

### Bug 3: mkdir at module load time (MEDIUM)
**Current** (line 11):
```bash
mkdir -p "$LEARN_DIR" "$CONFIG_DIR"
```
**Fix:** Remove this line. Move the mkdir into `learn_from_outcome()` (before append to `LEARN_DB`) and `init_routing_rules()` (before write). Module source must have **zero side effects**.

### Bug 4: `bc` dependency (MEDIUM)
Line 85 (`echo "scale=2; ... | bc"`) and line 107 (`echo "$cost_per_min < $current_cpm" | bc -l`) — replace with python3:
```bash
cost_per_min=$(python3 -c "import sys; t=int(sys.argv[1]); d=int(sys.argv[2]); print(f'{t/(d/60+0.1):.2f}')" "$tokens" "$duration")
```

## Deliverable 2: Wire `learn_from_outcome()` into dispatch

### Step 1: Source the lib in `bin/task-dispatch.sh`
After line 49 (task-status.sh source block) and after the task-decomposer source block already added in Phase 9.1, add:
```bash
# shellcheck source=../lib/learning-engine.sh
if [ -f "$SCRIPT_DIR/../lib/learning-engine.sh" ]; then
    . "$SCRIPT_DIR/../lib/learning-engine.sh"
else
    learn_from_outcome() { return 0; }
    analyze_batch() { return 0; }
fi
```

### Step 2: Add learning hook in both status writers
Modify `_write_status_consensus()` (line 864) and `_write_status_first_success()` (line 904). After the existing `write_task_status "$tid" "$_status_json"` call (lines 900 and 931), append:
```bash
    # Phase 9.2: feed outcome to learning engine
    local _learn_success="false"
    [[ "$final_state" == "done" ]] && _learn_success="true"
    local _learn_tokens=0
    if [ -s "$RESULTS_DIR/${tid}.tokens" ]; then
        _learn_tokens=$(cat "$RESULTS_DIR/${tid}.tokens" 2>/dev/null || echo "0")
    fi
    learn_from_outcome "${BATCH_ID:-unknown}" "$_learn_success" "${winner:-unknown}" \
        "$task_type" "$_duration" "$_learn_tokens" "" 2>/dev/null || true
```

The `${tid}.tokens` file may not exist yet — default to 0. The wire must not break dispatch if the learning call fails (`|| true`).

### Step 3: Wire `analyze_batch()` after inbox notification
In `bin/task-dispatch.sh` line 2283 (immediately after `echo "[dispatch] ✉️  Inbox notification written: ..."`), add:
```bash
# Phase 9.2: post-batch learning analysis
if command -v analyze_batch >/dev/null 2>&1; then
  _learn_analysis=$(analyze_batch "${BATCH_ID:-unknown}" 2>/dev/null || true)
  if [ -n "$_learn_analysis" ] && [ -f "$_learn_analysis" ]; then
    echo "[dispatch] 📊 Learning analysis: $_learn_analysis"
  fi
fi
```

This must run **before** `notify_event "batch_complete"` (line 2296) so analysis is on disk by the time downstream consumers fire.

## Deliverable 3: `get_routing_advice` MCP tool

### Add to `mcp-server/server.mjs` ListToolsRequestSchema handler (after the `get_token_budget` entry around line 544):
```javascript
{
  name: "get_routing_advice",
  description: "Get learned routing recommendation for a task type, based on historical batch outcomes. Returns the best-performing agent and the top-3 candidates by cost-per-minute. Falls back to default mapping when learnings.jsonl has fewer than 10 records.",
  inputSchema: {
    type: "object",
    properties: {
      task_type: { type: "string", description: "Task type (e.g. implement_feature, write_tests, security_audit)" }
    },
    required: ["task_type"]
  }
}
```

### Add to CallToolRequestSchema switch (after the `get_token_budget` case at line 608):
```javascript
case "get_routing_advice":
  result = runRoutingAdvice(args?.task_type || "");
  break;
```

### Add helper function (parallel to `runBudgetDashboard` / `runDecomposePreview`):
```javascript
function runRoutingAdvice(taskType) {
  const helperPath = join(PROJECT_ROOT, "lib", "learning-engine.sh");
  if (!existsSync(helperPath)) {
    return { error: "lib/learning-engine.sh not found" };
  }
  if (!taskType) return { error: "task_type is required" };
  try {
    const result = spawnSync("bash", ["-c",
      `source "${helperPath}" && get_routing_advice "$1"`,
      "--", taskType
    ], {
      encoding: "utf8",
      timeout: 10000,
      env: { ...process.env, PROJECT_ROOT },
    });
    if (result.status === 0 && result.stdout) {
      return { task_type: taskType, advice: result.stdout.trim() };
    }
    return { error: (result.stderr || "routing advice failed").slice(0, 500) };
  } catch (e) {
    return { error: String(e).slice(0, 500) };
  }
}
```

## Deliverable 4: `orch-dashboard.sh learn` subcommand

### Update `bin/orch-dashboard.sh` `case` statement
Add a new case alongside `cost`/`metrics`/`budget` (around line 11):
```bash
  learn)   source "$SCRIPT_DIR/_dashboard/learn.sh" "$@" ;;
```
Also update the help text in the same file to include:
```
  learn     Show learned routing rules and win-rate per model × task_type. Flags: --json --task-type <name>
```

### Create `bin/_dashboard/learn.sh`
```bash
#!/usr/bin/env bash
# Subcommand: orch-dashboard.sh learn — show learning-engine state
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ORCH_DIR="${ORCH_DIR:-$PROJECT_ROOT/.orchestration}"
LEARN_DIR="${LEARN_DIR:-$ORCH_DIR/learnings}"
LEARN_DB="${LEARN_DB:-$LEARN_DIR/learnings.jsonl}"
ROUTING_RULES="${ROUTING_RULES:-$LEARN_DIR/routing-rules.json}"

json_out=false
filter_tt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json)       json_out=true ;;
    --task-type)  filter_tt="${2:-}"; shift ;;
    *)            ;;
  esac
  shift || true
done

if [ ! -f "$LEARN_DB" ]; then
  echo "No learnings recorded yet. (LEARN_DB=$LEARN_DB does not exist)"
  exit 0
fi

python3 - "$LEARN_DB" "$ROUTING_RULES" "$json_out" "$filter_tt" <<'PY'
import json, sys, os, collections
db, rr, want_json, tt = sys.argv[1], sys.argv[2], sys.argv[3]=="true", sys.argv[4]
records = []
for line in open(db):
    line = line.strip()
    if not line: continue
    try: records.append(json.loads(line))
    except: pass
if tt:
    records = [r for r in records if r.get("task_type") == tt]
agg = collections.defaultdict(lambda: {"win":0,"loss":0,"tokens":0,"duration":0})
for r in records:
    key = (r.get("agent","?"), r.get("task_type","?"))
    if r.get("success"): agg[key]["win"] += 1
    else: agg[key]["loss"] += 1
    agg[key]["tokens"] += int(r.get("tokens",0) or 0)
    agg[key]["duration"] += int(r.get("duration",0) or 0)
rules = {"rules":[]}
if os.path.exists(rr):
    try: rules = json.load(open(rr))
    except: pass
out = {"records": len(records), "rules": rules.get("rules",[]),
       "win_rates": [
         {"agent":a, "task_type":t, "win":v["win"], "loss":v["loss"],
          "win_rate": (v["win"]/(v["win"]+v["loss"])) if (v["win"]+v["loss"])>0 else 0,
          "avg_tokens": int(v["tokens"]/(v["win"]+v["loss"])) if (v["win"]+v["loss"])>0 else 0}
         for (a,t),v in sorted(agg.items())
       ]}
if want_json:
    print(json.dumps(out, indent=2))
else:
    print(f"=== Learning Dashboard ({len(records)} records) ===")
    print()
    print(f"{'Agent':<20} {'Task Type':<25} {'Win':>5} {'Loss':>5} {'Win%':>7} {'AvgTok':>8}")
    print("-"*72)
    for w in out["win_rates"]:
        print(f"{w['agent']:<20} {w['task_type']:<25} {w['win']:>5} {w['loss']:>5} {w['win_rate']*100:>6.1f}% {w['avg_tokens']:>8}")
    print()
    print(f"Routing rules: {len(out['rules'])}")
    for r in out["rules"]:
        print(f"  {r.get('task_type'):<25} → {r.get('best_agent'):<15} cost/min={r.get('cost_per_min')}  succ={r.get('success_count')}")
PY
```
Make it executable (`chmod +x bin/_dashboard/learn.sh`).

## Constraints
- **Python3 stdlib only** — NO jq, NO bc, NO PyYAML, NO pip packages
- Module source must have **zero side effects** (no mkdir at load time)
- All env vars must be overridable for test isolation: `ORCH_DIR`, `LEARN_DIR`, `LEARN_DB`, `ROUTING_RULES`, `CONFIG_DIR`
- bash 3.2 compatible (no associative arrays, no `|&`)
- Do not break existing dispatch — wrap `learn_from_outcome` and `analyze_batch` calls with `|| true`
- Do not touch existing 11 MCP tools (only add the 12th: `get_routing_advice`)
- Do not touch existing dashboard subcommands (cost/metrics/slo/report/db/budget) — only add `learn`
- The `${tid}.tokens` file may not exist yet — default to 0; Phase 9.2 test task validates this path

## Verification
```bash
# Source test — no side effects
bash -c 'source lib/learning-engine.sh; echo OK'

# Standalone helper — no crash
bash lib/learning-engine.sh recommend implement_feature

# Dashboard subcommand
bash bin/orch-dashboard.sh learn --json
```
