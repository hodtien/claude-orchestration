#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/.." && pwd))"
ORCH_DIR="$PROJECT_ROOT/.orchestration"
SCHEDULE_DIR="$ORCH_DIR/scheduled-tasks"
TASKS_DIR="$ORCH_DIR/tasks"
LOG_FILE="$ORCH_DIR/tasks.jsonl"
DISPATCH_SH="$PROJECT_ROOT/bin/task-dispatch.sh"
mkdir -p "$SCHEDULE_DIR" "$TASKS_DIR" "$ORCH_DIR"

NOTIFY_SH="$SCRIPT_DIR/orch-notify-send.sh"

python3 - "$PROJECT_ROOT" "$SCHEDULE_DIR" "$TASKS_DIR" "$LOG_FILE" "$DISPATCH_SH" "$NOTIFY_SH" "$@" <<'PY'
import fcntl,json,os,re,secrets,shutil,subprocess,sys
from datetime import datetime,timedelta,timezone
from pathlib import Path
try: from zoneinfo import ZoneInfo
except Exception: ZoneInfo=None
project_root=Path(sys.argv[1]); schedule_dir=Path(sys.argv[2]); tasks_dir=Path(sys.argv[3])
log_file=Path(sys.argv[4]); dispatch_sh=Path(sys.argv[5]); notify_sh=Path(sys.argv[6]); args=sys.argv[7:]
SCHED_KEYS={"schedule","schedule_tz","last_run","next_run","enabled"}
def usage():
    print("Usage:\n  task-schedule.sh list\n  task-schedule.sh run-due [--dry-run]\n  task-schedule.sh enable <id>\n  task-schedule.sh disable <id>\n  task-schedule.sh trigger <id>\n  task-schedule.sh next <id>",file=sys.stderr)
def split_frontmatter(text):
    m=re.match(r"^---\s*\n(.*?)\n---\s*\n?(.*)\Z",text,re.DOTALL)
    if not m: raise ValueError("missing YAML frontmatter")
    return m.group(1),m.group(2)
def parse_value(raw):
    v=raw.strip()
    if v and v[0] not in ('"',"'",'['): v=re.sub(r"\s+#.*$","",v).strip()
    if len(v)>=2 and v[0]==v[-1] and v[0] in ('"',"'"): return v[1:-1]
    l=v.lower()
    if l in ("true","false"): return l=="true"
    if v.startswith('[') and v.endswith(']'):
        return [p.strip().strip('"').strip("'") for p in v[1:-1].split(',') if p.strip()]
    return v

def parse_front(front_text):
    data={}
    for line in front_text.splitlines():
        s=line.strip()
        if not s or s.startswith('#'): continue
        m=re.match(r"^([A-Za-z_][\w-]*)\s*:\s*(.*)$",s)
        if m: data[m.group(1)]=parse_value(m.group(2))
    return data

def dump_value(v):
    if isinstance(v,bool): return "true" if v else "false"
    if isinstance(v,list): return "["+", ".join(json.dumps(str(i),ensure_ascii=False) for i in v)+"]"
    return json.dumps("" if v is None else str(v),ensure_ascii=False)

def read_schedule(path):
    front,body=split_frontmatter(path.read_text(encoding='utf-8')); return parse_front(front),body.rstrip()

def update_schedule(path,updates):
    front,body=split_frontmatter(path.read_text(encoding='utf-8'))
    lines=front.splitlines(); idx={}
    for i,line in enumerate(lines):
        m=re.match(r"^\s*([A-Za-z_][\w-]*)\s*:",line)
        if m: idx[m.group(1)]=i
    for k,v in updates.items():
        nl=f"{k}: {dump_value(v)}"
        if k in idx: lines[idx[k]]=nl
        else: lines.append(nl)
    path.write_text("---\n"+"\n".join(lines).rstrip()+"\n---\n\n"+body.rstrip()+"\n",encoding='utf-8')

def parse_dt(s,tz):
    if not s: return None
    t=str(s).strip().strip('"').strip("'")
    if not t: return None
    dt=datetime.fromisoformat(t[:-1]+"+00:00") if t.endswith('Z') else datetime.fromisoformat(t)
    if dt.tzinfo is None: dt=dt.replace(tzinfo=tz)
    return dt.astimezone(tz)

