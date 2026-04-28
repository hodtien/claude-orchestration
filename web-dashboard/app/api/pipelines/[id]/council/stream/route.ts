import { loadPipeline, updateStage } from "@/lib/pipeline";
import {
  createMessageWithRetry,
  streamMessage,
  MAX_TOKENS,
  COUNCIL_PROMPTS,
  resolveModel
} from "@/lib/anthropic-client";

export const dynamic = "force-dynamic";
export const revalidate = 0;

async function callVoice(
  voice: keyof typeof COUNCIL_PROMPTS,
  expandedSpec: string,
  model: string,
  priorVoices?: string,
  userNote?: string
): Promise<string> {
  const parts = [`Spec under review:\n\n${expandedSpec}`];
  if (priorVoices) parts.push(`Council feedback so far:\n\n${priorVoices}`);
  if (userNote) parts.push(`User guidance for this round:\n${userNote}`);
  const userContent = parts.join("\n\n---\n\n");
  const msg = await createMessageWithRetry({
    model,
    max_tokens: MAX_TOKENS,
    system: COUNCIL_PROMPTS[voice],
    messages: [{ role: "user", content: userContent }]
  });
  return msg.content
    .flatMap((b) => (b.type === "text" ? [b.text] : []))
    .join("\n");
}

export async function GET(
  req: Request,
  { params }: { params: { id: string } }
) {
  const id = params.id;
  const url = new URL(req.url);
  const model = await resolveModel(url.searchParams.get("model"));
  const pipeline = await loadPipeline(id);
  if (!pipeline) {
    return new Response(JSON.stringify({ error: "not found" }), {
      status: 404,
      headers: { "Content-Type": "application/json" }
    });
  }
  const expanded = pipeline.stages.expand.output;
  if (!expanded) {
    return new Response(
      JSON.stringify({ error: "expand stage has no output; run expand first" }),
      {
        status: 400,
        headers: { "Content-Type": "application/json" }
      }
    );
  }
  if (pipeline.stages.council.status === "running") {
    return new Response(JSON.stringify({ error: "already running" }), {
      status: 409,
      headers: { "Content-Type": "application/json" }
    });
  }

  const encoder = new TextEncoder();
  const send = (
    controller: ReadableStreamDefaultController,
    data: object
  ) => {
    try {
      controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`));
    } catch {
      // closed
    }
  };

  const stream = new ReadableStream({
    async start(controller) {
      const aborted = { v: false };
      req.signal.addEventListener("abort", () => {
        aborted.v = true;
      });

      try {
        await updateStage(id, "council", {
          status: "running",
          startedAt: Date.now(),
          model
        });
        send(controller, { type: "start", model });

        const expandNote = pipeline.stages.expand.userNote?.trim() || undefined;
        const councilNote =
          pipeline.stages.council.userNote?.trim() || undefined;

        send(controller, { type: "phase", phase: "voices" });
        const runVoice = async (
          voice: keyof typeof COUNCIL_PROMPTS
        ): Promise<string> => {
          send(controller, { type: "voice_start", voice });
          const text = await callVoice(
            voice,
            expanded,
            model,
            undefined,
            expandNote
          );
          send(controller, { type: "voice_done", voice });
          return text;
        };
        const [skeptic, pragmatist, critic] = await Promise.all([
          runVoice("skeptic"),
          runVoice("pragmatist"),
          runVoice("critic")
        ]);
        send(controller, { type: "voices_done" });

        const priorBlock = `### Skeptic\n${skeptic}\n\n### Pragmatist\n${pragmatist}\n\n### Critic\n${critic}`;

        send(controller, { type: "phase", phase: "architect" });
        const parts = [`Spec under review:\n\n${expanded}`];
        parts.push(`Council feedback so far:\n\n${priorBlock}`);
        if (councilNote)
          parts.push(`User guidance for this round:\n${councilNote}`);
        const architectContent = parts.join("\n\n---\n\n");

        const architect = await streamMessage(
          {
            model,
            max_tokens: MAX_TOKENS,
            system: COUNCIL_PROMPTS.architect,
            messages: [{ role: "user", content: architectContent }]
          },
          (delta) => {
            if (!aborted.v) send(controller, { type: "delta", text: delta });
          }
        );

        const output = [
          "## Skeptic",
          skeptic,
          "",
          "## Pragmatist",
          pragmatist,
          "",
          "## Critic",
          critic,
          "",
          "## Architect (synthesis)",
          architect
        ].join("\n");

        await updateStage(id, "council", {
          status: "done",
          endedAt: Date.now(),
          output,
          model
        });
        send(controller, { type: "done" });
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        await updateStage(id, "council", {
          status: "failed",
          endedAt: Date.now(),
          error: msg
        });
        send(controller, { type: "error", error: msg });
      } finally {
        try {
          controller.close();
        } catch {
          // already closed
        }
      }
    }
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive"
    }
  });
}
