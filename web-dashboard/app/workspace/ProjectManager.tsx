"use client";

import { useCallback, useEffect, useState } from "react";

interface ProjectEntry {
  id: string;
  name: string;
  path: string;
  createdAt: number;
}

interface DirEntry {
  name: string;
  isDir: boolean;
}

interface DirResponse {
  success: boolean;
  data?: { path: string; parent: string | null; home: string; entries: DirEntry[] };
  error?: string;
}

type Dialog = "manage" | "form" | "browse" | null;
type FormMode = "add" | "edit";

interface ProjectManagerProps {
  projects: ProjectEntry[];
  onProjectsChanged: () => void;
}

function broadcastProjects() {
  if (typeof BroadcastChannel === "undefined") return;
  const bc = new BroadcastChannel("config:projects");
  bc.postMessage({ type: "changed", at: Date.now() });
  bc.close();
}

export function ProjectManager({ projects, onProjectsChanged }: ProjectManagerProps) {
  const [dialog, setDialog] = useState<Dialog>(null);
  const [formMode, setFormMode] = useState<FormMode>("add");
  const [editId, setEditId] = useState<string | null>(null);
  const [formName, setFormName] = useState("");
  const [formPath, setFormPath] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [browsePath, setBrowsePath] = useState("");
  const [browseEntries, setBrowseEntries] = useState<DirEntry[]>([]);
  const [browseParent, setBrowseParent] = useState<string | null>(null);
  const [browseHome, setBrowseHome] = useState("");
  const [browseLoading, setBrowseLoading] = useState(false);
  const [browseError, setBrowseError] = useState<string | null>(null);

  const closeAll = useCallback(() => {
    setDialog(null);
    setError(null);
    setBrowseError(null);
  }, []);

  useEffect(() => {
    if (dialog === null) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") closeAll();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [dialog, closeAll]);

  const openAdd = () => {
    setFormMode("add");
    setEditId(null);
    setFormName("");
    setFormPath("");
    setError(null);
    setDialog("form");
  };

  const openEdit = (p: ProjectEntry) => {
    setFormMode("edit");
    setEditId(p.id);
    setFormName(p.name);
    setFormPath(p.path);
    setError(null);
    setDialog("form");
  };

  const fetchDir = useCallback(async (dirPath: string) => {
    setBrowseLoading(true);
    setBrowseError(null);
    try {
      const res = await fetch(`/api/fs/directories?path=${encodeURIComponent(dirPath)}`, { cache: "no-store" });
      const json = (await res.json()) as DirResponse;
      if (!json.success || !json.data) throw new Error(json.error ?? "Failed to list directory");
      setBrowsePath(json.data.path);
      setBrowseEntries(json.data.entries);
      setBrowseParent(json.data.parent);
      setBrowseHome(json.data.home);
    } catch (e: unknown) {
      setBrowseError(e instanceof Error ? e.message : "Browse failed");
    } finally {
      setBrowseLoading(false);
    }
  }, []);

  const openBrowse = useCallback(() => {
    setDialog("browse");
    void fetchDir(formPath || "~");
  }, [formPath, fetchDir]);

  const selectDir = useCallback(() => {
    setFormPath(browsePath);
    setDialog("form");
  }, [browsePath]);

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      const isEdit = formMode === "edit" && editId;
      const url = isEdit
        ? `/api/config/projects/${encodeURIComponent(editId)}`
        : "/api/config/projects";
      const method = isEdit ? "PATCH" : "POST";
      const body = { name: formName.trim(), path: formPath.trim() };
      const res = await fetch(url, {
        method,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const json = await res.json();
      if (!json.success) throw new Error(json.error || "Save failed");
      broadcastProjects();
      onProjectsChanged();
      setDialog("manage");
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Save failed");
    } finally {
      setSaving(false);
    }
  };

  const remove = async (id: string, name: string) => {
    if (!confirm(`Delete project "${name}"?`)) return;
    setError(null);
    try {
      const res = await fetch(`/api/config/projects/${encodeURIComponent(id)}`, { method: "DELETE" });
      const json = await res.json();
      if (!json.success) throw new Error(json.error || "Delete failed");
      broadcastProjects();
      onProjectsChanged();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Delete failed");
    }
  };

  return (
    <>
      <button type="button" className="btn-mini btn-add-project" onClick={openAdd}>
        + Add
      </button>
      <button type="button" className="btn-mini btn-manage-projects" onClick={() => setDialog("manage")}>
        Manage
      </button>

      {dialog === "manage" && (
        <div className="ws-dialog-overlay" onClick={closeAll}>
          <div className="ws-dialog" onClick={(e) => e.stopPropagation()}>
            <div className="ws-dialog-head">
              <h2>Projects</h2>
              <button type="button" className="btn-mini btn-add-project" onClick={openAdd}>
                + Add Project
              </button>
            </div>

            {error && <div className="ws-dialog-error" role="alert">{error}</div>}

            {projects.length === 0 ? (
              <div className="ws-dialog-empty">
                No projects yet. Add one to organize your pipelines.
              </div>
            ) : (
              <ul className="project-manage-list">
                {projects.map((p) => (
                  <li key={p.id} className="project-manage-row">
                    <div className="project-manage-info">
                      <div className="project-manage-name">{p.name}</div>
                      <div className="project-manage-path" title={p.path}>{p.path}</div>
                    </div>
                    <div className="project-manage-actions">
                      <button type="button" className="btn-mini" onClick={() => openEdit(p)}>
                        Edit
                      </button>
                      <button
                        type="button"
                        className="btn-mini btn-mini-danger"
                        onClick={() => remove(p.id, p.name)}
                      >
                        Del
                      </button>
                    </div>
                  </li>
                ))}
              </ul>
            )}

            <div className="ws-dialog-actions">
              <button type="button" className="btn-mini" onClick={closeAll}>Close</button>
            </div>
          </div>
        </div>
      )}

      {dialog === "form" && (
        <div className="ws-dialog-overlay" onClick={() => setDialog("manage")}>
          <div className="ws-dialog" onClick={(e) => e.stopPropagation()}>
            <h2>{formMode === "add" ? "Add Project" : "Edit Project"}</h2>

            {error && <div className="ws-dialog-error" role="alert">{error}</div>}

            <div className="ws-field">
              <label htmlFor="pm-name">Name</label>
              <input
                id="pm-name"
                value={formName}
                onChange={(e) => setFormName(e.target.value)}
                placeholder="e.g. my-app"
                maxLength={80}
                autoFocus
              />
            </div>

            <div className="ws-field">
              <label htmlFor="pm-path">Folder Path</label>
              <div className="ws-path-row">
                <input
                  id="pm-path"
                  value={formPath}
                  onChange={(e) => setFormPath(e.target.value)}
                  placeholder="/Users/you/code/my-app"
                  readOnly
                />
                <button type="button" className="btn-mini" onClick={openBrowse}>
                  Browse…
                </button>
              </div>
            </div>

            <div className="ws-dialog-actions">
              <button type="button" className="btn-mini" onClick={() => setDialog("manage")}>
                Cancel
              </button>
              <button
                type="button"
                className="btn-mini btn-mini-primary"
                onClick={save}
                disabled={saving || !formName.trim() || !formPath.trim()}
              >
                {saving ? "Saving…" : "Save"}
              </button>
            </div>
          </div>
        </div>
      )}

      {dialog === "browse" && (
        <div className="ws-dialog-overlay" onClick={() => setDialog("form")}>
          <div className="ws-dialog ws-dialog-wide" onClick={(e) => e.stopPropagation()}>
            <h2>Select Folder</h2>
            <div className="ws-browse-path" title={browsePath}>{browsePath}</div>

            {browseError && <div className="ws-dialog-error" role="alert">{browseError}</div>}

            <div className="ws-browse-nav">
              {browseParent && (
                <button
                  type="button"
                  className="btn-mini"
                  onClick={() => fetchDir(browseParent)}
                  disabled={browseLoading}
                >
                  .. Up
                </button>
              )}
              {browsePath !== browseHome && (
                <button
                  type="button"
                  className="btn-mini"
                  onClick={() => fetchDir(browseHome)}
                  disabled={browseLoading}
                >
                  ~ Home
                </button>
              )}
            </div>

            <div className="ws-browse-list">
              {browseLoading ? (
                <div className="ws-browse-empty">Loading…</div>
              ) : browseEntries.length === 0 ? (
                <div className="ws-browse-empty">No subdirectories</div>
              ) : (
                browseEntries.map((entry) => (
                  <button
                    key={entry.name}
                    type="button"
                    className="ws-browse-entry"
                    onClick={() => fetchDir(browsePath + "/" + entry.name)}
                  >
                    {entry.name}/
                  </button>
                ))
              )}
            </div>

            <div className="ws-dialog-actions">
              <button type="button" className="btn-mini" onClick={() => setDialog("form")}>
                Cancel
              </button>
              <button
                type="button"
                className="btn-mini btn-mini-primary"
                onClick={selectDir}
                disabled={!browsePath}
              >
                Select This Folder
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
