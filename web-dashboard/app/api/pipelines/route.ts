import { NextResponse } from "next/server";
import { z } from "zod";
import { createPipeline, listPipelines } from "@/lib/pipeline";

export const dynamic = "force-dynamic";
export const revalidate = 0;

const createBody = z.object({
  rawIdea: z.string().min(1).max(8000)
});

export async function POST(req: Request) {
  let parsed;
  try {
    const json = await req.json();
    parsed = createBody.parse(json);
  } catch (err: unknown) {
    return NextResponse.json(
      { success: false, error: err instanceof Error ? err.message : "invalid body" },
      { status: 400 }
    );
  }
  try {
    const pipeline = await createPipeline(parsed.rawIdea);
    return NextResponse.json({ success: true, data: pipeline });
  } catch (err: unknown) {
    return NextResponse.json(
      { success: false, error: err instanceof Error ? err.message : String(err) },
      { status: 500 }
    );
  }
}

export async function GET() {
  try {
    const pipelines = await listPipelines(20);
    return NextResponse.json({ success: true, data: pipelines });
  } catch (err: unknown) {
    return NextResponse.json(
      { success: false, error: err instanceof Error ? err.message : String(err) },
      { status: 500 }
    );
  }
}
