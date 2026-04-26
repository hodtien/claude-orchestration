"use client";

import { useEffect, useState } from "react";
import type { TaskEvent } from "@/lib/types";

type TaskStatus = {
  schema_version?: number;
  task_id?: string;
  final_state?: string;
  agent?: string;
  [k: string]: unknown;
};

type ReflexionBlob = {
  iteration: number;
  [k: string]: unknown;
};

type TraceResult = {
  task_id: string;
  found: boolean;
  reason?: string;
  status: TaskStatus | null;
  events: TaskEvent[];
  reflexion: ReflexionBlob[];
  truncated?: boolean;
};

interface TraceDrawerProps {
  taskId: string;
  onClose: () => void;
}

function fmtTs(ts?: string): string {
  if (!ts) return "—";
  return ts.replace("T", " ").replace("Z", "");
}

function eventClass(ev: TaskEvent): string {
  const s = (ev.status || ev.outcome || ev.event || "").toLowerCase();
  if (/(succ|complete|done)/.test(s)) return "trace-evt ok";
  if (/(fail|error|exhaust|block|cancel)/.test(s)) return "trace-evt err";
  if (/(retry|failover)/.test(s)) return "trace-evt warn";
  return "trace-evt";
}

export default function TraceDrawer({ taskId, onClose }: TraceDrawerProps) {
  const [data, setData] = useState<TraceResult | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setErr(null);
    fetch(`/api/trace/${encodeURIComponent(taskId)}`, { cache: "no-store" })
      .then(async (r) => {
        if (!r.ok) throw new Error(`/api/trace ${r.status}`);
        return (await r.json()) as TraceResult;
      })
      .then((d) => {
        if (cancelled) return;
        setData(d);
        setLoading(false);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setErr(e instanceof Error ? e.message : String(e));
        setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [taskId]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div
      className="trace-overlay"
      role="dialog"
      aria-modal="true"
      aria-label={`Task trace ${taskId}`}
      onClick={onClose}
    >
      <aside className="trace-drawer" onClick={(e) => e.stopPropagation()}>
        <header className="trace-header">
          <div>
            <div className="trace-label">Task</div>
            <div className="trace-title">{taskId}</div>
          </div>
          <button
            type="button"
            className="trace-close"
            onClick={onClose}
            aria-label="Close trace"
          >
            ×
          </button>
        </header>

        {loading && <div className="empty">Loading trace…</div>}
        {err && <div className="trace-err">error: {err}</div>}

        {!loading && !err && data && !data.found && (
          <div className="empty">
            Not found ({data.reason || "unknown reason"})
          </div>
        )}

        {!loading && !err && data && data.found && (
          <>
            <section className="trace-section">
              <h3>Status</h3>
              {data.status ? (
                <dl className="trace-kv">
                  <dt>final_state</dt>
                  <dd>{data.status.final_state || "—"}</dd>
                  <dt>agent</dt>
                  <dd>{data.status.agent || "—"}</dd>
                  <dt>schema_version</dt>
                  <dd>{data.status.schema_version ?? "—"}</dd>
                </dl>
              ) : (
                <div className="empty">No status file.</div>
              )}
            </section>

            <section className="trace-section">
              <h3>
                Events ({data.events.length})
                {data.truncated && (
                  <span className="trace-trunc"> · truncated</span>
                )}
              </h3>
              {data.events.length === 0 ? (
                <div className="empty">No events.</div>
              ) : (
                <ol className="trace-timeline">
                  {data.events.map((ev, i) => (
                    <li key={i} className={eventClass(ev)}>
                      <span className="trace-ts">
                        {fmtTs(ev.ts || ev.timestamp)}
                      </span>
                      <span className="trace-evt-name">
                        {ev.event || ev.status || "—"}
                      </span>
                      {ev.agent && (
                        <span className="trace-evt-meta">{ev.agent}</span>
                      )}
                      {typeof ev.duration_s === "number" && (
                        <span className="trace-evt-meta">
                          {ev.duration_s}s
                        </span>
                      )}
                    </li>
                  ))}
                </ol>
              )}
            </section>

            {data.reflexion.length > 0 && (
              <section className="trace-section">
                <h3>Reflexion ({data.reflexion.length})</h3>
                <ol className="trace-reflexion">
                  {data.reflexion.map((r, i) => (
                    <li key={i}>
                      <div className="trace-refl-iter">v{r.iteration}</div>
                      <pre className="trace-refl-body">
                        {JSON.stringify(r, null, 2)}
                      </pre>
                    </li>
                  ))}
                </ol>
              </section>
            )}
          </>
        )}
      </aside>
    </div>
  );
}
