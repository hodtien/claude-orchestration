import path from "node:path";
import { promises as fs } from "node:fs";
import { loadPipeline, updateStage, updatePipelineField } from "@/lib/pipeline";
import { spawnDetached } from "@/lib/spawn-bash";
import { TASKS_DIR, RESULTS_DIR } from "@/lib/paths";

export const dynamic = "force-dynamic";
export const revalidate = 0;

interface UnitFile {
  id: string;
  file: string;
}

interface UnitStatus {
  id: string;
  state: "pending" | "running" | "done" | "failed";
  duration_sec?: number;
  winner_agent?: string;
  error?: string;
}

async function listUnits(batchDir: string): Promise<UnitFile[]> {
  const entries = await fs.readdir(batchDir);
  return entries
    .filter((f) => f.endsWith(".md") && !f.startsWith("README"))
    .map((f) => ({ id: f.replace(/\.md$/, ""), file: f }))
    .sort((a, b) => a.id.localeCompare(b.id));
}

async function readUnitTaskId(filePath: string): Promise<string | null> {
  try {
    const text = await fs.readFile(filePath, "utf8");
    const m = text.match(/^id:\s*(\S+)/m);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

async function pollUnitStatus(taskId: string): Promise<UnitStatus | null> {
  const statusPath = path.join(RESULTS_DIR, `${taskId}.status.json`);
  try {
    const raw = await fs.readFile(statusPath, "utf8");
    const data = JSON.parse(raw) as Record<string, unknown>;
    const finalState =
      typeof data.final_state === "string" ? data.final_state : "running";
    const state: UnitStatus["state"] =
      finalState === "done"
        ? "done"
        : finalState === "failed" || finalState === "exhausted"
        ? "failed"
        : "running";
    return {
      id: taskId,
      state,
      duration_sec:
        typeof data.duration_sec === "number" ? data.duration_sec : undefined,
      winner_agent:
        typeof data.winner_agent === "string" ? data.winner_agent : undefined,
      error: typeof data.error === "string" ? data.error : undefined
    };
  } catch {
    const logPath = path.join(RESULTS_DIR, `${taskId}.log`);
    try {
      await fs.stat(logPath);
      return { id: taskId, state: "running" };
    } catch {
      return { id: taskId, state: "pending" };
    }
  }
}

export async function GET(
  req: Request,
  { params }: { params: { id: string } }
) {
  const id = params.id;
  const pipeline = await loadPipeline(id);
  if (!pipeline) {
    return new Response(JSON.stringify({ error: "not found" }), {
      status: 404,
      headers: { "Content-Type": "application/json" }
    });
  }
  if (!pipeline.batchId) {
    return new Response(
      JSON.stringify({ error: "no batchId; run decompose first" }),
      { status: 400, headers: { "Content-Type": "application/json" } }
    );
  }
  if (pipeline.stages.dispatch.status === "running") {
    return new Response(JSON.stringify({ error: "already running" }), {
      status: 409,
      headers: { "Content-Type": "application/json" }
    });
  }

  const batchId = pipeline.batchId;
  const batchDir = path.join(TASKS_DIR, batchId);

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
        await updateStage(id, "dispatch", {
          status: "running",
          startedAt: Date.now()
        });

        const units = await listUnits(batchDir);
        const taskIds: string[] = [];
        for (const u of units) {
          const tid = await readUnitTaskId(path.join(batchDir, u.file));
          if (tid) taskIds.push(tid);
        }
        send(controller, {
          type: "start",
          batchId,
          unitCount: units.length,
          taskIds
        });

        const { pid } = spawnDetached("bin/task-dispatch.sh", [
          batchDir,
          "--parallel"
        ]);
        await updatePipelineField(id, { dispatchPid: pid });
        send(controller, { type: "spawned", pid });

        const deadline = Date.now() + 30 * 60 * 1000;
        let lastSummary = "";
        while (!aborted.v && Date.now() < deadline) {
          const statuses: UnitStatus[] = [];
          for (const tid of taskIds) {
            const s = await pollUnitStatus(tid);
            if (s) statuses.push(s);
          }
          const counts = {
            pending: statuses.filter((s) => s.state === "pending").length,
            running: statuses.filter((s) => s.state === "running").length,
            done: statuses.filter((s) => s.state === "done").length,
            failed: statuses.filter((s) => s.state === "failed").length
          };
          const summary = JSON.stringify({ counts, statuses });
          if (summary !== lastSummary) {
            send(controller, { type: "progress", counts, statuses });
            lastSummary = summary;
          }
          const total = taskIds.length;
          if (total > 0 && counts.done + counts.failed === total) break;
          await new Promise((r) => setTimeout(r, 2000));
        }

        const finalStatuses: UnitStatus[] = [];
        for (const tid of taskIds) {
          const s = await pollUnitStatus(tid);
          if (s) finalStatuses.push(s);
        }
        const failedCount = finalStatuses.filter(
          (s) => s.state === "failed"
        ).length;
        const doneCount = finalStatuses.filter(
          (s) => s.state === "done"
        ).length;
        const summary = `Dispatch ${
          failedCount === 0 ? "complete" : "complete with failures"
        }: ${doneCount}/${taskIds.length} done, ${failedCount} failed.`;

        await updateStage(id, "dispatch", {
          status: failedCount === 0 ? "done" : "failed",
          endedAt: Date.now(),
          output: summary,
          ...(failedCount > 0
            ? {
                error: `${failedCount} task(s) failed: ${finalStatuses
                  .filter((s) => s.state === "failed")
                  .map((s) => s.id)
                  .join(", ")}`
              }
            : {})
        });
        send(controller, {
          type: "done",
          summary,
          statuses: finalStatuses
        });
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        await updateStage(id, "dispatch", {
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
