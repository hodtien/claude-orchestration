"use client";

import { useCallback, useState } from "react";

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
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

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
          body: JSON.stringify({ rawIdea: trimmed })
        });
        const body = (await res.json()) as CreateResponse;
        if (!res.ok || !body.success) {
          throw new Error(body.error || `HTTP ${res.status}`);
        }
        setIdea("");
        if (body.data?.id) onCreated(body.data.id);
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setSubmitting(false);
      }
    },
    [idea, submitting, onCreated]
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
