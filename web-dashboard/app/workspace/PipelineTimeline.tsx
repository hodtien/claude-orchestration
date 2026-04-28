"use client";

import { useCallback, useEffect, useState } from "react";
import { useModelConfig } from "../../lib/use-model-config";
import BatchOverridePanel from "./BatchOverridePanel";

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

const FALLBACK_DEFAULT = "claude-sonnet-4-5";

const MODEL_STAGES: ReadonlySet<Stage> = new Set(["idea", "expand", "council"]);

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
  userNote?: string;
  model?: string;
}

const NOTE_STAGES: ReadonlySet<Stage> = new Set(["idea", "expand", "council"]);

const NOTE_PLACEHOLDERS: Partial<Record<Stage, string>> = {
  idea: "Add clarifications or constraints (passed to Expand)…",
  expand: "Refine spec before council debates it (passed to Skeptic/Pragmatist/Critic)…",
  council: "Steer the architect synthesis (passed to the Architect voice)…"
};

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
  const [noteDraft, setNoteDraft] = useState<Partial<Record<Stage, string>>>({});
  const [savingNote, setSavingNote] = useState<Stage | null>(null);
  const [noteMsg, setNoteMsg] = useState<Partial<Record<Stage, string>>>({});
  const [streamText, setStreamText] = useState<Partial<Record<Stage, string>>>(
    {}
  );
  const [streamPhase, setStreamPhase] = useState<Partial<Record<Stage, string>>>(
    {}
  );
  type VoiceName = "skeptic" | "pragmatist" | "critic";
  type VoiceStatus = "pending" | "running" | "done";
  const [voiceStatus, setVoiceStatus] = useState<
    Record<VoiceName, VoiceStatus>
  >({ skeptic: "pending", pragmatist: "pending", critic: "pending" });
  type UnitState = "pending" | "running" | "done" | "failed";
  interface UnitStatus {
    id: string;
    state: UnitState;
    duration_sec?: number;
    winner_agent?: string;
    error?: string;
  }
  interface DispatchCounts {
    pending: number;
    running: number;
    done: number;
    failed: number;
  }
  const [dispatchStatuses, setDispatchStatuses] = useState<UnitStatus[]>([]);
  const [dispatchCounts, setDispatchCounts] = useState<DispatchCounts | null>(
    null
  );
  const { config: modelConfig } = useModelConfig();
  const [selectedModel, setSelectedModel] = useState<Partial<Record<Stage, string>>>(
    {}
  );
  const [rerunPrompt, setRerunPrompt] = useState<Partial<Record<Stage, boolean>>>({});

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

  const runStreamingStage = useCallback(
    (stage: Stage, model?: string): Promise<void> => {
      return new Promise((resolve) => {
        setStreamText((prev) => ({ ...prev, [stage]: "" }));
        setStreamPhase((prev) => ({ ...prev, [stage]: "" }));
        if (stage === "council") {
          setVoiceStatus({
            skeptic: "pending",
            pragmatist: "pending",
            critic: "pending"
          });
        }
        setExpanded((prev) => {
          const next = new Set(prev);
          next.add(stage);
          return next;
        });
        const qs = model ? `?model=${encodeURIComponent(model)}` : "";
        const es = new EventSource(
          `/api/pipelines/${pipelineId}/${stage}/stream${qs}`
        );
        const finish = () => {
          es.close();
          setStreamText((prev) => {
            const next = { ...prev };
            delete next[stage];
            return next;
          });
          setStreamPhase((prev) => {
            const next = { ...prev };
            delete next[stage];
            return next;
          });
          onUpdated();
          resolve();
        };
        es.onmessage = (evt) => {
          try {
            const data = JSON.parse(evt.data);
            if (data.type === "delta") {
              setStreamText((prev) => ({
                ...prev,
                [stage]: (prev[stage] ?? "") + (data.text ?? "")
              }));
            } else if (data.type === "phase") {
              setStreamPhase((prev) => ({
                ...prev,
                [stage]: String(data.phase ?? "")
              }));
            } else if (data.type === "voice_start") {
              setVoiceStatus((prev) => ({
                ...prev,
                [data.voice as VoiceName]: "running"
              }));
            } else if (data.type === "voice_done") {
              setVoiceStatus((prev) => ({
                ...prev,
                [data.voice as VoiceName]: "done"
              }));
            } else if (data.type === "voices_done") {
              setStreamPhase((prev) => ({ ...prev, [stage]: "voices_done" }));
            } else if (data.type === "done") {
              finish();
            } else if (data.type === "error") {
              setActionErr(String(data.error ?? "stream error"));
              finish();
            }
          } catch (e: unknown) {
            setActionErr(e instanceof Error ? e.message : String(e));
            finish();
          }
        };
        es.onerror = () => {
          // EventSource auto-reconnects; if the server closed cleanly we already finished.
          // If it errored before any message, surface a generic notice.
        };
      });
    },
    [pipelineId, onUpdated]
  );

  const runDispatchStream = useCallback((): Promise<void> => {
    return new Promise((resolve) => {
      setDispatchStatuses([]);
      setDispatchCounts(null);
      setExpanded((prev) => {
        const next = new Set(prev);
        next.add("dispatch");
        return next;
      });
      const es = new EventSource(
        `/api/pipelines/${pipelineId}/dispatch/stream`
      );
      const finish = () => {
        es.close();
        onUpdated();
        resolve();
      };
      es.onmessage = (evt) => {
        try {
          const data = JSON.parse(evt.data);
          if (data.type === "start") {
            const ids = Array.isArray(data.taskIds)
              ? (data.taskIds as string[])
              : [];
            setDispatchStatuses(
              ids.map((id) => ({ id, state: "pending" as UnitState }))
            );
            setDispatchCounts({
              pending: ids.length,
              running: 0,
              done: 0,
              failed: 0
            });
          } else if (data.type === "progress") {
            if (Array.isArray(data.statuses)) {
              setDispatchStatuses(data.statuses as UnitStatus[]);
            }
            if (data.counts) {
              setDispatchCounts(data.counts as DispatchCounts);
            }
          } else if (data.type === "done") {
            if (Array.isArray(data.statuses)) {
              setDispatchStatuses(data.statuses as UnitStatus[]);
            }
            finish();
          } else if (data.type === "error") {
            setActionErr(String(data.error ?? "dispatch stream error"));
            finish();
          }
        } catch (e: unknown) {
          setActionErr(e instanceof Error ? e.message : String(e));
          finish();
        }
      };
      es.onerror = () => {
        // EventSource auto-reconnects; if the server closed cleanly we already finished.
      };
    });
  }, [pipelineId, onUpdated]);

  const runStage = useCallback(
    async (stage: Stage) => {
      if (running) return;
      setRunning(stage);
      setActionErr(null);
      try {
        if (stage === "expand" || stage === "council") {
          const model =
            selectedModel[stage] ??
            pipeline?.stages[stage].model ??
            modelConfig?.defaultModel ??
            FALLBACK_DEFAULT;
          await runStreamingStage(stage, model);
        } else if (stage === "dispatch") {
          await runDispatchStream();
        } else {
          const res = await fetch(`/api/pipelines/${pipelineId}/${stage}`, {
            method: "POST"
          });
          const body = await res.json();
          if (!res.ok || !body.success) {
            throw new Error(body.error || `HTTP ${res.status}`);
          }
          onUpdated();
        }
      } catch (e: unknown) {
        setActionErr(e instanceof Error ? e.message : String(e));
      } finally {
        setRunning(null);
      }
    },
    [
      pipelineId,
      running,
      onUpdated,
      runStreamingStage,
      runDispatchStream,
      selectedModel,
      pipeline,
      modelConfig
    ]
  );

  const saveNote = useCallback(
    async (stage: Stage) => {
      if (savingNote) return;
      const note = noteDraft[stage] ?? "";
      setSavingNote(stage);
      setNoteMsg((prev) => ({ ...prev, [stage]: "" }));
      try {
        const res = await fetch(`/api/pipelines/${pipelineId}/note`, {
          method: "PATCH",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ stage, note })
        });
        const body = await res.json();
        if (!res.ok || !body.success) {
          throw new Error(body.error || `HTTP ${res.status}`);
        }
        setNoteMsg((prev) => ({ ...prev, [stage]: "Saved" }));
        const targetStage: Stage = stage === "idea" ? "expand" : stage;
        const targetRec = pipeline?.stages[targetStage];
        if (targetRec && targetRec.status === "done") {
          setRerunPrompt((prev) => ({ ...prev, [stage]: true }));
        }
        onUpdated();
      } catch (e: unknown) {
        setNoteMsg((prev) => ({
          ...prev,
          [stage]: e instanceof Error ? e.message : String(e)
        }));
      } finally {
        setSavingNote(null);
      }
    },
    [pipelineId, savingNote, noteDraft, onUpdated]
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
          const canRerun =
            MODEL_STAGES.has(stage) &&
            stage !== "idea" &&
            rec.status === "done" &&
            !running;
          const canRun =
            stage !== "idea" &&
            !running &&
            rec.status !== "running" &&
            (rec.status === "failed" ||
              canRerun ||
              pipeline.stages[STAGES[idx - 1]]?.status === "done");
          const showModelPicker =
            stage === "idea"
              ? rec.status === "done"
              : MODEL_STAGES.has(stage) && canRun;
          const modelTarget: Stage = stage === "idea" ? "expand" : stage;
          const currentModel: string =
            selectedModel[modelTarget] ??
            pipeline.stages[modelTarget].model ??
            modelConfig?.defaultModel ??
            FALLBACK_DEFAULT;

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
                  {rec.model && (
                    <span className="model-badge" title="Model used for this stage">
                      {rec.model}
                    </span>
                  )}
                  {streamPhase[stage] && stage === "council" &&
                    (streamPhase[stage] === "voices" ||
                      streamPhase[stage] === "voices_done") && (
                      <span className="voice-badges">
                        {(["skeptic", "pragmatist", "critic"] as VoiceName[]).map(
                          (v) => (
                            <span
                              key={v}
                              className={`voice-badge voice-${voiceStatus[v]}`}
                              title={`${v}: ${voiceStatus[v]}`}
                            >
                              {v.charAt(0).toUpperCase() + v.slice(1)}
                              {voiceStatus[v] === "done"
                                ? " \u2713"
                                : voiceStatus[v] === "running"
                                ? " \u2026"
                                : ""}
                            </span>
                          )
                        )}
                      </span>
                    )}
                  {streamPhase[stage] && stage === "council" &&
                    streamPhase[stage] === "architect" && (
                      <span className="phase-badge">architect · streaming</span>
                    )}
                  {streamPhase[stage] && stage !== "council" && (
                    <span className="phase-badge">{streamPhase[stage]}</span>
                  )}
                </div>
                <div className="stage-actions">
                  <span className="dim">
                    {fmtDuration(rec.startedAt, rec.endedAt)}
                  </span>
                  {showModelPicker && (
                    <select
                      className="model-select"
                      value={currentModel}
                      onChange={(e) =>
                        setSelectedModel((prev) => ({
                          ...prev,
                          [modelTarget]: e.target.value
                        }))
                      }
                      disabled={
                        isStageRunning ||
                        (stage === "idea" &&
                          pipeline.stages.expand.status === "running")
                      }
                      title={
                        stage === "idea"
                          ? "Model for the upcoming Expand stage"
                          : "Model for this stage"
                      }
                    >
                      {(modelConfig?.models ?? []).length === 0 ? (
                        <option value={currentModel}>{currentModel}</option>
                      ) : (
                        Object.entries(
                          (modelConfig?.models ?? []).reduce<
                            Record<string, string[]>
                          >((acc, m) => {
                            const key = m.channel || "other";
                            (acc[key] ??= []).push(m.id);
                            return acc;
                          }, {})
                        ).map(([channel, ids]) => (
                          <optgroup key={channel} label={channel}>
                            {ids.map((m) => (
                              <option key={m} value={m}>
                                {m}
                              </option>
                            ))}
                          </optgroup>
                        ))
                      )}
                    </select>
                  )}
                  {canRun && (
                    <button
                      type="button"
                      className="btn-primary btn-sm"
                      onClick={() => runStage(stage)}
                      disabled={isStageRunning}
                    >
                      {rec.status === "failed"
                        ? "Retry"
                        : rec.status === "done"
                        ? "Re-run"
                        : "Run"}
                    </button>
                  )}
                  {(rec.output ||
                    rec.error ||
                    streamText[stage] ||
                    (stage === "dispatch" && dispatchStatuses.length > 0)) && (
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
                  {stage === "dispatch" && dispatchStatuses.length > 0 ? (
                    <div className="dispatch-progress">
                      {dispatchCounts && (
                        <div className="dispatch-counts">
                          <span className="dim">pending</span>{" "}
                          <strong>{dispatchCounts.pending}</strong>
                          <span className="dim"> · running</span>{" "}
                          <strong>{dispatchCounts.running}</strong>
                          <span className="dim"> · done</span>{" "}
                          <strong>{dispatchCounts.done}</strong>
                          <span className="dim"> · failed</span>{" "}
                          <strong>{dispatchCounts.failed}</strong>
                        </div>
                      )}
                      <ul className="dispatch-list">
                        {dispatchStatuses.map((u) => (
                          <li
                            key={u.id}
                            className={`dispatch-item dispatch-${u.state}`}
                            title={u.error ?? u.winner_agent ?? u.state}
                          >
                            <span className="dispatch-icon">
                              {u.state === "done"
                                ? "\u2713"
                                : u.state === "failed"
                                ? "\u2717"
                                : u.state === "running"
                                ? "\u2026"
                                : "\u00b7"}
                            </span>
                            <code className="dispatch-id">{u.id}</code>
                            {u.winner_agent && (
                              <span className="dim">{u.winner_agent}</span>
                            )}
                            {typeof u.duration_sec === "number" && (
                              <span className="dim">
                                {u.duration_sec.toFixed(1)}s
                              </span>
                            )}
                          </li>
                        ))}
                      </ul>
                      {rec.output && (
                        <pre className="stage-output">{rec.output}</pre>
                      )}
                    </div>
                  ) : streamText[stage] !== undefined ? (
                    <pre className="stage-output stage-streaming">
                      {streamText[stage] || "…"}
                      <span className="stream-caret">▍</span>
                    </pre>
                  ) : (
                    rec.output && (
                      <pre className="stage-output">{rec.output}</pre>
                    )
                  )}
                </div>
              )}
              {NOTE_STAGES.has(stage) && (
                <div className="stage-note">
                  <textarea
                    className="stage-note-input"
                    placeholder={NOTE_PLACEHOLDERS[stage]}
                    value={noteDraft[stage] ?? rec.userNote ?? ""}
                    onChange={(e) =>
                      setNoteDraft((prev) => ({
                        ...prev,
                        [stage]: e.target.value
                      }))
                    }
                    rows={2}
                    maxLength={4000}
                  />
                  <div className="stage-note-actions">
                    {noteMsg[stage] && (
                      <span className="dim stage-note-msg">
                        {noteMsg[stage]}
                      </span>
                    )}
                    <button
                      type="button"
                      className="btn-ghost btn-sm"
                      onClick={() => saveNote(stage)}
                      disabled={savingNote === stage}
                    >
                      {savingNote === stage ? "Saving…" : "Save note"}
                    </button>
                  </div>
                  {rerunPrompt[stage] && (
                    <div className="stage-rerun-prompt">
                      <span>
                        Note saved. Re-run{" "}
                        <strong>
                          {STAGE_LABELS[stage === "idea" ? "expand" : stage]}
                        </strong>{" "}
                        with the new note?
                      </span>
                      <div className="stage-rerun-actions">
                        <button
                          type="button"
                          className="btn-primary btn-sm"
                          onClick={() => {
                            const target: Stage =
                              stage === "idea" ? "expand" : stage;
                            setRerunPrompt((prev) => ({
                              ...prev,
                              [stage]: false
                            }));
                            runStage(target);
                          }}
                          disabled={running !== null}
                        >
                          Re-run
                        </button>
                        <button
                          type="button"
                          className="btn-ghost btn-sm"
                          onClick={() =>
                            setRerunPrompt((prev) => ({
                              ...prev,
                              [stage]: false
                            }))
                          }
                        >
                          Dismiss
                        </button>
                      </div>
                    </div>
                  )}
                </div>
              )}
            </li>
          );
        })}
      </ol>

      <BatchOverridePanel
        pipelineId={pipelineId}
        decomposeStatus={pipeline.stages.decompose.status}
        dispatchStatus={pipeline.stages.dispatch.status}
      />
    </div>
  );
}