def fmt_utc(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def parse_field(expr,lo,hi):
    if expr=='*': return set(range(lo,hi+1)),True
    vals=set()
    for tok in expr.split(','):
        tok=tok.strip()
        if tok.startswith('*/') and tok[2:].isdigit():
            step=int(tok[2:])
            if step<=0: raise ValueError(f"invalid step in {expr}")
            vals.update(range(lo,hi+1,step))
        elif tok.isdigit():
            n=int(tok)
            if lo<=n<=hi: vals.add(n)
            elif lo==0 and hi==6 and n==7: vals.add(0)
            else: raise ValueError(f"out-of-range value {n} in {expr}")
        else:
            raise ValueError(f"unsupported cron token '{tok}' (ranges not supported)")
    return vals,False

def cron_next(expr,from_dt):
    p=expr.split()
    if len(p)!=5: raise ValueError('cron expression must have 5 fields')
    mins,_=parse_field(p[0],0,59); hrs,_=parse_field(p[1],0,23)
    dom,dom_star=parse_field(p[2],1,31); mon,_=parse_field(p[3],1,12); dow,dow_star=parse_field(p[4],0,6)
    cur=from_dt.replace(second=0,microsecond=0)+timedelta(minutes=1)
    for _ in range(60*24*366*5):
        wk=(cur.weekday()+1)%7; dom_ok=cur.day in dom; dow_ok=wk in dow
        if cur.minute in mins and cur.hour in hrs and cur.month in mon:
            if (not dom_star and not dow_star and (dom_ok or dow_ok)) or ((dom_star or dow_star) and dom_ok and dow_ok):
                return cur
        cur+=timedelta(minutes=1)
    raise ValueError('no matching time found in 5 years')

def local_tzinfo():
    if ZoneInfo is not None:
        try:
            tz_name=os.environ.get('TZ')
            if tz_name: return ZoneInfo(tz_name)
        except Exception: pass
        try:
            target=str(Path('/etc/localtime').resolve()); marker='/zoneinfo/'
            if marker in target: return ZoneInfo(target.split(marker,1)[1])
        except Exception: pass
    return datetime.now().astimezone().tzinfo or timezone.utc

def tz_for(front):
    return timezone.utc if str(front.get('schedule_tz','local')).strip().lower()=='utc' else local_tzinfo()

def compute_next(front):
    expr=str(front.get('schedule','')).strip()
    if not expr: raise ValueError('missing schedule')
    tz=tz_for(front); now_tz=datetime.now(timezone.utc).astimezone(tz)
    nxt=parse_dt(front.get('next_run',''),tz)
    if nxt is None:
        base=parse_dt(front.get('last_run',''),tz) or now_tz
        nxt=cron_next(expr,base)
    return nxt,now_tz,tz

def is_enabled(front):
    v=front.get('enabled',True)
    return v if isinstance(v,bool) else str(v).lower() in {'1','true','yes','on'}

def render_task(front,body):
    return "\n".join(["---",*[f"{k}: {dump_value(v)}" for k,v in front.items()],"---","",body.rstrip(),""])

def ensure_safe_id(sid,path):
    if not re.fullmatch(r"[A-Za-z0-9._-]+",sid):
        raise ValueError(f"{path.name}: invalid id '{sid}' (allowed: A-Za-z0-9._-)")
    return sid

def append_event(sid,sched):
    log_file.parent.mkdir(parents=True,exist_ok=True)
    with log_file.open('a',encoding='utf-8') as f:
        f.write(json.dumps({"event":"scheduled_dispatch","id":sid,"schedule":sched,"ts":fmt_utc(datetime.now(timezone.utc))})+"\n")

def notify_scheduled(sid,sched_expr,tid,tz,next_run_str):
    """Fire scheduled_dispatch notification u2014 never raises."""
    try:
        if not notify_sh.is_file(): return
        payload=json.dumps({'schedule_id':sid,'schedule_expr':sched_expr,'schedule_tz':str(tz),'dispatched_task_id':tid,'next_run':next_run_str})
        subprocess.Popen([str(notify_sh),'scheduled_dispatch',payload],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    except Exception: pass

def validate_unique_ids(rows):
    ids={}
    for p,front,_ in rows:
        tz_raw=str(front.get('schedule_tz','local')); tz=tz_raw.strip().lower()
        if tz not in {'local','utc'}: raise SystemExit(f"[schedule] {p.name}: invalid schedule_tz '{tz_raw}' (must be local or UTC)")
        sid=str(front.get('id','')).strip()
        if sid: ids.setdefault(sid,[]).append(p.name)
    dup={sid:names for sid,names in ids.items() if len(names)>1}
    if dup:
        msg="; ".join(f"'{sid}' in {', '.join(sorted(names))}" for sid,names in sorted(dup.items()))
        raise SystemExit(f"[schedule] duplicate id value(s): {msg}")

def dispatch_one(path,front,body,dry_run):
    sid=str(front.get('id','')).strip()
    if not sid: raise ValueError(f"{path.name}: missing id")
    sid=ensure_safe_id(sid,path)
    stamp=datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S%f')[:-3]
    uniq=f"{stamp}-{secrets.token_hex(2)}"
    tid=f"scheduled-{sid}-{uniq}"; batch_dir=tasks_dir/f".scheduled-{sid}-{uniq}"
    task_front={k:v for k,v in front.items() if k not in SCHED_KEYS}
    task_front['id']=tid; task_front.setdefault('agent','gemini'); task_front.setdefault('task_type','')
    if dry_run:
        print(f"[dry-run] due: {sid} -> {tid}")
        return
    batch_dir.mkdir(parents=True,exist_ok=True)
    (batch_dir/'task-1.md').write_text(render_task(task_front,body),encoding='utf-8')
    try:
        subprocess.run([str(dispatch_sh),str(batch_dir)],check=True,cwd=str(project_root))
    finally:
        shutil.rmtree(batch_dir,ignore_errors=True)

def load_all():
    rows=[(p,*read_schedule(p)) for p in sorted(schedule_dir.glob('*.schedule.md'))]; validate_unique_ids(rows); return rows

def find_by_id(task_id):
    matches=[(p,front,body) for p,front,body in load_all() if str(front.get('id','')).strip()==task_id]
    if matches: return matches[0]
    raise SystemExit(f"[schedule] id not found: {task_id}")

if not args: usage(); raise SystemExit(1)
cmd=args[0]
if cmd=='list':
    rows=load_all()
    if not rows: print(f"[schedule] no schedules found in {schedule_dir}"); raise SystemExit(0)
    for p,front,_ in rows:
        sid=str(front.get('id',p.stem)).strip()
        try:
            nxt,now_tz,_=compute_next(front); due=is_enabled(front) and nxt<=now_tz; nxt_txt=fmt_utc(nxt)
        except Exception as e:
            due=False; nxt_txt=f"error: {e}"
        dflag='\tDUE' if due else ''
        print(f"{sid}\tenabled={str(is_enabled(front)).lower()}\tnext_run={nxt_txt}\tschedule={front.get('schedule','')}\ttz={front.get('schedule_tz','local')}{dflag}")

elif cmd=='run-due':
    dry_run=len(args)>1 and args[1]=='--dry-run'; ran=0; failures=0
    if not dry_run:
        lockf=(schedule_dir.parent/'task-schedule.run-due.lock').open('w')
        try: fcntl.flock(lockf,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise SystemExit("[schedule] run-due already in progress (lock held)")
    for p,front,body in load_all():
        if not is_enabled(front): continue
        try:
            nxt,now_tz,tz=compute_next(front)
            if nxt<=now_tz:
                dispatch_one(p,front,body,dry_run); ran+=1
                if not dry_run:
                    now_utc=datetime.now(timezone.utc)
                    nxt2=cron_next(str(front.get('schedule','')).strip(),now_utc.astimezone(tz))
                    update_schedule(p,{"last_run":fmt_utc(now_utc),"next_run":fmt_utc(nxt2)})
                    append_event(str(front.get('id','')),str(front.get('schedule','')))
                    notify_scheduled(str(front.get('id','')),str(front.get('schedule','')),tid,str(front.get('schedule_tz','local')),fmt_utc(nxt2))
            elif not dry_run:
                update_schedule(p,{"next_run":fmt_utc(nxt)})
        except Exception as e:
            failures+=1; print(f"[schedule] error in {p.name}: {e}",file=sys.stderr)
    mode='dry-run' if dry_run else 'run'
    print(f"[schedule] {mode} complete: dispatched={ran} failures={failures}")
    raise SystemExit(1 if failures else 0)

elif cmd in {'enable','disable','trigger','next'}:
    if len(args)<2: usage(); raise SystemExit(1)
    p,front,body=find_by_id(args[1])
    if cmd=='enable':
        nxt,_,_=compute_next({**front,"enabled":True})
        update_schedule(p,{"enabled":True,"next_run":fmt_utc(nxt)})
        print(f"[schedule] enabled {args[1]}")
    elif cmd=='disable':
        update_schedule(p,{"enabled":False}); print(f"[schedule] disabled {args[1]}")
    elif cmd=='trigger':
        dispatch_one(p,front,body,False)
        now_utc=datetime.now(timezone.utc); nxt=cron_next(str(front.get('schedule','')).strip(),now_utc.astimezone(tz_for(front)))
        update_schedule(p,{"last_run":fmt_utc(now_utc),"next_run":fmt_utc(nxt)})
        append_event(str(front.get('id','')),str(front.get('schedule','')))
        notify_scheduled(str(front.get('id','')),str(front.get('schedule','')),'',str(front.get('schedule_tz','local')),fmt_utc(nxt))
        print(f"[schedule] triggered {args[1]}")
    else:
        nxt,_,_=compute_next(front); print(fmt_utc(nxt))
else:
    usage(); raise SystemExit(1)
PY
