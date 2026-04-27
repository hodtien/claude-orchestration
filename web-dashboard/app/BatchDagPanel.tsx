"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { BatchDag, BatchSummary, BatchTaskNode } from "@/lib/batch";

interface Props {
  onSelectTask: (taskId: string) => void;
}

type Layer = BatchTaskNode[][];

function layerize(nodes: BatchTaskNode[]): Layer {
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const depth = new Map<string, number>();
  const visiting = new Set<string>();

  function getDepth(id: string): number {
    if (depth.has(id)) return depth.get(id)!;
    if (visiting.has(id)) return 0;
    visiting.add(id);
    const node = byId.get(id);
    if (!node || node.depends_on.length === 0) {
      depth.set(id, 0);
      return 0;
    }
    let max = 0;
    for (const d of node.depends_on) {
      if (byId.has(d)) max = Math.max(max, getDepth(d) + 1);
    }
    depth.set(id, max);
    return max;
  }

  for (const n of nodes) getDepth(n.id);

  const maxD = Math.max(0, ...Array.from(depth.values()));
  const layers: Layer = [];
  for (let i = 0; i <= maxD; i++) layers.push([]);
  for (const n of nodes) {
    layers[depth.get(n.id) ?? 0].push(n);
  }

  return layers;
}

const NODE_W = 140;
const NODE_H = 34;
const PAD_X = 60;
const PAD_Y = 50;
const MARGIN = 20;

function stateColor(state: string): string {
  switch (state) {
    case "succeeded":
      return "var(--ok)";
    case "failed":
      return "var(--err)";
    case "running":
      return "var(--warn)";
    case "blocked":
      return "var(--text-dim)";
    default:
      return "var(--border)";
  }
}

