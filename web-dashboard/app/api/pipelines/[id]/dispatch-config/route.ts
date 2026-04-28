import { NextResponse } from "next/server";
import { loadPipeline } from "@/lib/pipeline";
import { writeBatchOverride } from "@/lib/config";
import { assertSameOrigin } from "@/lib/csrf";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function POST(
  req: Request,
  { params }: { params: { id: string } }
) {
  const csrf = assertSameOrigin(req);
  if (csrf) return csrf;
  try {
    const pipeline = await loadPipeline(params.id);
    if (!pipeline) {
      return NextResponse.json(
        { success: false, error: "pipeline not found" },
        { status: 404 }
      );
    }

    if (pipeline.stages.dispatch.status !== "pending") {
      return NextResponse.json(
        {
          success: false,
          error: `dispatch is "${pipeline.stages.dispatch.status}"; override only allowed when pending`
        },
        { status: 409 }
      );
    }

    if (!pipeline.batchId) {
      return NextResponse.json(
        { success: false, error: "no batchId; run decompose first" },
        { status: 400 }
      );
    }

    const body = await req.json();
    const file = await writeBatchOverride(pipeline.batchId, body);
    return NextResponse.json({ success: true, data: { file } });
  } catch (err: unknown) {
    if (err instanceof RangeError) {
      return NextResponse.json(
        { success: false, error: err.message },
        { status: 400 }
      );
    }
    return NextResponse.json(
      { success: false, error: err instanceof Error ? err.message : String(err) },
      { status: 500 }
    );
  }
}
