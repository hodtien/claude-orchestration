#!/usr/bin/env bash
# _dashboard/db.sh — Metrics DB admin
# Sourced by orch-dashboard.sh. Subcommands: import, import --full, trends [--days N], compare, slow [--top N], rollup, status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DB_PATH="$PROJECT_ROOT/.orchestration/metrics.db"
LOG_PATH="$PROJECT_ROOT/.orchestration/tasks.jsonl"
mkdir -p "$PROJECT_ROOT/.orchestration"

python3 - "$DB_PATH" "$LOG_PATH" "$@" <<'PY'
import json, os, sqlite3, sys
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

USAGE = """Usage:
  db import
  db import --full
  db trends
  db trends --days 30
  db compare <batch-a> <batch-b>
  db slow [--top N]
  db rollup
  db status"""
SPARK = "▁▂▃▄▅▆▇█"

def die(msg=""):
    if msg: print(msg, file=sys.stderr)
    print(USAGE, file=sys.stderr); sys.exit(1)
def to_int(v, d=0):
    try: return int(v)
    except Exception: return d
def now_iso(): return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def norm_ts(v):
    s = str(v or "").strip()
    if not s: return now_iso()
    try: return datetime.fromisoformat(s.replace("Z","+00:00")).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception: return s
def mget(c, k, d=""):
    row = c.execute("SELECT value FROM meta WHERE key=?",(k,)).fetchone()
    return row[0] if row else d
def mset(c, k, v):
    c.execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(k,str(v)))
def percentile(vals, p):
    if not vals: return 0.0
    arr = sorted(vals); i = (len(arr)-1)*p; lo,hi = int(i),min(int(i)+1,len(arr)-1)
    return float(arr[lo] if lo==hi else arr[lo]*(hi-i)+arr[hi]*(i-lo))
def sparkline(values):
    present = [v for v in values if v is not None]
    if not present: return SPARK[0]*len(values)
    lo,hi = min(present),max(present); span = hi-lo if hi!=lo else 1
    return "".join(SPARK[int(round(((lo if v is None else v)-lo)/span*(len(SPARK)-1)))] for v in values)
def rate_bar(pct, width=10):
    pct = max(0.0,min(100.0,pct)); fill = int(round(width*pct/100.0))
    return "█"*fill+"░"*(width-fill)

def init_schema(c):
    c.executescript("""
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS task_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, event TEXT NOT NULL, task_id TEXT NOT NULL,
      agent TEXT NOT NULL, project TEXT DEFAULT '', status TEXT DEFAULT '', duration_s INTEGER DEFAULT 0,
      prompt_chars INTEGER DEFAULT 0, output_chars INTEGER DEFAULT 0, error TEXT DEFAULT '', line_no INTEGER,
      UNIQUE(ts,event,task_id)
    );
    CREATE TABLE IF NOT EXISTS tasks (
      task_id TEXT PRIMARY KEY, agent TEXT, project TEXT, status TEXT, start_ts TEXT, end_ts TEXT,
      duration_s INTEGER DEFAULT 0, prompt_chars INTEGER DEFAULT 0, output_chars INTEGER DEFAULT 0,
      retry_count INTEGER DEFAULT 0, error TEXT
    );
    CREATE TABLE IF NOT EXISTS daily_rollups (
      day TEXT NOT NULL, agent TEXT NOT NULL, total_tasks INTEGER NOT NULL, success_count INTEGER NOT NULL,
      failure_count INTEGER NOT NULL, avg_duration_s REAL NOT NULL, p50_duration_s REAL NOT NULL, p95_duration_s REAL NOT NULL,
      total_prompt_chars INTEGER NOT NULL, total_output_chars INTEGER NOT NULL, PRIMARY KEY(day,agent)
    );
    CREATE INDEX IF NOT EXISTS idx_events_task_id ON task_events(task_id);
    CREATE INDEX IF NOT EXISTS idx_tasks_end_ts ON tasks(end_ts);
    """)
    need = {"day","agent","total_tasks","success_count","failure_count","avg_duration_s","p50_duration_s","p95_duration_s","total_prompt_chars","total_output_chars"}
    have = {r[1] for r in c.execute("PRAGMA table_info(daily_rollups)")}
    if have and not need.issubset(have):
        c.execute("DROP TABLE daily_rollups")
        c.execute("""CREATE TABLE daily_rollups (
          day TEXT NOT NULL, agent TEXT NOT NULL, total_tasks INTEGER NOT NULL, success_count INTEGER NOT NULL,
          failure_count INTEGER NOT NULL, avg_duration_s REAL NOT NULL, p50_duration_s REAL NOT NULL, p95_duration_s REAL NOT NULL,
          total_prompt_chars INTEGER NOT NULL, total_output_chars INTEGER NOT NULL, PRIMARY KEY(day,agent))""")
    mset(c,"last_line_count",mget(c,"last_line_count","0")); c.connection.commit()

