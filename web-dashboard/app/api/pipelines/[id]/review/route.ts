import { NextResponse } from "next/server";
import { promises as fs } from "node:fs";
import path from "node:path";
import { loadPipeline, updateStage } from "@/lib/pipeline";
import { RESULTS_DIR, TASKS_DIR } from "@/lib/paths";

export const dynamic = "force-dynamic";
export const revalidate = 0;

interface TaskResult {
  taskId: string;
  finalState: string;
  winnerAgent?: string;
  durationSec?: number;
  output?: string;
}

async function readJson(fp: string): Promise<Record<string, unknown> | null> {
  try {
    const raw = await fs.readFile(fp, "utf8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function readText(fp: string): Promise<string | null> {
  try {
    return await fs.readFile(fp, "utf8");
  } catch {
    return null;
  }
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

async function collectBatchResults(batchId: string): Promise<TaskResult[]> {
  const batchDir = path.join(TASKS_DIR, batchId);
  let entries: string[];
  try {
    entries = await fs.readdir(batchDir);
  } catch {
    return [];
  }

  const unitFiles = entries.filter(
    (f) => f.endsWith(".md") && !f.startsWith("README")
  );
  const taskIds: string[] = [];
  for (const f of unitFiles) {
    if (f.startsWith("task-")) {
      taskIds.push(f.replace(/\.md$/, ""));
    } else {
      const tid = await readUnitTaskId(path.join(batchDir, f));
      if (tid) taskIds.push(tid);
    }
  }

  const results: TaskResult[] = [];
  for (const tid of taskIds) {
    const statusFile = path.join(RESULTS_DIR, `${tid}.status.json`);
    const statusJson = await readJson(statusFile);

    const result: TaskResult = {
      taskId: tid,
      finalState: "unknown"
    };

    if (statusJson) {
      result.finalState = String(statusJson.final_state ?? "unknown");
      if (statusJson.winner_agent)
        result.winnerAgent = String(statusJson.winner_agent);
      if (typeof statusJson.duration_sec === "number")
        result.durationSec = statusJson.duration_sec;
    }

    const outFile = path.join(RESULTS_DIR, `${tid}.out`);
    const output = await readText(outFile);
    if (output) {
      result.output =
        output.length > 4000
          ? output.slice(0, 4000) + "\n…(truncated)"
          : output;
    }

    results.push(result);
  }
  return results;
}

export async function POST(
  _req: Request,
  { params }: { params: { id: string } }
) {
  const id = params.id;
  const pipeline = await loadPipeline(id);
  if (!pipeline) {
    return NextResponse.json(
      { success: false, error: "not found" },
      { status: 404 }
    );
  }
  if (!pipeline.batchId) {
    return NextResponse.json(
      { success: false, error: "no batchId; run decompose and dispatch first" },
      { status: 400 }
    );
  }

  if (pipeline.stages.review.status === "running") {
    return NextResponse.json(
      { success: false, error: "review is already running" },
      { status: 409 }
    );
  }

  await updateStage(id, "review", {
    status: "running",
    startedAt: Date.now()
  });

  try {
    let results = await collectBatchResults(pipeline.batchId);
    const deadline = Date.now() + 5 * 60 * 1000;
    while (
      results.length > 0 &&
      results.some(
        (r) => r.finalState !== "done" && r.finalState !== "failed" && r.finalState !== "exhausted"
      ) &&
      Date.now() < deadline
    ) {
      await new Promise((r) => setTimeout(r, 2000));
      results = await collectBatchResults(pipeline.batchId);
    }

    if (results.length === 0) {
      const next = await updateStage(id, "review", {
        status: "done",
        endedAt: Date.now(),
        output:
          "No task results found yet. Dispatch may still be running — click Run again later to check."
      });
      return NextResponse.json({ success: true, data: next });
    }

    const done = results.filter((r) => r.finalState === "done");
    const failed = results.filter((r) => r.finalState !== "done");
    const lines: string[] = [
      "## Review Summary",
      `**${done.length}/${results.length}** tasks completed.`,
      ""
    ];

    for (const r of results) {
      const icon = r.finalState === "done" ? "[PASS]" : "[FAIL]";
      const agent = r.winnerAgent ? ` (${r.winnerAgent})` : "";
      const dur =
        r.durationSec != null ? ` ${r.durationSec.toFixed(1)}s` : "";
      lines.push(`### ${icon} ${r.taskId}${agent}${dur}`);
      if (r.output) {
        const preview =
          r.output.length > 500 ? r.output.slice(0, 500) + "…" : r.output;
        lines.push("```", preview, "```");
      }
      lines.push("");
    }

    if (failed.length > 0) {
      lines.push(
        `**${failed.length} task(s) failed or still in progress.**`
      );
    }

    const output = lines.join("\n");
    const next = await updateStage(id, "review", {
      status: "done",
      endedAt: Date.now(),
      output
    });
    return NextResponse.json({ success: true, data: next });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    await updateStage(id, "review", {
      status: "failed",
      endedAt: Date.now(),
      error: msg
    });
    return NextResponse.json({ success: false, error: msg }, { status: 500 });
  }
}
