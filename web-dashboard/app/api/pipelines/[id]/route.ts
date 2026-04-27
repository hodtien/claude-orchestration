import { NextResponse } from "next/server";
import { loadPipeline } from "@/lib/pipeline";

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
