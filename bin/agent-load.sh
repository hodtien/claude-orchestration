#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$PROJECT_ROOT/.orchestration/agent-load.json"
mkdir -p "$(dirname "$STATE_FILE")"
usage(){ echo "Usage: agent-load.sh [status|increment <agent>|decrement <agent>|least-loaded <agent...>]" >&2; }
ensure(){
  python3 - "$STATE_FILE" <<'PY'
import json,os,sys; p=sys.argv[1]
if os.path.exists(p): raise SystemExit(0)
t=f"{p}.tmp"; json.dump({"copilot":0,"gemini":0}, open(t,"w",encoding="utf-8"), sort_keys=True); os.replace(t,p)
PY
}
status_cmd(){
  ensure
  python3 - "$STATE_FILE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8")); print(f"{'agent':<16} active_count")
for k in sorted(d): print(f"{k:<16} {max(0,int(d.get(k,0) or 0))}")
PY
}
mutate(){
  ensure
  python3 - "$STATE_FILE" "$1" "$2" <<'PY'
import fcntl,json,os,sys
p,op,a=sys.argv[1],sys.argv[2],sys.argv[3]
with open(f"{p}.lock","w",encoding="utf-8") as lk:
  fcntl.flock(lk, fcntl.LOCK_EX)
  d=json.load(open(p,encoding="utf-8")); d.setdefault("copilot",0); d.setdefault("gemini",0); d.setdefault(a,0)
  v=max(0,int(d.get(a,0) or 0)); d[a]=v+1 if op=="increment" else max(0,v-1)
  t=f"{p}.tmp"; json.dump(d, open(t,"w",encoding="utf-8"), sort_keys=True); os.replace(t,p)
print(max(0,int(d.get(a,0) or 0)))
PY
}
least_loaded(){
  ensure; [ "$#" -gt 0 ] || { usage; exit 2; }
  python3 - "$STATE_FILE" "$@" <<'PY'
import json,sys
p,c=sys.argv[1],[x for x in sys.argv[2:] if x]; d=json.load(open(p,encoding="utf-8"))
for a in c: d.setdefault(a,0)
print(min(c, key=lambda n:(max(0,int(d.get(n,0) or 0)),n)))
PY
}
case "${1:-status}" in
  status) status_cmd;;
  increment) [ $# -eq 2 ] || { usage; exit 2; }; mutate increment "$2";;
  decrement) [ $# -eq 2 ] || { usage; exit 2; }; mutate decrement "$2";;
  least-loaded) shift; least_loaded "$@";;
  *) usage; exit 2;;
esac
