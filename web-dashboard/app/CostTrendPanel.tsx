"use client";

import { useEffect, useRef, useState } from "react";
import type {
  TrendResult,
  BudgetState,
  TrendBucket,
  BudgetModelRow,
} from "@/lib/cost-trend";

type Props = Record<string, never>;

function fmtNum(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(1) + "k";
  return String(n);
}

function fmtPct(n: number): string {
  return n.toFixed(1) + "%";
}

const POLL_OK_MS = 5000;
const POLL_BACKOFF_MAX_MS = 60000;

const WINDOW_OPTIONS = [
  { label: "24h", window: "24h", bucket: "1h" as const },
  { label: "7d", window: "7d", bucket: "1d" as const },
];

const MODEL_COLORS = [
  "oklch(72% 0.16 250)",
  "oklch(74% 0.14 150)",
  "oklch(80% 0.15 75)",
  "oklch(68% 0.20 25)",
  "oklch(65% 0.18 310)",
  "oklch(78% 0.12 200)",
];

function colorFor(idx: number): string {
  return MODEL_COLORS[idx % MODEL_COLORS.length];
}

const W = 680;
const H = 180;
const PAD_L = 56;
const PAD_R = 12;
const PAD_T = 8;
const PAD_B = 24;
const CHART_W = W - PAD_L - PAD_R;
const CHART_H = H - PAD_T - PAD_B;

function buildAreaPaths(
  buckets: TrendBucket[],
  models: string[],
  field: "tokens_in" | "cost_usd"
): { paths: { model: string; d: string; color: string }[]; maxY: number } {
  if (buckets.length === 0) return { paths: [], maxY: 0 };

  const stacked: number[][] = buckets.map(() =>
    new Array(models.length).fill(0)
  );

  for (let bi = 0; bi < buckets.length; bi++) {
    let cumulative = 0;
    for (let mi = 0; mi < models.length; mi++) {
      const pm = buckets[bi].per_model[models[mi]];
      const val =
        field === "tokens_in"
          ? (pm?.tokens_in ?? 0) + (pm?.tokens_out ?? 0)
          : pm?.[field] ?? 0;
      cumulative += val;
      stacked[bi][mi] = cumulative;
    }
  }

  let maxY = 0;
  for (const row of stacked) {
    const top = row[row.length - 1] ?? 0;
    if (top > maxY) maxY = top;
  }
  if (maxY === 0) maxY = 1;

  const xStep = buckets.length > 1 ? CHART_W / (buckets.length - 1) : CHART_W;
  const scaleY = CHART_H / maxY;

  const paths: { model: string; d: string; color: string }[] = [];

  for (let mi = models.length - 1; mi >= 0; mi--) {
    const topPts: string[] = [];
    const botPts: string[] = [];

    for (let bi = 0; bi < buckets.length; bi++) {
      const x = PAD_L + bi * xStep;
      const yTop = PAD_T + CHART_H - stacked[bi][mi] * scaleY;
      const yBot =
        mi === 0
          ? PAD_T + CHART_H
          : PAD_T + CHART_H - stacked[bi][mi - 1] * scaleY;
      topPts.push(`${x.toFixed(1)},${yTop.toFixed(1)}`);
      botPts.unshift(`${x.toFixed(1)},${yBot.toFixed(1)}`);
    }

    const d = `M${topPts.join("L")}L${botPts.join("L")}Z`;
    paths.push({ model: models[mi], d, color: colorFor(mi) });
  }

  return { paths, maxY };
}

function XLabels({ buckets, bucket }: { buckets: TrendBucket[]; bucket: string }) {
  if (buckets.length === 0) return null;
  const step = Math.max(1, Math.floor(buckets.length / 6));
  const xStep =
    buckets.length > 1 ? CHART_W / (buckets.length - 1) : CHART_W;

  return (
    <>
      {buckets.map((b, i) => {
        if (i % step !== 0 && i !== buckets.length - 1) return null;
        const x = PAD_L + i * xStep;
        const label =
          bucket === "1d"
            ? b.ts.slice(5, 10)
            : b.ts.slice(11, 16);
        return (
          <text
            key={b.ts}
            x={x}
            y={H - 2}
            textAnchor="middle"
            fontSize={9}
            fill="var(--text-dim)"
            fontFamily="var(--mono)"
          >
            {label}
          </text>
        );
      })}
    </>
  );
}

function YLabels({ maxY }: { maxY: number }) {
  const ticks = [0, 0.25, 0.5, 0.75, 1];
  return (
    <>
      {ticks.map((t) => {
        const y = PAD_T + CHART_H - t * CHART_H;
        return (
          <g key={t}>
            <line
              x1={PAD_L}
              y1={y}
              x2={W - PAD_R}
              y2={y}
              stroke="var(--border)"
              strokeWidth={0.5}
            />
            <text
              x={PAD_L - 6}
              y={y + 3}
              textAnchor="end"
              fontSize={9}
              fill="var(--text-dim)"
              fontFamily="var(--mono)"
            >
              {fmtNum(maxY * t)}
            </text>
          </g>
        );
      })}
    </>
  );
}

function statusColor(status: string): string {
  if (status === "over") return "var(--err)";
  if (status === "warn") return "var(--warn)";
  return "var(--ok)";
}

