"use client";

import { useCallback, useEffect, useState } from "react";
import { broadcastConfigChange } from "../../lib/use-model-config";

interface AgentEntry {
  id: string;
  channel: string;
  cost_tier: number;
  cost_per_1k_tokens: number;
  capabilities: string[];
  note?: string;
}

interface FormData {
  id: string;
  channel: string;
  cost_tier: number;
  cost_per_1k_tokens: number;
  capabilities: string;
  note: string;
}

const EMPTY_FORM: FormData = {
  id: "",
  channel: "router",
  cost_tier: 3,
  cost_per_1k_tokens: 0,
  capabilities: "",
  note: "",
};

const CHANNELS = ["router", "gemini_cli", "copilot_cli"];

export function AgentsTab() {
  const [agents, setAgents] = useState<AgentEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [dialog, setDialog] = useState<"add" | "edit" | null>(null);
  const [editId, setEditId] = useState<string | null>(null);
  const [form, setForm] = useState<FormData>(EMPTY_FORM);
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      const res = await fetch("/api/config/agents", { cache: "no-store" });
      const json = await res.json();
      if (!json.success) throw new Error(json.error);
      const agentsMap = json.data.agents ?? json.data;
      const list = typeof agentsMap === "object" && !Array.isArray(agentsMap)
        ? Object.entries(agentsMap).map(([id, a]) => ({ id, ...(a as Record<string, unknown>) })) as AgentEntry[]
        : agentsMap as AgentEntry[];
      setAgents(list);
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

  const openEdit = (a: AgentEntry) => {
    setForm({
      id: a.id,
      channel: a.channel,
      cost_tier: a.cost_tier,
      cost_per_1k_tokens: a.cost_per_1k_tokens,
      capabilities: a.capabilities.join(", "),
      note: a.note ?? "",
    });
    setEditId(a.id);
    setDialog("edit");
  };

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      const entry = {
        channel: form.channel,
        cost_tier: form.cost_tier,
        cost_per_1k_tokens: form.cost_per_1k_tokens,
        capabilities: form.capabilities.split(",").map((s) => s.trim()).filter(Boolean),
        note: form.note || undefined,
      };
      const isEdit = dialog === "edit" && editId;
      const url = isEdit ? `/api/config/agents/${encodeURIComponent(editId)}` : "/api/config/agents";
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
    if (!confirm(`Delete agent "${id}"?`)) return;
    setError(null);
    try {
      const res = await fetch(`/api/config/agents/${encodeURIComponent(id)}`, { method: "DELETE" });
      const json = await res.json();
      if (!json.success) throw new Error(json.error);
      broadcastConfigChange();
      await load();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Delete failed");
    }
  };

  if (loading && !agents.length) return <div className="loading" aria-live="polite">Loading agents...</div>;

  return (
    <div>
      {error && <div className="error-banner" role="alert" aria-live="assertive">{error}</div>}

      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
        <div style={{ fontSize: 13, color: "var(--text-dim)" }}>
          {agents.length} agents configured
        </div>
        <button className="btn btn-primary" onClick={openAdd}>+ Add Agent</button>
      </div>

      <table className="config-table">
        <thead>
          <tr>
            <th>Agent ID</th>
            <th>Channel</th>
            <th>Tier</th>
            <th>Cost/1k</th>
            <th>Capabilities</th>
            <th style={{ width: 100 }}></th>
          </tr>
        </thead>
        <tbody>
          {agents.map((a) => (
            <tr key={a.id}>
              <td><span style={{ fontFamily: "var(--mono)" }}>{a.id}</span></td>
              <td><span className="chip">{a.channel}</span></td>
              <td>{a.cost_tier}</td>
              <td style={{ fontFamily: "var(--mono)" }}>${a.cost_per_1k_tokens.toFixed(4)}</td>
              <td>
                {a.capabilities.map((c) => <span key={c} className="chip">{c}</span>)}
              </td>
              <td style={{ textAlign: "right" }}>
                <button className="btn btn-ghost btn-sm" onClick={() => openEdit(a)}>Edit</button>
                <button className="btn btn-danger btn-sm" onClick={() => remove(a.id)}>Del</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {agents.length === 0 && <div className="empty-state">No agents configured</div>}

      {dialog && (
        <div className="dialog-overlay" onClick={() => setDialog(null)}>
          <div className="dialog" onClick={(e) => e.stopPropagation()}>
            <h2>{dialog === "add" ? "Add Agent" : `Edit ${editId}`}</h2>

            {dialog === "add" && (
              <div className="field">
                <label>Agent ID</label>
                <input
                  value={form.id}
                  onChange={(e) => setForm({ ...form, id: e.target.value })}
                  placeholder="e.g. gemini-agent"
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
                <label>Cost Tier (1-5)</label>
                <input
                  type="number" min={1} max={5}
                  value={form.cost_tier}
                  onChange={(e) => setForm({ ...form, cost_tier: Number(e.target.value) })}
                />
              </div>
              <div className="field">
                <label>Cost per 1k tokens ($)</label>
                <input
                  type="number" min={0} step={0.0001}
                  value={form.cost_per_1k_tokens}
                  onChange={(e) => setForm({ ...form, cost_per_1k_tokens: Number(e.target.value) })}
                />
              </div>
            </div>

            <div className="field">
              <label>Capabilities (comma-separated)</label>
              <input
                value={form.capabilities}
                onChange={(e) => setForm({ ...form, capabilities: e.target.value })}
                placeholder="e.g. code_review, implement_feature"
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
