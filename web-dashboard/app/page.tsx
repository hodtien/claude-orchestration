"use client";

import { useEffect, useState } from "react";

type TaskRow = {
  ts?: string;
  timestamp?: string;
  event?: string;
  task_id?: string;
  agent?: string;
  status?: string;
  outcome?: string;
  duration_s?: number;
  prompt_chars?: number;
  output_chars?: number;
};

type AgentCost = {
  agent: string;
  calls: number;
  tokens_in: number;
  tokens_out: number;
  cost_usd: number;
};

type TasksPayload = {
  source: string;
  count: number;
  tasks: TaskRow[];
};

type CostPayload = {
  source: string;
  totals: {
    calls: number;
    tokens_in: number;
    tokens_out: number;
    cost_usd: number;
  };
  per_agent: AgentCost[];
};

function pillClass(t: TaskRow): string {
  const s = (t.status || t.outcome || t.event || "").toLowerCase();
  if (s.includes("succ") || s.includes("complete") || s.includes("done"))
    return "pill ok";
  if (s.includes("fail") || s.includes("error") || s.includes("exhaust"))
    return "pill err";
  if (s.includes("start") || s.includes("running") || s.includes("attempt"))
    return "pill warn";
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

export default function Page() {
  const [tasks, setTasks] = useState<TasksPayload | null>(null);
  const [cost, setCost] = useState<CostPayload | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [lastTick, setLastTick] = useState<string>("");

  useEffect(() => {
    let cancelled = false;
    const fetchAll = async () => {
      try {
        const [tRes, cRes] = await Promise.all([
          fetch("/api/tasks", { cache: "no-store" }),
          fetch("/api/cost", { cache: "no-store" })
        ]);
        const t = (await tRes.json()) as TasksPayload;
        const c = (await cRes.json()) as CostPayload;
        if (!cancelled) {
          setTasks(t);
          setCost(c);
          setErr(null);
          setLastTick(new Date().toISOString().replace("T", " ").slice(0, 19));
        }
      } catch (e: unknown) {
        if (!cancelled) setErr(e instanceof Error ? e.message : String(e));
      }
    };
    fetchAll();
    const id = setInterval(fetchAll, 5000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  const recent = tasks?.tasks?.slice(0, 50) ?? [];
  const running = recent.filter((r) =>
    /(start|running|attempt)/i.test(r.status || r.event || "")
  ).length;
  const succeeded = recent.filter((r) =>
    /(succ|complete|done)/i.test(r.status || r.outcome || r.event || "")
  ).length;
  const failed = recent.filter((r) =>
    /(fail|error|exhaust)/i.test(r.status || r.outcome || r.event || "")
  ).length;

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
                  <td>{r.task_id || "—"}</td>
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
    </main>
  );
}