export default function CostTrendPanel(_props: Props) {
  const [trend, setTrend] = useState<TrendResult | null>(null);
  const [budget, setBudget] = useState<BudgetState | null>(null);
  const [windowIdx, setWindowIdx] = useState(0);
  const [err, setErr] = useState<string | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const failuresRef = useRef(0);

  const opt = WINDOW_OPTIONS[windowIdx];

  useEffect(() => {
    let cancelled = false;

    const schedule = (ms: number) => {
      if (cancelled) return;
      timerRef.current = setTimeout(tick, ms);
    };

    const tick = async () => {
      try {
        const [tRes, bRes] = await Promise.all([
          fetch(
            `/api/cost-trend?window=${opt.window}&bucket=${opt.bucket}`,
            { cache: "no-store" }
          ),
          fetch("/api/budget", { cache: "no-store" }),
        ]);
        if (!tRes.ok) throw new Error(`/api/cost-trend ${tRes.status}`);
        if (!bRes.ok) throw new Error(`/api/budget ${bRes.status}`);
        const t = (await tRes.json()) as TrendResult;
        const b = (await bRes.json()) as BudgetState;
        if (cancelled) return;
        setTrend(t);
        setBudget(b);
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
  }, [opt.window, opt.bucket]);

  const buckets = trend?.buckets ?? [];
  const models = trend?.models ?? [];
  const { paths: tokenPaths, maxY: tokenMaxY } = buildAreaPaths(
    buckets,
    models,
    "tokens_in"
  );

  const budgetRows: BudgetModelRow[] = budget?.per_model ?? [];

  return (
    <section className="panel">
      <div className="failures-header">
        <h2>Cost &amp; Token Trend</h2>
        <div className="since-strip">
          {WINDOW_OPTIONS.map((o, i) => (
            <button
              key={o.label}
              type="button"
              className={`since-btn${windowIdx === i ? " active" : ""}`}
              onClick={() => setWindowIdx(i)}
            >
              {o.label}
            </button>
          ))}
        </div>
      </div>

      {err && <div className="trace-err">{err}</div>}

      {trend && (
        <div className="cost-totals-strip">
          <div className="slo-card">
            <span className="slo-label">Calls</span>
            <span className="slo-value">{fmtNum(trend.totals.calls)}</span>
          </div>
          <div className="slo-card">
            <span className="slo-label">Tokens</span>
            <span className="slo-value">
              {fmtNum(trend.totals.tokens_in + trend.totals.tokens_out)}
            </span>
          </div>
          <div className="slo-card">
            <span className="slo-label">Cost</span>
            <span className="slo-value">
              ${trend.totals.cost_usd.toFixed(4)}
            </span>
          </div>
        </div>
      )}

      {buckets.length > 0 && (
        <div className="chart-area">
          <div className="chart-label">Tokens by model</div>
          <div className="dag-scroll" style={{ maxHeight: H + 16 }}>
            <svg
              viewBox={`0 0 ${W} ${H}`}
              className="dag-svg"
              width={W}
              height={H}
            >
              <YLabels maxY={tokenMaxY} />
              {tokenPaths.map((p) => (
                <path
                  key={p.model}
                  d={p.d}
                  fill={p.color}
                  fillOpacity={0.55}
                  stroke={p.color}
                  strokeWidth={1}
                />
              ))}
              <XLabels buckets={buckets} bucket={opt.bucket} />
            </svg>
          </div>
          <div className="chart-legend">
            {models.map((m, i) => (
              <span key={m} className="legend-item">
                <span
                  className="legend-dot"
                  style={{ background: colorFor(i) }}
                />
                {m}
              </span>
            ))}
          </div>
        </div>
      )}

      {budget && (
        <div className="budget-section">
          <div className="chart-label">
            Budget burn-down (24h)
            {!budget.config_present && (
              <span className="trace-trunc"> (defaults — no budget.yaml)</span>
            )}
          </div>

          <div className="budget-global">
            <div className="budget-bar-wrap">
              <div className="budget-bar-label">
                <span>Global</span>
                <span>
                  {fmtNum(budget.global.used_24h)} / {fmtNum(budget.global.limit)}
                  {" "}({fmtPct(budget.global.pct)})
                </span>
              </div>
              <div className="budget-bar-track">
                <div
                  className="budget-bar-fill"
                  style={{
                    width: `${Math.min(budget.global.pct, 100)}%`,
                    background: statusColor(budget.global.status),
                  }}
                />
                <div
                  className="budget-bar-threshold"
                  style={{ left: `${budget.global.alert_threshold_pct}%` }}
                />
              </div>
            </div>
          </div>

          {budgetRows.length > 0 && (
            <div className="budget-models">
              {budgetRows.map((r) => (
                <div key={r.model} className="budget-bar-wrap">
                  <div className="budget-bar-label">
                    <span>
                      {r.model}
                      {r.is_global_pool && (
                        <span className="budget-pool-tag">pool</span>
                      )}
                    </span>
                    <span>
                      {fmtNum(r.used_24h)} / {fmtNum(r.limit)}
                      {" "}({fmtPct(r.pct)})
                    </span>
                  </div>
                  <div className="budget-bar-track">
                    <div
                      className="budget-bar-fill"
                      style={{
                        width: `${Math.min(r.pct, 100)}%`,
                        background: statusColor(r.status),
                      }}
                    />
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </section>
  );
}
