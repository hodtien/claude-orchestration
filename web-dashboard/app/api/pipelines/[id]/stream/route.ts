import { loadPipeline, type Pipeline, STAGES } from "@/lib/pipeline";

export const dynamic = "force-dynamic";
export const revalidate = 0;

function isTerminal(p: Pipeline): boolean {
  if (p.stages.dispatch.status === "failed") return true;
  if (p.stages.review.status === "done" || p.stages.review.status === "failed")
    return true;
  return STAGES.filter((s) => s !== "review").every((s) => {
    const st = p.stages[s].status;
    return st === "done" || st === "failed";
  });
}

export async function GET(
  req: Request,
  { params }: { params: { id: string } }
) {
  const id = params.id;
  const initial = await loadPipeline(id);
  if (!initial) {
    return new Response(JSON.stringify({ success: false, error: "not found" }), {
      status: 404,
      headers: { "Content-Type": "application/json" }
    });
  }

  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    async start(controller) {
      let running = true;
      let interval: ReturnType<typeof setInterval> | null = null;

      const send = (data: string) => {
        try {
          controller.enqueue(encoder.encode(`data: ${data}\n\n`));
        } catch {
          running = false;
        }
      };

      const tick = async () => {
        try {
          const p = await loadPipeline(id);
          if (!p) {
            send(JSON.stringify({ error: "pipeline deleted" }));
            running = false;
            if (interval) clearInterval(interval);
            try {
              controller.close();
            } catch {
              // already closed
            }
            return;
          }
          send(JSON.stringify(p));
          if (isTerminal(p)) {
            running = false;
            if (interval) clearInterval(interval);
            try {
              controller.close();
            } catch {
              // already closed
            }
          }
        } catch (err: unknown) {
          send(
            JSON.stringify({
              error: err instanceof Error ? err.message : String(err)
            })
          );
        }
      };

      await tick();
      interval = setInterval(() => {
        if (!running) {
          if (interval) clearInterval(interval);
          return;
        }
        void tick();
      }, 1000);

      req.signal.addEventListener("abort", () => {
        running = false;
        if (interval) clearInterval(interval);
        try {
          controller.close();
        } catch {
          // already closed
        }
      });
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
