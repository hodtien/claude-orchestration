import { NextResponse } from "next/server";
import path from "node:path";
import { loadPipeline, updateStage, updatePipelineField } from "@/lib/pipeline";
import { spawnDetached } from "@/lib/spawn-bash";
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
  if (!pipeline.batchId) {
    return NextResponse.json(
      { success: false, error: "no batchId; run decompose first" },
      { status: 400 }
    );
  }

  if (pipeline.stages.dispatch.status === "running") {
    return NextResponse.json(
      { success: false, error: "dispatch is already running" },
      { status: 409 }
    );
  }

  await updateStage(id, "dispatch", {
    status: "running",
    startedAt: Date.now()
  });

  try {
    const batchDir = path.join(TASKS_DIR, pipeline.batchId);
    const { pid } = spawnDetached(
      "bin/task-dispatch.sh",
      [batchDir, "--parallel"]
    );

    await updatePipelineField(id, { dispatchPid: pid });
    const next = await updateStage(id, "dispatch", {
      status: "done",
      endedAt: Date.now(),
      output: `PID: ${pid} · Batch: ${pipeline.batchId}`
    });
    return NextResponse.json({ success: true, data: next });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    await updateStage(id, "dispatch", {
      status: "failed",
      endedAt: Date.now(),
      error: msg
    });
    return NextResponse.json({ success: false, error: msg }, { status: 500 });
  }
}
