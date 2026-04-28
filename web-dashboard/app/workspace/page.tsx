"use client";

import { useCallback, useEffect, useState } from "react";
import IdeaComposer from "./IdeaComposer";
import PipelineTimeline from "./PipelineTimeline";
import "./workspace.css";

interface PipelineSummary {
  id: string;
  rawIdea: string;
  currentStage: string;
  createdAt: number;
  updatedAt: number;
}

interface ListResponse {
  success: boolean;
  data?: PipelineSummary[];
  error?: string;
}

export default function WorkspacePage() {
  const [pipelines, setPipelines] = useState<PipelineSummary[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const res = await fetch("/api/pipelines", { cache: "no-store" });
      if (!res.ok) throw new Error(`/api/pipelines ${res.status}`);
      const body = (await res.json()) as ListResponse;
      if (body.success && body.data) {
        setPipelines(body.data);
        setErr(null);
        if (!activeId && body.data.length > 0) {
          setActiveId(body.data[0].id);
        }
      } else if (body.error) {
        setErr(body.error);
      }
    } catch (e: unknown) {
      setErr(e instanceof Error ? e.message : String(e));
    }
  }, [activeId]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const handleCreated = useCallback(
    (id: string) => {
      setActiveId(id);
      void refresh();
    },
    [refresh]
  );

  return (
    <main className="workspace">
      <header className="page">
        <h1>Idea Workspace</h1>
        <div className="meta">
          {err ? `error: ${err}` : `${pipelines.length} pipelines`}
        </div>
      </header>

      <IdeaComposer onCreated={handleCreated} />

      <section className="ws-layout">
        <aside className="ws-sidebar">
          <h2>Pipelines</h2>
          {pipelines.length === 0 ? (
            <div className="empty">No pipelines yet. Submit an idea above.</div>
          ) : (
            <ul className="pipeline-list">
              {pipelines.map((p) => (
                <li key={p.id}>
                  <button
                    type="button"
                    className={
                      "pipeline-item" + (p.id === activeId ? " active" : "")
                    }
                    onClick={() => setActiveId(p.id)}
                  >
                    <div className="pipeline-idea">
                      {p.rawIdea.slice(0, 80)}
                      {p.rawIdea.length > 80 ? "…" : ""}
                    </div>
                    <div className="pipeline-meta">
                      <span className="stage-badge">{p.currentStage}</span>
                      <span className="dim">
                        {new Date(p.updatedAt).toLocaleTimeString()}
                      </span>
                    </div>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </aside>

        <section className="ws-main">
          {activeId ? (
            <PipelineTimeline pipelineId={activeId} onUpdated={refresh} />
          ) : (
            <div className="empty">
              Select or create a pipeline to view its stages.
            </div>
          )}
        </section>
      </section>
    </main>
  );
}
