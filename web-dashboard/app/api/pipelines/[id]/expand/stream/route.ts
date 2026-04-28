import { loadPipeline, updateStage } from "@/lib/pipeline";
import {
  streamMessage,
  MAX_TOKENS,
  EXPAND_SYSTEM,
  resolveModel
} from "@/lib/anthropic-client";
import {
  getRepoContext,
  buildExpandSystemWithContext
} from "@/lib/repo-context";

export const dynamic = "force-dynamic";
export const revalidate = 0;

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
  if (pipeline.stages.expand.status === "running") {
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
        await updateStage(id, "expand", {
          status: "running",
          startedAt: Date.now(),
          model
        });
        send(controller, { type: "start", model });

        const ideaNote = pipeline.stages.idea.userNote?.trim();
        const expandNote = pipeline.stages.expand.userNote?.trim();
        const notes: string[] = [];
        if (ideaNote) notes.push(`Idea-stage clarification:\n${ideaNote}`);
        if (expandNote) notes.push(`Expand-stage refinement (additional requirements):\n${expandNote}`);
        const userContent = notes.length
          ? `${pipeline.rawIdea}\n\n---\n\n${notes.join("\n\n---\n\n")}`
          : pipeline.rawIdea;

        const repoContext = await getRepoContext();
        const systemWithCtx = buildExpandSystemWithContext(
          EXPAND_SYSTEM,
          repoContext
        );

        const text = await streamMessage(
          {
            model,
            max_tokens: MAX_TOKENS,
            system: systemWithCtx,
            messages: [{ role: "user", content: userContent }]
          },
          (delta) => {
            if (!aborted.v) send(controller, { type: "delta", text: delta });
          }
        );

        await updateStage(id, "expand", {
          status: "done",
          endedAt: Date.now(),
          output: text,
          model
        });
        send(controller, { type: "done" });
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        await updateStage(id, "expand", {
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