def parse_event(raw):
    try: obj = json.loads(raw.strip())
    except Exception: return None
    if not isinstance(obj,dict): return None
    event, task_id = str(obj.get("event","")).strip().lower(), str(obj.get("task_id","").strip())
    if not event or not task_id: return None
    out = obj.get("output",""); out_len = len(out) if isinstance(out,str) else 0
    return {
        "ts": norm_ts(obj.get("ts")), "event": event, "task_id": task_id,
        "agent": str(obj.get("agent","unknown") or "unknown"), "project": str(obj.get("project","") or ""),
        "status": str(obj.get("status","") or ""), "duration_s": to_int(obj.get("duration_s",0),0),
        "prompt_chars": to_int(obj.get("prompt_chars",0),0), "output_chars": to_int(obj.get("output_chars",out_len),out_len),
        "error": str(obj.get("error","") or "")
    }

def upsert_task(c, e):
    if e["event"] == "start":
        c.execute("""INSERT INTO tasks(task_id,agent,project,status,start_ts,prompt_chars,output_chars,duration_s,error,retry_count)
                     VALUES(?,?,?,?,?,?,?,?,?,0)
                     ON CONFLICT(task_id) DO UPDATE SET
                     agent=excluded.agent, project=excluded.project, status=COALESCE(NULLIF(excluded.status,''),tasks.status,'running'),
                     start_ts=COALESCE(tasks.start_ts,excluded.start_ts),
                     prompt_chars=MAX(COALESCE(tasks.prompt_chars,0),excluded.prompt_chars),
                     output_chars=MAX(COALESCE(tasks.output_chars,0),excluded.output_chars)""",
                  (e["task_id"],e["agent"],e["project"],e["status"] or "running",e["ts"],e["prompt_chars"],e["output_chars"],e["duration_s"],e["error"]))
    elif e["event"] == "retry":
        c.execute("""INSERT INTO tasks(task_id,agent,project,status,retry_count,error)
                     VALUES(?,?,?,?,1,?)
                     ON CONFLICT(task_id) DO UPDATE SET
                     agent=excluded.agent, project=excluded.project, status=COALESCE(NULLIF(excluded.status,''),tasks.status,'retrying'),
                     retry_count=COALESCE(tasks.retry_count,0)+1, error=COALESCE(NULLIF(excluded.error,''),tasks.error)""",
                  (e["task_id"],e["agent"],e["project"],e["status"] or "retrying",e["error"]))
    elif e["event"] == "complete":
        c.execute("""INSERT INTO tasks(task_id,agent,project,status,end_ts,duration_s,prompt_chars,output_chars,error,retry_count)
                     VALUES(?,?,?,?,?,?,?,?,?,0)
                     ON CONFLICT(task_id) DO UPDATE SET
                     agent=excluded.agent, project=excluded.project, status=COALESCE(NULLIF(excluded.status,''),tasks.status,'unknown'),
                     end_ts=excluded.end_ts, duration_s=excluded.duration_s,
                     prompt_chars=MAX(COALESCE(tasks.prompt_chars,0),excluded.prompt_chars),
                     output_chars=MAX(COALESCE(tasks.output_chars,0),excluded.output_chars),
                     error=COALESCE(NULLIF(excluded.error,''),tasks.error)""",
                  (e["task_id"],e["agent"],e["project"],e["status"] or "unknown",e["ts"],e["duration_s"],e["prompt_chars"],e["output_chars"],e["error"]))

