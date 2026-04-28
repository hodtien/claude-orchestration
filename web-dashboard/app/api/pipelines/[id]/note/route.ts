import { NextResponse } from "next/server";
import { z } from "zod";
import { loadPipeline, updateStage, STAGES } from "@/lib/pipeline";

export const dynamic = "force-dynamic";
export const revalidate = 0;

const bodySchema = z.object({
  stage: z.enum(STAGES),
  note: z.string().max(4000)
});

export async function PATCH(
  req: Request,
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

  let parsed;
  try {
    parsed = bodySchema.parse(await req.json());
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : "invalid body";
    return NextResponse.json(
      { success: false, error: msg },
      { status: 400 }
    );
  }

  const next = await updateStage(id, parsed.stage, {
    userNote: parsed.note.trim() || undefined
  });
  return NextResponse.json({ success: true, data: next });
}
