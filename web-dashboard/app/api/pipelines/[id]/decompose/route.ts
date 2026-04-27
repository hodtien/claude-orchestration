import { NextResponse } from "next/server";
import path from "node:path";
import { promises as fs } from "node:fs";
import { loadPipeline, updateStage, updatePipelineField } from "@/lib/pipeline";
import { runBash } from "@/lib/spawn-bash";
import { TASKS_DIR } from "@/lib/paths";

export const dynamic = "force-dynamic";
export const revalidate = 0;

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

  const spec =
    pipeline.stages.council.output || pipeline.stages.expand.output;
  if (!spec) {
    return NextResponse.json(
      {
        success: false,
        error: "no expand or council output available to decompose"
      },
      { status: 400 }
    );
  }

  await updateStage(id, "decompose", {
    status: "running",
    startedAt: Date.now()
  });

  try {
    const batchId = `batch-${id}`;
    const batchDir = path.join(TASKS_DIR, batchId);
    await fs.mkdir(batchDir, { recursive: true });

    const specFile = path.join(batchDir, "spec.md");
    await fs.writeFile(specFile, spec, "utf8");

    const result = runBash(
      "lib/task-decomposer.sh",
      ["decompose_task", batchId, specFile, "medium", "dev"],
      { timeoutMs: 60_000 }
    );

    if (result.status !== 0) {
      throw new Error(
        `task-decomposer exited ${result.status}: ${result.stderr.slice(0, 500)}`
      );
    }

    await updatePipelineField(id, { batchId });
    const next = await updateStage(id, "decompose", {
      status: "done",
      endedAt: Date.now(),
      output: `Batch dir: ${batchDir}\n\n${result.stdout.slice(0, 2000)}`
    });
    return NextResponse.json({ success: true, data: next });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    await updateStage(id, "decompose", {
      status: "failed",
      endedAt: Date.now(),
      error: msg
    });
    return NextResponse.json({ success: false, error: msg }, { status: 500 });
  }
}
