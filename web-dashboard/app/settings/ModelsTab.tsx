"use client";

import { Fragment, useCallback, useEffect, useState } from "react";
import { broadcastConfigChange, type ModelView } from "../../lib/use-model-config";

interface ModelsData {
  models: ModelView[];
  defaultModel: string | undefined;
  allowlist: string[];
}

interface FormData {
  id: string;
  channel: string;
  tier: string;
  cost_hint: string;
  strengths: string;
  note: string;
}

const EMPTY_FORM: FormData = {
  id: "",
  channel: "router",
  tier: "",
  cost_hint: "",
  strengths: "",
  note: "",
};

const CHANNELS = ["router", "gemini_cli", "copilot_cli"];
const TIERS = ["", "ultra", "premium", "fast", "cheap", "code-review"];
const COST_HINTS = ["", "very-high", "high", "medium-high", "medium", "medium-low", "low"];

function groupByChannel(models: ModelView[]): Map<string, ModelView[]> {
  const groups = new Map<string, ModelView[]>();
  for (const m of models) {
    const ch = m.channel ?? "other";
    const arr = groups.get(ch) ?? [];
    arr.push(m);
    groups.set(ch, arr);
  }
  return groups;
}

export function ModelsTab() {
  const [data, setData] = useState<ModelsData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [dialog, setDialog] = useState<"add" | "edit" | null>(null);
  const [editId, setEditId] = useState<string | null>(null);
  const [form, setForm] = useState<FormData>(EMPTY_FORM);
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      const res = await fetch("/api/config/models", { cache: "no-store" });
      const json = await res.json();
      if (!json.success) throw new Error(json.error);
      setData(json.data);
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

  const openAdd = () => {
    setForm(EMPTY_FORM);
    setEditId(null);
    setDialog("add");
  };

  const openEdit = (m: ModelView) => {
    setForm({
      id: m.id,
      channel: m.channel,
      tier: m.tier ?? "",
      cost_hint: m.cost_hint ?? "",
      strengths: (m.strengths ?? []).join(", "),
      note: m.note ?? "",
    });
    setEditId(m.id);
    setDialog("edit");
  };

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      const entry: Record<string, unknown> = {
        channel: form.channel,
      };
      if (form.tier) entry.tier = form.tier;
      if (form.cost_hint) entry.cost_hint = form.cost_hint;
      const strengthsArr = form.strengths.split(",").map((s) => s.trim()).filter(Boolean);
      if (strengthsArr.length > 0) entry.strengths = strengthsArr;
      if (form.note) entry.note = form.note;

      const isEdit = dialog === "edit" && editId;
      const url = isEdit ? `/api/config/models/${encodeURIComponent(editId)}` : "/api/config/models";
      const method = isEdit ? "PATCH" : "POST";
      const body = isEdit ? { entry } : { id: form.id, entry };
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

  const remove = async (id: string) => {
    if (!confirm(`Delete model "${id}"?`)) return;
    setError(null);
    try {
      const res = await fetch(`/api/config/models/${encodeURIComponent(id)}`, { method: "DELETE" });
      const json = await res.json();
      if (!json.success) throw new Error(json.error);
      broadcastConfigChange();
      await load();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Delete failed");
    }
  };

  const setDefault = async (id: string) => {
    setError(null);
    try {
      const res = await fetch("/api/config/default-model", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ model: id }),
      });
      const json = await res.json();
      if (!json.success) throw new Error(json.error);
      broadcastConfigChange();
      await load();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed to set default");
    }
  };

  if (loading && !data) return <div className="loading" aria-live="polite">Loading models...</div>;

  const groups: Map<string, ModelView[]> = data
    ? groupByChannel(data.models)
    : new Map<string, ModelView[]>();

  return (
    <div>
      {error && <div className="error-banner" role="alert" aria-live="assertive">{error}</div>}

      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
        <div style={{ fontSize: 13, color: "var(--text-dim)" }}>
          {data?.models.length ?? 0} models registered
          {data?.defaultModel && (
            <> &middot; Default: <span className="chip default">{data.defaultModel}</span></>
          )}
        </div>
        <button className="btn btn-primary" onClick={openAdd}>+ Add Model</button>
      </div>

      <table className="config-table">
        <thead>
          <tr>
            <th>Model ID</th>
            <th>Channel</th>
            <th>Tier</th>
            <th>Cost</th>
            <th>Strengths</th>
            <th style={{ width: 120 }}></th>
          </tr>
        </thead>
        <tbody>
          {[...groups.entries()].map(([ch, models]) => (
            <Fragment key={`ch-${ch}`}>
              <tr className="category-row">
                <td colSpan={6}>{ch}</td>
              </tr>
              {models.map((m: ModelView) => (
                <tr key={m.id}>
                  <td>
                    <span style={{ fontFamily: "var(--mono)" }}>{m.id}</span>
                    {m.isDefault && <span className="chip default" style={{ marginLeft: 6 }}>default</span>}
                  </td>
                  <td><span className="chip">{m.channel}</span></td>
                  <td>{m.tier ?? "—"}</td>
                  <td>{m.cost_hint ?? "—"}</td>
                  <td>
                    {(m.strengths ?? []).map((s: string) => (
                      <span key={s} className="chip">{s}</span>
                    ))}
                  </td>
                  <td style={{ textAlign: "right" }}>
                    {!m.isDefault && (
                      <button className="btn btn-ghost btn-sm" onClick={() => setDefault(m.id)}>
                        Set default
                      </button>
                    )}
                    <button className="btn btn-ghost btn-sm" onClick={() => openEdit(m)}>Edit</button>
                    <button className="btn btn-danger btn-sm" onClick={() => remove(m.id)}>Del</button>
                  </td>
                </tr>
              ))}
            </Fragment>
          ))}
        </tbody>
      </table>

      {groups.size === 0 && <div className="empty-state">No models configured</div>}

      {dialog && (
        <div className="dialog-overlay" onClick={() => setDialog(null)}>
          <div className="dialog" onClick={(e) => e.stopPropagation()}>
            <h2>{dialog === "add" ? "Add Model" : `Edit ${editId}`}</h2>

            {dialog === "add" && (
              <div className="field">
                <label>Model ID</label>
                <input
                  value={form.id}
                  onChange={(e) => setForm({ ...form, id: e.target.value })}
                  placeholder="e.g. cc/claude-sonnet-4-6"
                />
              </div>
            )}

            <div className="field">
              <label>Channel</label>
              <select value={form.channel} onChange={(e) => setForm({ ...form, channel: e.target.value })}>
                {CHANNELS.map((c) => <option key={c} value={c}>{c}</option>)}
              </select>
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
              <div className="field">
                <label>Tier</label>
                <select value={form.tier} onChange={(e) => setForm({ ...form, tier: e.target.value })}>
                  {TIERS.map((t) => <option key={t} value={t}>{t || "(none)"}</option>)}
                </select>
              </div>
              <div className="field">
                <label>Cost Hint</label>
                <select value={form.cost_hint} onChange={(e) => setForm({ ...form, cost_hint: e.target.value })}>
                  {COST_HINTS.map((c) => <option key={c} value={c}>{c || "(none)"}</option>)}
                </select>
              </div>
            </div>

            <div className="field">
              <label>Strengths (comma-separated)</label>
              <input
                value={form.strengths}
                onChange={(e) => setForm({ ...form, strengths: e.target.value })}
                placeholder="e.g. code, analysis, vision"
              />
            </div>

            <div className="field">
              <label>Note</label>
              <input
                value={form.note}
                onChange={(e) => setForm({ ...form, note: e.target.value })}
                placeholder="Optional note"
              />
            </div>

            <div className="dialog-actions">
              <button className="btn btn-ghost" onClick={() => setDialog(null)}>Cancel</button>
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
