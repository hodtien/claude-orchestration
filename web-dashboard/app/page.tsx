"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  isRunning,
  isTerminal,
  type CostPayload,
  type TaskEvent,
  type TasksPayload
} from "@/lib/types";
import TraceDrawer from "./TraceDrawer";
import BatchDagPanel from "./BatchDagPanel";
import FailuresPanel from "./FailuresPanel";

function pillClass(t: TaskEvent): string {
  if (isTerminal(t)) {
    const s = (t.status || t.outcome || t.event || "").toLowerCase();
    if (/(succ|complete|done)/.test(s)) return "pill ok";
    return "pill err";
  }
  if (isRunning(t)) return "pill warn";
  return "pill dim";
}

function fmtNum(n: number | undefined): string {
  if (n === undefined || n === null || Number.isNaN(n)) return "—";
  return n.toLocaleString();
}

function fmtUsd(n: number): string {
  if (!n) return "$0.0000";
  return "$" + n.toFixed(4);
}

function fmtTs(ts?: string): string {
  if (!ts) return "—";
  return ts.replace("T", " ").replace("Z", "");
}

const POLL_OK_MS = 5000;
const POLL_BACKOFF_MAX_MS = 60000;

export default function Page() {
  const [tasks, setTasks] = useState<TasksPayload | null>(null);
  const [cost, setCost] = useState<CostPayload | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [lastTick, setLastTick] = useState<string>("");
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const failuresRef = useRef(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const closeDrawer = useCallback(() => setSelectedTaskId(null), []);

  useEffect(() => {
    let cancelled = false;

    const schedule = (ms: number) => {
      if (cancelled) return;
      timerRef.current = setTimeout(fetchAll, ms);
    };

    const fetchAll = async () => {
      try {
        const [tRes, cRes] = await Promise.all([
          fetch("/api/tasks", { cache: "no-store" }),
          fetch("/api/cost", { cache: "no-store" })
        ]);
        if (!tRes.ok) throw new Error(`/api/tasks ${tRes.status}`);
        if (!cRes.ok) throw new Error(`/api/cost ${cRes.status}`);
        const t = (await tRes.json()) as TasksPayload;
        const c = (await cRes.json()) as CostPayload;
        if (cancelled) return;
        setTasks(t);
        setCost(c);
        setErr(null);
        failuresRef.current = 0;
        setLastTick(new Date().toISOString().replace("T", " ").slice(0, 19));
        schedule(POLL_OK_MS);
      } catch (e: unknown) {
        if (cancelled) return;
        failuresRef.current += 1;
        setErr(e instanceof Error ? e.message : String(e));
        const backoff = Math.min(
          POLL_OK_MS * 2 ** failuresRef.current,
          POLL_BACKOFF_MAX_MS
        );
        schedule(backoff);
      }
    };

    fetchAll();
    return () => {
      cancelled = true;
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, []);

  const recent = tasks?.tasks?.slice(0, 50) ?? [];
  const now = Date.now();
  const running = recent.filter((r) => isRunning(r, now)).length;
  const succeeded = recent.filter((r) => {
    if (!isTerminal(r)) return false;
    const s = (r.status || r.outcome || r.event || "").toLowerCase();
    return /(succ|complete|done)/.test(s);
  }).length;
  const failed = recent.filter((r) => {
    if (!isTerminal(r)) return false;
    const s = (r.status || r.outcome || r.event || "").toLowerCase();
    return /(fail|error|exhaust|block|cancel)/.test(s);
  }).length;

  return (
    <main>
      <header className="page">
        <h1>Claude Orchestration · Live</h1>
        <div className="meta">
          {err ? `error: ${err}` : `tick ${lastTick || "…"}`}
        </div>
      </header>

      <div className="summary-grid">
        <div className="card">
          <div className="label">Recent tasks</div>
          <div className="value">{recent.length}</div>
        </div>
        <div className="card">
          <div className="label">Running</div>
          <div className="value">{running}</div>
        </div>
        <div className="card">
          <div className="label">Succeeded</div>
          <div className="value">{succeeded}</div>
        </div>
        <div className="card">
          <div className="label">Failed</div>
          <div className="value">{failed}</div>
        </div>
        <div className="card">
          <div className="label">Cost (logged)</div>
          <div className="value">{fmtUsd(cost?.totals.cost_usd ?? 0)}</div>
        </div>
      </div>

      <BatchDagPanel onSelectTask={setSelectedTaskId} />

      <FailuresPanel onSelectTask={setSelectedTaskId} />

      <section className="panel">
        <h2>Recent tasks</h2>
        {recent.length === 0 ? (
          <div className="empty">No task events yet.</div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>ts</th>
                <th>task_id</th>
                <th>agent</th>
                <th>state</th>
                <th className="num">dur (s)</th>
                <th className="num">prompt</th>
                <th className="num">output</th>
              </tr>
            </thead>
            <tbody>
              {recent.map((r, i) => (
                <tr key={`${r.task_id}-${i}`}>
                  <td>{fmtTs(r.ts || r.timestamp)}</td>
                  <td>
                    {r.task_id ? (
                      <button
                        type="button"
                        className="task-link"
                        onClick={() => setSelectedTaskId(r.task_id!)}
                      >
                        {r.task_id}
                      </button>
                    ) : (
                      "—"
                    )}
                  </td>
                  <td>{r.agent || "—"}</td>
                  <td>
                    <span className={pillClass(r)}>
                      {r.status || r.outcome || r.event || "—"}
                    </span>
                  </td>
                  <td className="num">{fmtNum(r.duration_s)}</td>
                  <td className="num">{fmtNum(r.prompt_chars)}</td>
                  <td className="num">{fmtNum(r.output_chars)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section className="panel">
        <h2>Cost by agent</h2>
        {!cost || cost.per_agent.length === 0 ? (
          <div className="empty">
            No cost-tracking entries at <code>{cost?.source ?? "…"}</code>.
          </div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>agent</th>
                <th className="num">calls</th>
                <th className="num">tokens in</th>
                <th className="num">tokens out</th>
                <th className="num">cost (USD)</th>
              </tr>
            </thead>
            <tbody>
              {cost.per_agent.map((a) => (
                <tr key={a.agent}>
                  <td>{a.agent}</td>
                  <td className="num">{fmtNum(a.calls)}</td>
                  <td className="num">{fmtNum(a.tokens_in)}</td>
                  <td className="num">{fmtNum(a.tokens_out)}</td>
                  <td className="num">{fmtUsd(a.cost_usd)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      {selectedTaskId && (
        <TraceDrawer taskId={selectedTaskId} onClose={closeDrawer} />
      )}
    </main>
  );
}