export default function BatchDagPanel({ onSelectTask }: Props) {
  const [batches, setBatches] = useState<BatchSummary[]>([]);
  const [activeBatch, setActiveBatch] = useState<string | null>(null);
  const [dag, setDag] = useState<BatchDag | null>(null);
  const [loading, setLoading] = useState(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    let cancelled = false;
    const fetchBatches = async () => {
      try {
        const res = await fetch("/api/batches", { cache: "no-store" });
        if (!res.ok) return;
        const data = (await res.json()) as { batches: BatchSummary[] };
        if (cancelled) return;
        setBatches(data.batches);
      } catch {
        // silent
      }
      if (!cancelled) timerRef.current = setTimeout(fetchBatches, 5000);
    };
    fetchBatches();
    return () => {
      cancelled = true;
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, []);

  const selectBatch = useCallback(async (batchId: string) => {
    setActiveBatch(batchId);
    setLoading(true);
    try {
      const res = await fetch(`/api/batches/${encodeURIComponent(batchId)}`, {
        cache: "no-store"
      });
      if (!res.ok) {
        setDag(null);
        return;
      }
      const data = (await res.json()) as BatchDag;
      setDag(data);
    } catch {
      setDag(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!activeBatch) return;
    let cancelled = false;
    const id = setInterval(async () => {
      try {
        const res = await fetch(
          `/api/batches/${encodeURIComponent(activeBatch)}`,
          { cache: "no-store" }
        );
        if (cancelled) return;
        if (res.ok) {
          const data = (await res.json()) as BatchDag;
          if (!cancelled) setDag(data);
        }
      } catch {
        // silent
      }
    }, 5000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [activeBatch]);

  if (batches.length === 0) return null;

  const layers = dag ? layerize(dag.tasks) : [];
  const cols = layers.length;
  const maxRows = Math.max(1, ...layers.map((l) => l.length));
  const svgW = cols * (NODE_W + PAD_X) - PAD_X + MARGIN * 2;
  const svgH = maxRows * (NODE_H + PAD_Y) - PAD_Y + MARGIN * 2;

  const pos = new Map<string, { x: number; y: number }>();
  for (let col = 0; col < layers.length; col++) {
    const layer = layers[col];
    const totalH = layer.length * (NODE_H + PAD_Y) - PAD_Y;
    const startY = (svgH - totalH) / 2;
    for (let row = 0; row < layer.length; row++) {
      pos.set(layer[row].id, {
        x: MARGIN + col * (NODE_W + PAD_X),
        y: startY + row * (NODE_H + PAD_Y)
      });
    }
  }

  return (
    <section className="panel">
      <h2>Batch DAG</h2>

      <div className="batch-strip">
        {batches.map((b) => (
          <button
            key={b.batch_id}
            type="button"
            className={`batch-pill${activeBatch === b.batch_id ? " active" : ""}`}
            onClick={() => selectBatch(b.batch_id)}
          >
            {b.batch_id}
            <span className="batch-pill-count">{b.task_count}</span>
            {b.state_counts && (b.state_counts.failed > 0 || b.state_counts.running > 0 || b.state_counts.succeeded > 0) && (
              <span className="batch-pill-dots">
                {b.state_counts.failed > 0 && <span className="batch-pill-dot dot-err" />}
                {b.state_counts.running > 0 && <span className="batch-pill-dot dot-warn" />}
                {b.state_counts.succeeded > 0 && <span className="batch-pill-dot dot-ok" />}
              </span>
            )}
          </button>
        ))}
      </div>

      {loading && <div className="empty">Loading DAG…</div>}

      {dag && !loading && (
        <>
          {dag.cycle && (
            <div className="dag-cycle-banner">
              Cycle detected: {dag.cycle.join(" → ")} — graph hidden until resolved
            </div>
          )}
          {dag.truncated && (
            <div
              className="dag-cycle-banner"
              style={{ borderColor: "var(--warn)" }}
            >
              Showing first {dag.tasks.length} of {dag.total_task_count} nodes
            </div>
          )}
          {!dag.cycle && (
          <div className="dag-scroll">
            <svg
              className="dag-svg"
              width={svgW}
              height={svgH}
              viewBox={`0 0 ${svgW} ${svgH}`}
            >
              {dag.tasks.map((node) => {
                const to = pos.get(node.id);
                if (!to) return null;
                return node.depends_on.map((depId) => {
                  const from = pos.get(depId);
                  if (!from) return null;
                  const x1 = from.x + NODE_W;
                  const y1 = from.y + NODE_H / 2;
                  const x2 = to.x;
                  const y2 = to.y + NODE_H / 2;
                  const mx = (x1 + x2) / 2;
                  const depNode = dag.tasks.find((n) => n.id === depId);
                  const edgeFailed =
                    depNode?.state === "failed" ||
                    depNode?.state === "blocked";
                  return (
                    <path
                      key={`${depId}->${node.id}`}
                      className="dag-edge"
                      d={`M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`}
                      stroke={edgeFailed ? "var(--err)" : "var(--border)"}
                      strokeWidth={1.5}
                      fill="none"
                      opacity={0.7}
                    />
                  );
                });
              })}

              {dag.tasks.map((node) => {
                const p = pos.get(node.id);
                if (!p) return null;
                const color = stateColor(node.state);
                return (
                  <g
                    key={node.id}
                    className="dag-node"
                    onClick={() => onSelectTask(node.id)}
                    style={{ cursor: "pointer" }}
                  >
                    <rect
                      x={p.x}
                      y={p.y}
                      width={NODE_W}
                      height={NODE_H}
                      rx={6}
                      fill="var(--surface-2)"
                      stroke={color}
                      strokeWidth={1.5}
                    />
                    <text
                      x={p.x + NODE_W / 2}
                      y={p.y + NODE_H / 2 + 1}
                      textAnchor="middle"
                      dominantBaseline="middle"
                      fill="var(--text)"
                      fontSize={11}
                      fontFamily="var(--mono)"
                    >
                      {node.id.length > 18
                        ? node.id.slice(0, 16) + "…"
                        : node.id}
                    </text>
                  </g>
                );
              })}
            </svg>
          </div>
          )}
        </>
      )}
    </section>
  );
}
