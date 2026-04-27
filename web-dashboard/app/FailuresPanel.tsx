"use client";

import { useEffect, useRef, useState } from "react";
import type { FailureRow, SloSummary } from "@/lib/failures";

type FailuresPayload = {
  generated_at: string;
  filter: { limit: number; since: string | null };
  scanned: number;
  failures: FailureRow[];
  limit_clamped: boolean;
  slo: SloSummary;
};

type Props = {
  onSelectTask: (taskId: string) => void;
};

function fmtTs(ts?: string | null): string {
  if (!ts) return "—";
  return ts.replace("T", " ").replace("Z", "");
}

function fmtPct(n: number): string {
  return (n * 100).toFixed(1) + "%";
}

const POLL_OK_MS = 5000;
const POLL_BACKOFF_MAX_MS = 60000;
const SINCE_OPTIONS = [
  { label: "24h", value: "24h" },
  { label: "7d", value: "7d" },
  { label: "30d", value: "30d" },
];

export default function FailuresPanel({ onSelectTask }: Props) {
  const [data, setData] = useState<FailuresPayload | null>(null);
  const [since, setSince] = useState("24h");
  const [err, setErr] = useState<string | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const failuresRef = useRef(0);

  useEffect(() => {
    let cancelled = false;

    const schedule = (ms: number) => {
      if (cancelled) return;
      timerRef.current = setTimeout(tick, ms);
    };

    const tick = async () => {
      try {
        const res = await fetch(
          `/api/failures?limit=50&since=${since}`,
          { cache: "no-store" }
        );
        if (!res.ok) throw new Error(`/api/failures ${res.status}`);
        const payload = (await res.json()) as FailuresPayload;
        if (cancelled) return;
        setData(payload);
        setErr(null);
        failuresRef.current = 0;
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

    tick();
    return () => {
      cancelled = true;
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, [since]);

  const slo = data?.slo;
  const failures = data?.failures ?? [];

  return (
    <section className="panel">
      <div className="failures-header">
        <h2>Failures &amp; SLO</h2>
        <div className="since-strip">
          {SINCE_OPTIONS.map((opt) => (
            <button
              key={opt.value}
              type="button"
              className={`since-btn${since === opt.value ? " active" : ""}`}
              onClick={() => setSince(opt.value)}
            >
              {opt.label}
            </button>
          ))}
        </div>
      </div>

      {slo && (
        <div className="slo-cards">
          <div className="slo-card">
            <span className="slo-label">Completed (24h)</span>
            <span className="slo-value">{slo.total_completed_24h}</span>
          </div>
          <div className="slo-card">
            <span className="slo-label">Failed (24h)</span>
            <span className="slo-value slo-err">{slo.total_failed_24h}</span>
          </div>
          <div className="slo-card">
            <span className="slo-label">Failure rate</span>
            <span
              className={`slo-value${slo.failure_rate_24h > 0.2 ? " slo-err" : ""}`}
            >
              {fmtPct(slo.failure_rate_24h)}
            </span>
          </div>
        </div>
      )}

      {err && <div className="trace-err">{err}</div>}

      {failures.length === 0 ? (
        <div className="empty">No failures in this window.</div>
      ) : (
        <table>
          <thead>
            <tr>
              <th>completed</th>
              <th>task_id</th>
              <th>type</th>
              <th>state</th>
              <th>batch</th>
              <th className="num">dur (s)</th>
              <th className="num">reflexion</th>
              <th>error</th>
            </tr>
          </thead>
          <tbody>
            {failures.map((f, i) => (
              <tr key={`${f.task_id}-${i}`}>
                <td>{fmtTs(f.completed_at)}</td>
                <td>
                  <button
                    type="button"
                    className="task-link"
                    onClick={() => onSelectTask(f.task_id)}
                  >
                    {f.task_id}
                  </button>
                </td>
                <td>{f.task_type ?? "—"}</td>
                <td>
                  <span className="pill err">{f.final_state}</span>
                </td>
                <td style={{ fontFamily: "var(--mono)", fontSize: 11, color: "var(--text-dim)" }}>
                  {f.batch_id ?? "—"}
                </td>
                <td className="num">
                  {f.duration_sec !== null ? f.duration_sec : "—"}
                </td>
                <td className="num">{f.reflexion_iterations}</td>
                <td
                  style={{
                    fontFamily: "var(--mono)",
                    fontSize: 11,
                    color: "var(--text-dim)",
                    maxWidth: 200,
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap"
                  }}
                  title={f.error_summary ?? undefined}
                >
                  {f.error_summary ?? "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {data?.limit_clamped && (
        <div className="empty">Results capped at {data.filter.limit}.</div>
      )}
    </section>
  );
}
