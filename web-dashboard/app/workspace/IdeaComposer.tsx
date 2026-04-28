"use client";

import { useCallback, useEffect, useState } from "react";

interface ProjectOption {
  id: string;
  name: string;
}

interface ModelOption {
  id: string;
  channel: string;
  tier?: string;
}

interface IdeaComposerProps {
  onCreated: (id: string) => void;
}

interface CreateResponse {
  success: boolean;
  data?: { id: string };
  error?: string;
}

export default function IdeaComposer({ onCreated }: IdeaComposerProps) {
  const [idea, setIdea] = useState("");
  const [project, setProject] = useState("");
  const [modelOverride, setModelOverride] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [registeredProjects, setRegisteredProjects] = useState<ProjectOption[]>([]);
  const [availableModels, setAvailableModels] = useState<ModelOption[]>([]);

  useEffect(() => {
    async function loadProjects() {
      try {
        const res = await fetch("/api/config/projects", { cache: "no-store" });
        const json = await res.json();
        if (json.success && json.data) {
          setRegisteredProjects(
            (json.data as Array<{ id: string; name: string }>).map((p) => ({
              id: p.id,
              name: p.name,
            }))
          );
        }
      } catch {
        // non-critical — dropdown just stays empty
      }
    }
    async function loadModels() {
      try {
        const res = await fetch("/api/config/models", { cache: "no-store" });
        const json = await res.json();
        if (json.success && json.data?.models) {
          const all = json.data.models as Array<{
            id: string;
            channel: string;
            tier?: string;
            inSettingsAllowlist: boolean;
          }>;
          setAvailableModels(
            all
              .filter((m) => m.inSettingsAllowlist && m.channel === "router")
              .map((m) => ({ id: m.id, channel: m.channel, tier: m.tier }))
          );
        }
      } catch {
        // non-critical
      }
    }
    void loadProjects();
    void loadModels();

    if (typeof BroadcastChannel === "undefined") return;
    const bc = new BroadcastChannel("config:projects");
    bc.onmessage = () => { void loadProjects(); };
    return () => bc.close();
  }, []);

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      const trimmed = idea.trim();
      if (!trimmed || submitting) return;

      setSubmitting(true);
      setError(null);
      try {
        const res = await fetch("/api/pipelines", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            rawIdea: trimmed,
            ...(project ? { project } : {}),
            ...(modelOverride ? { modelOverride } : {})
          })
        });
        const body = (await res.json()) as CreateResponse;
        if (!res.ok || !body.success) {
          throw new Error(body.error || `HTTP ${res.status}`);
        }
        setIdea("");
        setProject("");
        setModelOverride("");
        if (body.data?.id) onCreated(body.data.id);
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setSubmitting(false);
      }
    },
    [idea, project, modelOverride, submitting, onCreated]
  );

  return (
    <form className="idea-composer" onSubmit={handleSubmit}>
      <textarea
        className="idea-input"
        placeholder="Describe your idea… e.g. &quot;Add a caching layer to /api/tasks with 30s TTL&quot;"
        value={idea}
        onChange={(e) => setIdea(e.target.value)}
        rows={3}
        disabled={submitting}
      />
      <div className="composer-footer">
        <div className="composer-project">
          <select
            className="project-input"
            value={project}
            onChange={(e) => setProject(e.target.value)}
            disabled={submitting}
          >
            <option value="">No project</option>
            {registeredProjects.map((p) => (
              <option key={p.id} value={p.name}>
                {p.name}
              </option>
            ))}
          </select>
        </div>
        <div className="composer-model">
          <select
            className="model-select"
            value={modelOverride}
            onChange={(e) => setModelOverride(e.target.value)}
            disabled={submitting}
            title="Model override (Auto = use task_mapping routing)"
          >
            <option value="">Auto (task routing)</option>
            {availableModels.map((m) => (
              <option key={m.id} value={m.id}>
                {m.id}
                {m.tier ? ` · ${m.tier}` : ""}
              </option>
            ))}
          </select>
        </div>
        {error && <span className="composer-error">{error}</span>}
        <button
          type="submit"
          className="btn-primary"
          disabled={!idea.trim() || submitting}
        >
          {submitting ? "Submitting…" : "Submit Idea"}
        </button>
      </div>
    </form>
  );
}
