"use client";

import { useCallback, useEffect, useState } from "react";
import { broadcastConfigChange } from "../../lib/use-model-config";

interface RoutingEntry {
  task_type: string;
  mode?: string;
  interactive_agent?: string;
  parallel?: string[];
  fallback?: string[];
  consensus?: boolean;
  rationale?: string;
  note?: string;
  depends_on?: string[];
}

interface RoutingData {
  task_mapping: Record<string, Omit<RoutingEntry, "task_type">>;
  parallel_policy?: Record<string, unknown>;
  hybrid_policy?: Record<string, unknown>;
}

const MODES = ["auto", "async", "interactive"] as const;

function flatten(tm: Record<string, Omit<RoutingEntry, "task_type">>): RoutingEntry[] {
  return Object.entries(tm).map(([task_type, entry]) => ({ task_type, ...entry }));
}

export function RoutingTab() {
  const [data, setData] = useState<RoutingData | null>(null);
  const [models, setModels] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editTaskType, setEditTaskType] = useState<string | null>(null);
  const [form, setForm] = useState<RoutingEntry | null>(null);
  const [saving, setSaving] = useState(false);

  const entries = data ? flatten(data.task_mapping) : [];

  const load = useCallback(async () => {
    try {
      setLoading(true);
      const [routingRes, modelsRes] = await Promise.all([
        fetch("/api/config/routing", { cache: "no-store" }),
        fetch("/api/config/models", { cache: "no-store" }),
      ]);
      const routingJson = await routingRes.json();
      const modelsJson = await modelsRes.json();
      if (!routingJson.success) throw new Error(routingJson.error);
      if (!modelsJson.success) throw new Error(modelsJson.error);
      setData(routingJson.data);
      setModels(modelsJson.data.models.map((m: { id: string }) => m.id));
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
    const bc = new BroadcastChannel("config:models");
    bc.onmessage = () => { load(); };
    return () => bc.close();
  }, [load]);

  const openEdit = (entry: RoutingEntry) => {
    setForm({
      ...entry,
      parallel: entry.parallel ?? [],
      fallback: entry.fallback ?? [],
      depends_on: entry.depends_on ?? [],
    });
    setEditTaskType(entry.task_type);
  };

  const save = async () => {
    if (!form || !editTaskType) return;
    setSaving(true);
    setError(null);
    try {
      const entry = {
        mode: form.mode || undefined,
        interactive_agent: form.interactive_agent || undefined,
        parallel: form.parallel?.length ? form.parallel : undefined,
        fallback: form.fallback?.length ? form.fallback : undefined,
        consensus: form.consensus || undefined,
        rationale: form.rationale || undefined,
        note: form.note || undefined,
      };
      const res = await fetch(`/api/config/routing/${encodeURIComponent(editTaskType)}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ entry }),
      });
      const json = await res.json();
      if (!json.success) throw new Error(json.error);
      broadcastConfigChange();
      setEditTaskType(null);
      setForm(null);
      await load();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Save failed");
    } finally {
      setSaving(false);
    }
  };

  const toggleListItem = (list: string[] | undefined, model: string): string[] => {
    const cur = list ?? [];
    return cur.includes(model) ? cur.filter((x) => x !== model) : [...cur, model];
  };

  if (loading && !data) return <div className="loading" aria-live="polite">Loading routing...</div>;

  return (
    <div>
      {error && <div className="error-banner" role="alert" aria-live="assertive">{error}</div>}

      <div style={{ fontSize: 13, color: "var(--text-dim)", marginBottom: 16 }}>
        {entries.length} task types configured
      </div>

      <table className="config-table">
        <thead>
          <tr>
            <th>Task Type</th>
            <th>Mode</th>
            <th>Parallel</th>
            <th>Fallback</th>
            <th>Flags</th>
            <th style={{ width: 80 }}></th>
          </tr>
        </thead>
        <tbody>
          {entries.map((entry) => (
            <tr key={entry.task_type}>
              <td><span style={{ fontFamily: "var(--mono)" }}>{entry.task_type}</span></td>
              <td>
                {entry.mode && <span className="chip">{entry.mode}</span>}
              </td>
              <td>
                {(entry.parallel ?? []).map((m) => <span key={m} className="chip">{m}</span>)}
              </td>
              <td>
                {(entry.fallback ?? []).map((m) => <span key={m} className="chip">{m}</span>)}
              </td>
              <td>
                {entry.consensus && <span className="chip ok">consensus</span>}
                {entry.interactive_agent && (
                  <span className="chip default">{entry.interactive_agent}</span>
                )}
                {(entry.depends_on ?? []).length > 0 && (
                  <span className="chip warn">deps</span>
                )}
              </td>
              <td style={{ textAlign: "right" }}>
                <button className="btn btn-ghost btn-sm" onClick={() => openEdit(entry)}>Edit</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {entries.length === 0 && <div className="empty-state">No routing configured</div>}

      {form && editTaskType && (
        <div className="dialog-overlay" onClick={() => { setEditTaskType(null); setForm(null); }}>
          <div className="dialog" onClick={(e) => e.stopPropagation()} style={{ minWidth: 520 }}>
            <h2>Edit routing: {editTaskType}</h2>

            <div className="field">
              <label>Mode</label>
              <select
                value={form.mode ?? ""}
                onChange={(e) => setForm({ ...form, mode: e.target.value || undefined })}
              >
                <option value="">-- auto --</option>
                {MODES.filter((m) => m !== "auto").map((m) => (
                  <option key={m} value={m}>{m}</option>
                ))}
              </select>
            </div>

            <div className="field">
              <label>Interactive Agent</label>
              <input
                value={form.interactive_agent ?? ""}
                onChange={(e) => setForm({ ...form, interactive_agent: e.target.value || undefined })}
                placeholder="e.g. copilot-agent"
              />
            </div>

            <div className="field">
              <label>Parallel Models</label>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 4 }}>
                {models.map((m) => {
                  const active = form.parallel?.includes(m);
                  return (
                    <button
                      key={m}
                      className={`chip ${active ? "default" : ""}`}
                      style={{ cursor: "pointer", border: "none" }}
                      onClick={() => setForm({ ...form, parallel: toggleListItem(form.parallel, m) })}
                    >
                      {active ? "\u2713 " : ""}{m}
                    </button>
                  );
                })}
              </div>
            </div>

            <div className="field">
              <label>Fallback Models</label>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 4 }}>
                {models.map((m) => {
                  const active = form.fallback?.includes(m);
                  return (
                    <button
                      key={m}
                      className={`chip ${active ? "default" : ""}`}
                      style={{ cursor: "pointer", border: "none" }}
                      onClick={() => setForm({ ...form, fallback: toggleListItem(form.fallback, m) })}
                    >
                      {active ? "\u2713 " : ""}{m}
                    </button>
                  );
                })}
              </div>
            </div>

            <div className="field toggle-row">
              <input
                type="checkbox"
                className="toggle"
                checked={form.consensus ?? false}
                onChange={(e) => setForm({ ...form, consensus: e.target.checked })}
                id="consensus-toggle"
              />
              <label htmlFor="consensus-toggle" style={{ margin: 0 }}>Consensus mode</label>
            </div>

            <div className="field">
              <label>Rationale</label>
              <input
                value={form.rationale ?? ""}
                onChange={(e) => setForm({ ...form, rationale: e.target.value || undefined })}
                placeholder="Why this routing?"
              />
            </div>

            <div className="dialog-actions">
              <button className="btn btn-ghost" onClick={() => { setEditTaskType(null); setForm(null); }}>Cancel</button>
              <button className="btn btn-primary" onClick={save} disabled={saving}>
                {saving ? "Saving..." : "Save"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