def recompute_rollups(c):
    c.execute("DELETE FROM daily_rollups")
    groups = defaultdict(lambda: {"n":0,"ok":0,"fail":0,"dur":[],"pc":0,"oc":0})
    q = """SELECT substr(COALESCE(end_ts,start_ts),1,10),COALESCE(agent,'unknown'),COALESCE(status,''),COALESCE(duration_s,0),
                  COALESCE(prompt_chars,0),COALESCE(output_chars,0) FROM tasks WHERE COALESCE(end_ts,start_ts) IS NOT NULL"""
    for day, agent, status, dur, pchars, ochars in c.execute(q):
        g = groups[(day,agent)]; g["n"]+=1; g["ok"]+=1 if status=="success" else 0
        g["fail"]+=1 if status in ("failed","exhausted","error") else 0
        if dur > 0: g["dur"].append(dur)
        g["pc"]+=pchars; g["oc"]+=ochars
    for (day,agent),g in groups.items():
        avg = sum(g["dur"])/len(g["dur"]) if g["dur"] else 0.0
        c.execute("INSERT INTO daily_rollups VALUES (?,?,?,?,?,?,?,?,?,?)",
                  (day,agent,g["n"],g["ok"],g["fail"],round(avg,2),round(percentile(g["dur"],0.5),2),round(percentile(g["dur"],0.95),2),g["pc"],g["oc"]))
    return len(groups)

