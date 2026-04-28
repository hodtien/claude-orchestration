"use client";

import { useCallback, useEffect, useState } from "react";
import { useModelConfig } from "../../lib/use-model-config";

interface BatchOverridePanelProps {
  pipelineId: string;
  decomposeStatus: string;
  dispatchStatus: string;
}

export default function BatchOverridePanel({
  pipelineId,
  decomposeStatus,
  dispatchStatus,
}: BatchOverridePanelProps) {
  const { config } = useModelConfig();
  const [open, setOpen] = useState(false);
  const [defaultModel, setDefaultModel] = useState<string>("");
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!defaultModel && config?.defaultModel) {
      setDefaultModel(config.defaultModel);
    }
  }, [config, defaultModel]);

  if (decomposeStatus !== "done" || dispatchStatus !== "pending") {
    return null;
  }

  const save = useCallback(async () => {
    setSaving(true);
    setErr(null);
    setMsg(null);
    try {
      const res = await fetch(
        `/api/pipelines/${pipelineId}/dispatch-config`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            default_model: defaultModel || undefined,
          }),
        }
      );
      const json = await res.json();
      if (!json.success) throw new Error(json.error ?? "Save failed");
      setMsg("Override saved. Will apply to next dispatch.");
    } catch (e: unknown) {
      setErr(e instanceof Error ? e.message : "Save failed");
    } finally {
      setSaving(false);
    }
  }, [pipelineId, defaultModel]);

  const models = config?.models ?? [];

  return (
    <div className="batch-override-panel">
      <button
        type="button"
        className="batch-override-toggle"
        onClick={() => setOpen((v) => !v)}
      >
        {open ? "\u25be" : "\u25b8"} Configure this batch
      </button>
      {open && (
        <div className="batch-override-body">
          <div className="batch-override-hint">
            Override the model used for this batch only. Global config
            (Settings) is unchanged.
          </div>
          <div className="batch-override-field">
            <label htmlFor="batch-default-model">Default model</label>
            <select
              id="batch-default-model"
              value={defaultModel}
              onChange={(e) => setDefaultModel(e.target.value)}
              disabled={saving}
            >
              <option value="">— use global default —</option>
              {models.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.id}
                </option>
              ))}
            </select>
          </div>
          <div className="batch-override-actions">
            {msg && <span className="dim">{msg}</span>}
            {err && <span className="composer-error">{err}</span>}
            <button
              type="button"
              className="btn-primary btn-sm"
              onClick={save}
              disabled={saving}
            >
              {saving ? "Saving\u2026" : "Save override"}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
