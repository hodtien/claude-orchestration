"use client";

import { useCallback, useEffect, useState } from "react";

type Stage =
  | "idea"
  | "expand"
  | "council"
  | "decompose"
  | "dispatch"
  | "review";
type StageStatus = "pending" | "running" | "done" | "failed";

const STAGES: Stage[] = [
  "idea",
  "expand",
  "council",
  "decompose",
  "dispatch",
  "review"
];

const STAGE_LABELS: Record<Stage, string> = {
  idea: "Idea",
  expand: "Expand",
  council: "Council",
  decompose: "Decompose",
  dispatch: "Dispatch",
  review: "Review"
};

interface StageRecord {
  status: StageStatus;
  startedAt?: number;
  endedAt?: number;
  output?: string;
  error?: string;
}

interface Pipeline {
  id: string;
  rawIdea: string;
  currentStage: Stage;
  stages: Record<Stage, StageRecord>;
  batchId?: string;
  dispatchPid?: number;
  createdAt: number;
  updatedAt: number;
}

interface PipelineTimelineProps {
  pipelineId: string;
  onUpdated: () => void;
}

function pillClass(status: StageStatus): string {
  if (status === "done") return "pill ok";
  if (status === "failed") return "pill err";
  if (status === "running") return "pill warn";
  return "pill dim";
}

function fmtDuration(start?: number, end?: number): string {
  if (!start) return "—";
  const e = end ?? Date.now();
  const ms = e - start;
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

export default function PipelineTimeline({
  pipelineId,
  onUpdated
}: PipelineTimelineProps) {
  const [pipeline, setPipeline] = useState<Pipeline | null>(null);
  const [streamErr, setStreamErr] = useState<string | null>(null);
  const [actionErr, setActionErr] = useState<string | null>(null);
  const [running, setRunning] = useState<Stage | null>(null);
  const [expanded, setExpanded] = useState<Set<Stage>>(new Set());

  useEffect(() => {
    setPipeline(null);
    setStreamErr(null);
    const es = new EventSource(`/api/pipelines/${pipelineId}/stream`);
    es.onmessage = (evt) => {
      try {
        const data = JSON.parse(evt.data);
        if (data.error) {
          setStreamErr(String(data.error));
          return;
        }
        setPipeline(data as Pipeline);
        setStreamErr(null);
      } catch (e: unknown) {
        setStreamErr(e instanceof Error ? e.message : String(e));
      }
    };
    es.onerror = () => {
      // EventSource auto-reconnects on transient errors
    };
    return () => {
      es.close();
    };
  }, [pipelineId]);

  const runStage = useCallback(
    async (stage: Stage) => {
      if (running) return;
      setRunning(stage);
      setActionErr(null);
      try {
        const res = await fetch(`/api/pipelines/${pipelineId}/${stage}`, {
          method: "POST"
        });
        const body = await res.json();
        if (!res.ok || !body.success) {
          throw new Error(body.error || `HTTP ${res.status}`);
        }
        onUpdated();
      } catch (e: unknown) {
        setActionErr(e instanceof Error ? e.message : String(e));
      } finally {
        setRunning(null);
      }
    },
    [pipelineId, running, onUpdated]
  );

  const toggleExpand = useCallback((stage: Stage) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(stage)) next.delete(stage);
      else next.add(stage);
      return next;
    });
  }, []);

  if (streamErr && !pipeline) {
    return <div className="empty">Stream error: {streamErr}</div>;
  }
  if (!pipeline) {
    return <div className="empty">Loading pipeline…</div>;
  }

  return (
    <div className="pipeline-timeline">
      <div className="pipeline-header">
        <div className="pipeline-id-line">
          <code>{pipeline.id}</code>
          {pipeline.batchId && (
            <span className="batch-badge">batch: {pipeline.batchId}</span>
          )}
        </div>
        <div className="pipeline-raw">{pipeline.rawIdea}</div>
        {actionErr && <div className="composer-error">{actionErr}</div>}
      </div>

      <ol className="stage-list">
        {STAGES.map((stage, idx) => {
          const rec = pipeline.stages[stage];
          const isOpen = expanded.has(stage);
          const isCurrent = pipeline.currentStage === stage;
          const isStageRunning = running === stage || rec.status === "running";
          const canRun =
            stage !== "idea" &&
            !running &&
            rec.status !== "running" &&
            (rec.status === "failed" ||
              pipeline.stages[STAGES[idx - 1]]?.status === "done");

          return (
            <li
              key={stage}
              className={
                "stage-card" +
                (isCurrent ? " current" : "") +
                (rec.status === "failed" ? " failed" : "") +
                (rec.status === "done" ? " done" : "")
              }
            >
              <div className="stage-head">
                <div className="stage-title">
                  <span className="stage-num">{idx + 1}</span>
                  <span className="stage-label">{STAGE_LABELS[stage]}</span>
                  <span className={pillClass(rec.status)}>{rec.status}</span>
                </div>
                <div className="stage-actions">
                  <span className="dim">
                    {fmtDuration(rec.startedAt, rec.endedAt)}
                  </span>
                  {canRun && (
                    <button
                      type="button"
                      className="btn-primary btn-sm"
                      onClick={() => runStage(stage)}
                      disabled={isStageRunning}
                    >
                      {rec.status === "failed" ? "Retry" : "Run"}
                    </button>
                  )}
                  {(rec.output || rec.error) && (
                    <button
                      type="button"
                      className="btn-ghost btn-sm"
                      onClick={() => toggleExpand(stage)}
                    >
                      {isOpen ? "Hide" : "Show"}
                    </button>
                  )}
                </div>
              </div>
              {isOpen && (
                <div className="stage-body">
                  {rec.error && <pre className="stage-error">{rec.error}</pre>}
                  {rec.output && (
                    <pre className="stage-output">{rec.output}</pre>
                  )}
                </div>
              )}
            </li>
          );
        })}
      </ol>
    </div>
  );
}
