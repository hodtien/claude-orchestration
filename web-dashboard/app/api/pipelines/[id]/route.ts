import { NextResponse } from "next/server";
import { z } from "zod";
import { loadPipeline, updatePipelineField } from "@/lib/pipeline";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function GET(
  _req: Request,
  { params }: { params: { id: string } }
) {
  try {
    const pipeline = await loadPipeline(params.id);
    if (!pipeline) {
      return NextResponse.json(
        { success: false, error: "not found" },
        { status: 404 }
      );
    }
    return NextResponse.json({ success: true, data: pipeline });
  } catch (err: unknown) {
    return NextResponse.json(
      { success: false, error: err instanceof Error ? err.message : String(err) },
      { status: 500 }
    );
  }
}

const patchBody = z.object({
  project: z.union([z.string().trim().min(1).max(80), z.null()]).optional()
});

export async function PATCH(
  req: Request,
  { params }: { params: { id: string } }
) {
  let parsed;
  try {
    const json = await req.json();
    parsed = patchBody.parse(json);
  } catch (err: unknown) {
    return NextResponse.json(
      { success: false, error: err instanceof Error ? err.message : "invalid body" },
      { status: 400 }
    );
  }
  try {
    const patch: { project?: string } = {};
    if (parsed.project === null) {
      patch.project = undefined;
    } else if (typeof parsed.project === "string") {
      patch.project = parsed.project;
    }
    const pipeline = await updatePipelineField(params.id, patch);
    return NextResponse.json({ success: true, data: pipeline });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    const status = msg.startsWith("pipeline not found") ? 404 : 500;
    return NextResponse.json({ success: false, error: msg }, { status });
  }
}