def run_import(c, src, full=False):
    if full:
        c.executescript("DELETE FROM task_events; DELETE FROM tasks; DELETE FROM daily_rollups;")
        mset(c,"last_line_count",0)
    if not os.path.exists(src) or os.path.getsize(src)==0:
        mset(c,"last_import_ts",now_iso()); c.connection.commit()
        print("Import complete: source missing/empty; nothing imported."); return
    with open(src,"r",encoding="utf-8",errors="replace") as f: total = sum(1 for _ in f)
    last = 0 if full else to_int(mget(c,"last_line_count","0"),0)
    if total < last:
        c.executescript("DELETE FROM task_events; DELETE FROM tasks; DELETE FROM daily_rollups;"); last = 0
    ingested = skipped = dup = 0
    with open(src,"r",encoding="utf-8",errors="replace") as f:
        for line_no, raw in enumerate(f,1):
            if line_no <= last: continue
            e = parse_event(raw)
            if not e: skipped+=1; continue
            cur = c.execute("""INSERT OR IGNORE INTO task_events(ts,event,task_id,agent,project,status,duration_s,prompt_chars,output_chars,error,line_no)
                               VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                            (e["ts"],e["event"],e["task_id"],e["agent"],e["project"],e["status"],e["duration_s"],e["prompt_chars"],e["output_chars"],e["error"],line_no))
            if cur.rowcount == 1: upsert_task(c,e); ingested+=1
            else: dup+=1
    nroll = recompute_rollups(c); mset(c,"last_line_count",total); mset(c,"last_import_ts",now_iso()); c.connection.commit()
    print(f"Import complete: {ingested} ingested, {skipped} skipped, {dup} duplicates, rollups={nroll}, last_line_count={total}.")

def trends(c, days):
    start = (date.today()-timedelta(days=days-1)).isoformat()
    rows = c.execute("""SELECT agent,SUM(total_tasks),SUM(success_count),
                        CASE WHEN SUM(total_tasks)>0 THEN SUM(avg_duration_s*total_tasks)/SUM(total_tasks) ELSE 0 END
                        FROM daily_rollups WHERE day>=? GROUP BY agent ORDER BY SUM(total_tasks) DESC,agent""",(start,)).fetchall()
    print(f"Agent Trends (last {days} days)\n{'='*52}")
    if not rows: print("No metrics available."); return
    days_list = [(date.today()-timedelta(days=i)).isoformat() for i in range(days-1,-1,-1)]
    by_day = {(a,d):v for a,d,v in c.execute("SELECT agent,day,avg_duration_s FROM daily_rollups WHERE day>=?",(start,))}
    for agent,total,ok,avg in rows:
        pct = 100.0*(ok or 0)/(total or 1) if total else 0.0
        print(f"{agent:<12} [{rate_bar(pct)}] {pct:6.1f}%  avg {int(round(avg or 0)):>4}s  tasks {total}")
    print("\nDuration trend (avg_s/day):")
    for agent,*_ in rows:
        vals = [by_day.get((agent,d)) for d in days_list]
        print(f"{agent:<12} {sparkline(vals)}  {' '.join('-' if v is None else str(int(round(v))) for v in vals)}")

def batch_stats(c, b):
    q = """SELECT COUNT(*),SUM(CASE WHEN status='success' THEN 1 ELSE 0 END),
           SUM(CASE WHEN status IN ('failed','exhausted','error') THEN 1 ELSE 0 END),
           AVG(CASE WHEN duration_s>0 THEN duration_s END),MIN(NULLIF(duration_s,0)),MAX(NULLIF(duration_s,0))
           FROM tasks WHERE task_id=? OR task_id LIKE ?"""
    total,ok,fail,avg,fast,slow = c.execute(q,(b,f"{b}-%")).fetchone()
    return [total or 0,f"{(100.0*(ok or 0)/(total or 1)):.0f}%" if total else "0%",int(round(avg or 0)),fail or 0,f"{int(fast)}s" if fast else "-",f"{int(slow)}s" if slow else "-"]
def compare(c, a, b):
    A, B = batch_stats(c,a), batch_stats(c,b)
    print("Batch Comparison\n"+"="*52); print(f"{'Metric':<18} {a:<16} {b:<16}")
    for i,m in enumerate(["Total tasks","Success rate","Avg duration (s)","Failed tasks","Fastest task","Slowest task"]):
        print(f"{m:<18} {str(A[i]):<16} {str(B[i]):<16}")

def slow(c, top):
    rows = c.execute("SELECT task_id,COALESCE(agent,'unknown'),COALESCE(status,''),duration_s FROM tasks WHERE duration_s>0 ORDER BY duration_s DESC LIMIT ?",(top,)).fetchall()
    print(f"Slowest tasks (top {top})"); print(f"{'task_id':<42} {'agent':<12} {'status':<10} {'duration':>8}")
    for tid,agent,status,dur in rows: print(f"{tid[:42]:<42} {agent[:12]:<12} {status[:10]:<10} {int(dur):>7}s")
    if not rows: print("(no completed tasks with duration)")

def status(c, src, db):
    src_lines = sum(1 for _ in open(src,"r",encoding="utf-8",errors="replace")) if os.path.exists(src) else 0
    imported = to_int(mget(c,"last_line_count","0"),0)
    print("DB status")
    print(f"  db_path:         {db}")
    print(f"  events rows:     {c.execute('SELECT COUNT(*) FROM task_events').fetchone()[0]}")
    print(f"  tasks rows:      {c.execute('SELECT COUNT(*) FROM tasks').fetchone()[0]}")
    print(f"  rollups rows:    {c.execute('SELECT COUNT(*) FROM daily_rollups').fetchone()[0]}")
    print(f"  source_lines:    {src_lines}")
    print(f"  last_line_count: {imported}")
    print(f"  backlog_lines:   {max(0,src_lines-imported)}")
    print(f"  last_import_ts:  {mget(c,'last_import_ts','n/a')}")

if len(sys.argv) < 4: die()
db_path, src_path, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
conn = sqlite3.connect(db_path); cur = conn.cursor(); init_schema(cur)
try:
    if cmd == "import":
        if args not in ([],["--full"]): die()
        run_import(cur, src_path, args == ["--full"])
    elif cmd == "trends":
        days = 7 if not args else (max(1,to_int(args[1],7)) if len(args)==2 and args[0]=="--days" else die())
        trends(cur, days)
    elif cmd == "compare":
        if len(args) != 2: die()
        compare(cur, args[0], args[1])
    elif cmd == "slow":
        top = 10 if not args else (max(1,to_int(args[1],10)) if len(args)==2 and args[0]=="--top" else die())
        slow(cur, top)
    elif cmd == "rollup":
        if args: die()
        print(f"Rollup complete: {recompute_rollups(cur)} day/agent rows updated."); conn.commit()
    elif cmd == "status":
        if args: die()
        status(cur, src_path, db_path)
    else:
        die()
finally:
    conn.close()
PY