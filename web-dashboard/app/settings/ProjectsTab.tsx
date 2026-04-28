"use client";

import { useCallback, useEffect, useState } from "react";
import { broadcastConfigChange } from "../../lib/use-model-config";

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

type Dialog = "add" | "edit" | "browse" | null;

export function ProjectsTab() {
  const [projects, setProjects] = useState<ProjectEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [dialog, setDialog] = useState<Dialog>(null);
  const [editId, setEditId] = useState<string | null>(null);
  const [formName, setFormName] = useState("");
  const [formPath, setFormPath] = useState("");
  const [saving, setSaving] = useState(false);

  const [browsePath, setBrowsePath] = useState("");
  const [browseEntries, setBrowseEntries] = useState<DirEntry[]>([]);
  const [browseParent, setBrowseParent] = useState<string | null>(null);
  const [browseHome, setBrowseHome] = useState("");
  const [browseLoading, setBrowseLoading] = useState(false);
  const [browseError, setBrowseError] = useState<string | null>(null);
  const [browseReturnDialog, setBrowseReturnDialog] = useState<"add" | "edit">("add");

  const load = useCallback(async () => {
    try {
      setLoading(true);
      const res = await fetch("/api/config/projects", { cache: "no-store" });
      const json = await res.json();
      if (!json.success) throw new Error(json.error);
      setProjects(json.data ?? []);
      setError(null);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Load failed");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  useEffect(() => {
    if (typeof BroadcastChannel === "undefined") return;
    const bc = new BroadcastChannel("config:projects");
    bc.onmessage = () => { load(); };
    return () => bc.close();
  }, [load]);

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

  const openBrowse = useCallback((returnTo: "add" | "edit") => {
    setBrowseReturnDialog(returnTo);
    setDialog("browse");
    void fetchDir(formPath || "~");
  }, [formPath, fetchDir]);

  const selectDir = useCallback(() => {
    setFormPath(browsePath);
    setDialog(browseReturnDialog);
  }, [browsePath, browseReturnDialog]);

  const openAdd = () => {
    setFormName("");
    setFormPath("");
    setEditId(null);
    setDialog("add");
  };

  const openEdit = (p: ProjectEntry) => {
    setFormName(p.name);
    setFormPath(p.path);
    setEditId(p.id);
    setDialog("edit");
  };

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      const isEdit = dialog === "edit" && editId;
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
      if (!json.success) throw new Error(json.error);
      broadcastConfigChange();
      setDialog(null);
      await load();
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
      if (!json.success) throw new Error(json.error);
      broadcastConfigChange();
      await load();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Delete failed");
    }
  };

  if (loading && !projects.length) return <div className="loading" aria-live="polite">Loading projects...</div>;

  const formDialog = dialog === "add" || dialog === "edit";

  return (
    <div>
      {error && <div className="error-banner" role="alert" aria-live="assertive">{error}</div>}

      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
        <div style={{ fontSize: 13, color: "var(--text-dim)" }}>
          {projects.length} projects registered
        </div>
        <button className="btn btn-primary" onClick={openAdd}>+ Add Project</button>
      </div>

      <table className="config-table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Path</th>
            <th>Created</th>
            <th style={{ width: 100 }}></th>
          </tr>
        </thead>
        <tbody>
          {projects.map((p) => (
            <tr key={p.id}>
              <td style={{ fontWeight: 500 }}>{p.name}</td>
              <td><span style={{ fontFamily: "var(--mono)", fontSize: 12 }}>{p.path}</span></td>
              <td style={{ fontSize: 12, color: "var(--text-dim)" }}>
                {new Date(p.createdAt).toLocaleDateString()}
              </td>
              <td style={{ textAlign: "right" }}>
                <button className="btn btn-ghost btn-sm" onClick={() => openEdit(p)}>Edit</button>
                <button className="btn btn-danger btn-sm" onClick={() => remove(p.id, p.name)}>Del</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {projects.length === 0 && <div className="empty-state">No projects registered. Add one to get started.</div>}

      {formDialog && (
        <div className="dialog-overlay" onClick={() => setDialog(null)}>
          <div className="dialog" onClick={(e) => e.stopPropagation()}>
            <h2>{dialog === "add" ? "Add Project" : `Edit ${formName || editId}`}</h2>

            <div className="field">
              <label>Project Name</label>
              <input
                value={formName}
                onChange={(e) => setFormName(e.target.value)}
                placeholder="e.g. my-app"
                maxLength={80}
              />
            </div>

            <div className="field">
              <label>Project Path</label>
              <div style={{ display: "flex", gap: 8 }}>
                <input
                  value={formPath}
                  onChange={(e) => setFormPath(e.target.value)}
                  placeholder="/Users/you/code/my-app"
                  style={{ flex: 1 }}
                  readOnly
                />
                <button
                  type="button"
                  className="btn btn-ghost"
                  onClick={() => openBrowse(dialog as "add" | "edit")}
                  style={{ whiteSpace: "nowrap" }}
                >
                  Browse...
                </button>
              </div>
            </div>

            <div className="dialog-actions">
              <button className="btn btn-ghost" onClick={() => setDialog(null)}>Cancel</button>
              <button
                className="btn btn-primary"
                onClick={save}
                disabled={saving || !formName.trim() || !formPath.trim()}
              >
                {saving ? "Saving..." : "Save"}
              </button>
            </div>
          </div>
        </div>
      )}

      {dialog === "browse" && (
        <div className="dialog-overlay" onClick={() => setDialog(browseReturnDialog)}>
          <div className="dialog" onClick={(e) => e.stopPropagation()} style={{ minWidth: 500 }}>
            <h2>Select Folder</h2>
            <div style={{ fontSize: 12, fontFamily: "var(--mono)", color: "var(--text-dim)", marginBottom: 12, wordBreak: "break-all" }}>
              {browsePath}
            </div>

            {browseError && <div className="error-banner">{browseError}</div>}

            <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
              {browseParent && (
                <button
                  className="btn btn-ghost btn-sm"
                  onClick={() => fetchDir(browseParent)}
                  disabled={browseLoading}
                >
                  .. Up
                </button>
              )}
              {browsePath !== browseHome && (
                <button
                  className="btn btn-ghost btn-sm"
                  onClick={() => fetchDir(browseHome)}
                  disabled={browseLoading}
                >
                  ~ Home
                </button>
              )}
            </div>

            <div style={{
              maxHeight: 300,
              overflowY: "auto",
              border: "1px solid var(--border)",
              borderRadius: 6,
              background: "var(--bg)",
            }}>
              {browseLoading ? (
                <div style={{ padding: 16, textAlign: "center", color: "var(--text-dim)", fontSize: 13 }}>Loading...</div>
              ) : browseEntries.length === 0 ? (
                <div style={{ padding: 16, textAlign: "center", color: "var(--text-dim)", fontSize: 13 }}>No subdirectories</div>
              ) : (
                browseEntries.map((entry) => (
                  <button
                    key={entry.name}
                    type="button"
                    style={{
                      display: "block",
                      width: "100%",
                      textAlign: "left",
                      padding: "6px 12px",
                      fontSize: 13,
                      fontFamily: "var(--mono)",
                      background: "none",
                      border: "none",
                      borderBottom: "1px solid var(--border)",
                      color: "var(--text)",
                      cursor: "pointer",
                    }}
                    onClick={() => {
                      const next = browsePath + "/" + entry.name;
                      void fetchDir(next);
                    }}
                    onMouseOver={(e) => { (e.currentTarget as HTMLElement).style.background = "var(--surface-2)"; }}
                    onMouseOut={(e) => { (e.currentTarget as HTMLElement).style.background = "none"; }}
                  >
                    {entry.name}/
                  </button>
                ))
              )}
            </div>

            <div className="dialog-actions">
              <button className="btn btn-ghost" onClick={() => setDialog(browseReturnDialog)}>Cancel</button>
              <button className="btn btn-primary" onClick={selectDir} disabled={!browsePath}>
                Select This Folder
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
