#!/usr/bin/env bash
set -euo pipefail
usage() {
  cat <<'EOF'
Usage:
  task-dag.sh <batch-dir>                 # ASCII DAG
  task-dag.sh <batch-dir> --mermaid       # Mermaid graph LR
  task-dag.sh <batch-dir> --critical-path # highlight critical path
  task-dag.sh <batch-dir> --json          # JSON adjacency + metadata
EOF
}
[ $# -ge 1 ] || { usage >&2; exit 1; }
BATCH_INPUT="$1"; shift || true
MODE="ascii"; SHOW_CRITICAL=0; SIMPLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mermaid) MODE="mermaid" ;;
    --json) MODE="json" ;;
    --critical-path) SHOW_CRITICAL=1 ;;
    --simple) SIMPLE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[dag] unknown flag: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -d "$BATCH_INPUT" ]; then
  [[ "$BATCH_INPUT" = /* ]] && BATCH_DIR="$BATCH_INPUT" || BATCH_DIR="$(pwd)/$BATCH_INPUT"
elif [ -d "$PROJECT_ROOT/.orchestration/tasks/$BATCH_INPUT" ]; then
  BATCH_DIR="$PROJECT_ROOT/.orchestration/tasks/$BATCH_INPUT"
else
  echo "[dag] batch dir not found: $BATCH_INPUT" >&2; exit 1
fi
shopt -s nullglob
TASK_FILES=("$BATCH_DIR"/task-*.md)
if [ ${#TASK_FILES[@]} -eq 0 ]; then
  echo "[dag] no task-*.md files found in $BATCH_DIR"
  echo "Summary: total tasks=0, parallel groups=0, critical path length=0"
  exit 0
fi
python3 - "$MODE" "$SHOW_CRITICAL" "$SIMPLE" "$BATCH_DIR" "${TASK_FILES[@]}" <<'PYEOF'
import json, re, sys, heapq
from collections import defaultdict
mode, show_critical, simple, batch_dir = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1", sys.argv[4]
files = sys.argv[5:]
def clip(s, w=79): return s if len(s) <= w else s[:w-3] + "..."
def frontmatter(text):
    m = re.match(r"^---\s*\n(.*?)\n---", text, re.S)
    if not m: return {}
    out, cur = {}, None
    for raw in m.group(1).splitlines():
        line = raw.rstrip(); s = line.strip()
        if not s or s.startswith("#"): continue
        if ":" in s and re.match(r"^[A-Za-z0-9_]+:", s):
            k, v = s.split(":", 1); out[k.strip()] = v.strip(); cur = k.strip() if not v.strip() else None; continue
        if cur and s.startswith("- "): out[cur] += ("," if out[cur] else "") + s[2:].strip(); continue
        cur = None
    return out
def scalar(v, d=""):
    if v is None: return d
    v = v.strip()
    if not v: return d
    if v[0] not in ('"', "'", "["): v = re.sub(r"\s+#.*$", "", v).strip()
    return v[1:-1] if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'") else v
def parse_list(v):
    if v is None: return []
    v = v.strip()
    if not v: return []
    if v[0] not in ('"', "'", "["): v = re.sub(r"\s+#.*$", "", v).strip()
    if v.startswith("[") and v.endswith("]"): v = v[1:-1].strip()
    if not v: return []
    return [p.strip().strip('"').strip("'") for p in v.split(",") if p.strip()]
tasks = {}
for fp in files:
    with open(fp, "r", encoding="utf-8", errors="replace") as f: fm = frontmatter(f.read())
    tid = scalar(fm.get("id"), "")
    if not tid: continue
    if tid in tasks: print(f"[dag] WARNING: duplicate task id '{tid}' in {fp}", file=sys.stderr); continue
    tasks[tid] = {
        "id": tid, "agent": scalar(fm.get("agent"), "unknown"), "priority": scalar(fm.get("priority"), "normal"),
        "depends_on": [d for d in parse_list(fm.get("depends_on")) if d and d != tid],
    }
if not tasks:
    print("[dag] no valid task ids found")
    print("Summary: total tasks=0, parallel groups=0, critical path length=0")
    sys.exit(0)
internal = set(tasks)
missing_deps = {t: [d for d in info["depends_on"] if d not in internal] for t, info in tasks.items()}
graph = {t: [d for d in info["depends_on"] if d in internal] for t, info in tasks.items()}
adj, indegree = defaultdict(list), {t: 0 for t in tasks}
for t, deps in graph.items():
    for d in deps: adj[d].append(t); indegree[t] += 1
for d in adj: adj[d].sort()
WHITE, GRAY, BLACK = 0, 1, 2
color = {t: WHITE for t in tasks}
cycles, seen = [], set()
def norm(c):
    core = c[:-1]
    return tuple(c) if not core else min(tuple(core[i:] + core[:i]) for i in range(len(core)))
def dfs(n, stack):
    color[n] = GRAY; stack.append(n)
    for dep in graph[n]:
        if color[dep] == WHITE: dfs(dep, stack)
        elif color[dep] == GRAY:
            cyc = stack[stack.index(dep):] + [dep]; key = norm(cyc)
            if key not in seen: seen.add(key); cycles.append(cyc)
    stack.pop(); color[n] = BLACK
for t in sorted(tasks):
    if color[t] == WHITE: dfs(t, [])
cycle_nodes = {n for cyc in cycles for n in cyc[:-1]}
heap = [t for t, d in indegree.items() if d == 0]; heapq.heapify(heap)
in_deg, topo, levels = dict(indegree), [], {}
while heap:
    t = heapq.heappop(heap); topo.append(t)
    deps = [d for d in graph[t] if d in levels]
    levels[t] = max((levels[d] for d in deps), default=-1) + 1
    for nxt in adj.get(t, []):
        in_deg[nxt] -= 1
        if in_deg[nxt] == 0: heapq.heappush(heap, nxt)
unresolved_nodes = sorted(t for t in tasks if t not in levels)
if unresolved_nodes:
    fill = max(levels.values(), default=-1) + 1
    for t in unresolved_nodes: levels[t] = fill
dist, prev = {}, {}
for t in topo:
    deps = [d for d in graph[t] if d in dist]
    if deps:
        best = max(deps, key=lambda d: (dist[d], d)); dist[t] = dist[best] + 1; prev[t] = best
    else: dist[t] = 1
critical_path = []
if dist:
    cur = max(sorted(dist), key=lambda t: (dist[t], t))
    while True:
        critical_path.append(cur)
        if cur not in prev: break
        cur = prev[cur]
    critical_path.reverse()
critical = set(critical_path)
for t in tasks: tasks[t]["level"], tasks[t]["is_critical"] = levels[t], t in critical
summary = {"total_tasks": len(tasks), "parallel_groups": max(levels.values(), default=-1) + 1, "critical_path_length": len(critical_path)}
if mode == "json":
    by_level = defaultdict(list)
    for t in sorted(tasks): by_level[levels[t]].append(t)
    print(json.dumps({
        "batch_dir": batch_dir, "adjacency": {k: adj.get(k, []) for k in sorted(tasks)},
        "levels": [by_level[i] for i in sorted(by_level)], "critical_path": critical_path,
        "cycles": cycles, "missing_deps": missing_deps, "tasks": tasks, "summary": summary,
    }, indent=2))
elif mode == "mermaid":
    print("graph LR")
    ids, used = {}, set()
    def sid(name):
        base = re.sub(r"[^A-Za-z0-9_]", "_", name); base = "n_" + base if (not base or base[0].isdigit()) else base
        out, i = base, 2
        while out in used: out, i = f"{base}_{i}", i + 1
        used.add(out); return out
    for t in sorted(tasks):
        ids[t] = sid(t); lbl = t if simple else f"{t}<br/>({tasks[t]['agent']})"
        print(f'  {ids[t]}["{lbl}"]')
    for t in sorted(tasks):
        for d in graph[t]: print(f"  {ids[d]} --> {ids[t]}")
    colors = [("#e1f5fe","#01579b"),("#f3e5f5","#4a148c"),("#e8f5e9","#1b5e20"),("#fff3e0","#e65100")]
    for i, a in enumerate(sorted({tasks[t]["agent"] for t in tasks})):
        fill, stroke = colors[i % len(colors)]; cls = f"agent_{i}"
        print(f"  classDef {cls} fill:{fill},stroke:{stroke},stroke-width:1px")
        nodes = ",".join(ids[t] for t in sorted(tasks) if tasks[t]["agent"] == a)
        if nodes: print(f"  class {nodes} {cls}")
    if show_critical and critical_path:
        print("  classDef critical stroke:#d50000,stroke-width:3px")
        print(f"  class {','.join(ids[t] for t in critical_path)} critical")
        print(f"  %% critical-path: {' -> '.join(critical_path)}")
    for cyc in cycles: print(f"  %% cycle: {' -> '.join(cyc)}")
    for t in sorted(tasks):
        if missing_deps[t]: print(f"  %% warning: {t} missing deps: {', '.join(missing_deps[t])}")
    print(f"  %% summary: total tasks={summary['total_tasks']}, parallel groups={summary['parallel_groups']}, critical path length={summary['critical_path_length']}")
else:
    print(f"DAG {batch_dir}")
    if show_critical and critical_path: print(clip(f"Critical path: {' -> '.join(critical_path)}"))
    by_level = defaultdict(list)
    for t in sorted(tasks): by_level[levels[t]].append(t)
    for lvl in sorted(by_level):
        for t in by_level[lvl]:
            label = t if simple else f"{t}({tasks[t]['agent']})"; pref = "*" if show_critical and t in critical else " "
            deps = ",".join(graph[t]); line = f"{pref}[{lvl}] {label}" + (f" <- {deps}" if deps else "")
            if t in cycle_nodes: line += " (cycle)"
            elif t in unresolved_nodes: line += " (blocked-by-cycle)"
            if missing_deps[t]: line += f" (missing: {','.join(missing_deps[t])})"
            print(clip(line))
    for cyc in cycles: print(clip(f"WARNING: cycle detected: {' -> '.join(cyc)}"))
    print(clip(f"Summary: total tasks={summary['total_tasks']}, parallel groups={summary['parallel_groups']}, critical path length={summary['critical_path_length']}"))
PYEOF
