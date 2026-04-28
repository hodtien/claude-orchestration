"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import IdeaComposer from "./IdeaComposer";
import PipelineTimeline from "./PipelineTimeline";
import { ProjectManager } from "./ProjectManager";
import "./workspace.css";

interface PipelineSummary {
  id: string;
  rawIdea: string;
  project?: string;
  currentStage: string;
  createdAt: number;
  updatedAt: number;
}

interface ProjectOption {
  id: string;
  name: string;
  path: string;
  createdAt: number;
}

interface ListResponse {
  success: boolean;
  data?: PipelineSummary[];
  error?: string;
}

const UNASSIGNED_KEY = "__unassigned__";
const COLLAPSE_STORAGE_KEY = "workspace.collapsedProjects";

function groupByProject(pipelines: PipelineSummary[]): Array<[string, PipelineSummary[]]> {
  const groups = new Map<string, PipelineSummary[]>();
  for (const p of pipelines) {
    const key = p.project?.trim() || UNASSIGNED_KEY;
    const arr = groups.get(key) ?? [];
    arr.push(p);
    groups.set(key, arr);
  }
  return [...groups.entries()].sort(([a], [b]) => {
    if (a === UNASSIGNED_KEY) return 1;
    if (b === UNASSIGNED_KEY) return -1;
    return a.localeCompare(b);
  });
}

export default function WorkspacePage() {
  const [pipelines, setPipelines] = useState<PipelineSummary[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [editingProject, setEditingProject] = useState<string | null>(null);
  const [editValue, setEditValue] = useState("");
  const [registeredProjects, setRegisteredProjects] = useState<ProjectOption[]>([]);

  const loadProjects = useCallback(async () => {
    try {
      const res = await fetch("/api/config/projects", { cache: "no-store" });
      const json = await res.json();
      if (json.success && json.data) {
        setRegisteredProjects(
          (json.data as Array<{ id: string; name: string; path: string; createdAt: number }>).map((p) => ({
            id: p.id,
            name: p.name,
            path: p.path,
            createdAt: p.createdAt,
          }))
        );
      }
    } catch {
      // non-critical
    }
  }, []);

  useEffect(() => {
    void loadProjects();

    if (typeof BroadcastChannel === "undefined") return;
    const bc = new BroadcastChannel("config:projects");
    bc.onmessage = () => { void loadProjects(); };
    return () => bc.close();
  }, [loadProjects]);

  useEffect(() => {
    try {
      const raw = localStorage.getItem(COLLAPSE_STORAGE_KEY);
      if (raw) {
        const arr = JSON.parse(raw) as string[];
        if (Array.isArray(arr)) setCollapsed(new Set(arr));
      }
    } catch {
      // ignore malformed storage
    }
  }, []);

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

  const grouped = useMemo(() => groupByProject(pipelines), [pipelines]);

  const toggleGroup = useCallback((key: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      try {
        localStorage.setItem(COLLAPSE_STORAGE_KEY, JSON.stringify([...next]));
      } catch {
        // ignore quota errors
      }
      return next;
    });
  }, []);

  const startEditProject = useCallback((p: PipelineSummary, e: React.MouseEvent) => {
    e.stopPropagation();
    setEditingProject(p.id);
    setEditValue(p.project ?? "");
  }, []);

  const cancelEdit = useCallback(() => {
    setEditingProject(null);
    setEditValue("");
  }, []);

  const saveProject = useCallback(
    async (id: string) => {
      const trimmed = editValue.trim();
      try {
        const res = await fetch(`/api/pipelines/${encodeURIComponent(id)}`, {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ project: trimmed === "" ? null : trimmed })
        });
        if (!res.ok) {
          const body = await res.json().catch(() => ({}));
          throw new Error(body.error || `HTTP ${res.status}`);
        }
        setEditingProject(null);
        setEditValue("");
        void refresh();
      } catch (e: unknown) {
        setErr(e instanceof Error ? e.message : String(e));
      }
    },
    [editValue, refresh]
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
          <div className="ws-sidebar-head">
            <h2>Pipelines</h2>
            <div className="sidebar-project-actions">
              <ProjectManager projects={registeredProjects} onProjectsChanged={loadProjects} />
            </div>
          </div>
          {pipelines.length === 0 ? (
            <div className="empty">No pipelines yet. Submit an idea above.</div>
          ) : (
            <div className="project-groups">
              {grouped.map(([key, items]) => {
                const isCollapsed = collapsed.has(key);
                const label = key === UNASSIGNED_KEY ? "Unassigned" : key;
                return (
                  <div key={key} className="project-group">
                    <button
                      type="button"
                      className="project-group-header"
                      onClick={() => toggleGroup(key)}
                      aria-expanded={!isCollapsed}
                    >
                      <span className="chevron" aria-hidden>
                        {isCollapsed ? "▸" : "▾"}
                      </span>
                      <span className="project-group-name">{label}</span>
                      <span className="project-group-count">{items.length}</span>
                    </button>
                    {!isCollapsed && (
                      <ul className="pipeline-list">
                        {items.map((p) => (
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
                              {editingProject === p.id ? (
                                <div
                                  className="pipeline-edit-project"
                                  onClick={(e) => e.stopPropagation()}
                                >
                                  <select
                                    className="project-input"
                                    value={editValue}
                                    onChange={(e) => setEditValue(e.target.value)}
                                    onKeyDown={(e) => {
                                      if (e.key === "Escape") {
                                        cancelEdit();
                                      }
                                    }}
                                    autoFocus
                                  >
                                    <option value="">Unassigned</option>
                                    {registeredProjects.map((rp) => (
                                      <option key={rp.id} value={rp.name}>
                                        {rp.name}
                                      </option>
                                    ))}
                                  </select>
                                  <button
                                    type="button"
                                    className="btn-mini"
                                    onClick={() => saveProject(p.id)}
                                  >
                                    Save
                                  </button>
                                  <button
                                    type="button"
                                    className="btn-mini btn-ghost"
                                    onClick={cancelEdit}
                                  >
                                    Cancel
                                  </button>
                                </div>
                              ) : (
                                <span
                                  className="pipeline-edit-link"
                                  role="button"
                                  tabIndex={0}
                                  onClick={(e) => startEditProject(p, e)}
                                  onKeyDown={(e) => {
                                    if (e.key === "Enter" || e.key === " ") {
                                      e.preventDefault();
                                      e.stopPropagation();
                                      setEditingProject(p.id);
                                      setEditValue(p.project ?? "");
                                    }
                                  }}
                                >
                                  Edit project
                                </span>
                              )}
                            </button>
                          </li>
                        ))}
                      </ul>
                    )}
                  </div>
                );
              })}
            </div>
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
