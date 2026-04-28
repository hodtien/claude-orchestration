import { NextResponse } from "next/server";
import { saveRoutingEntry } from "@/lib/config";
import { taskMappingEntrySchema } from "@/lib/config-schema";
import { assertSameOrigin } from "@/lib/csrf";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function PATCH(
  req: Request,
  { params }: { params: { taskType: string } }
) {
  const csrf = assertSameOrigin(req);
  if (csrf) return csrf;
  try {
    const body = await req.json();
    const entry = body.entry ?? body;
    const validated = taskMappingEntrySchema.parse(entry);
    await saveRoutingEntry(params.taskType, validated);
    return NextResponse.json({
      success: true,
      data: { taskType: params.taskType }
    });
  } catch (err: unknown) {
    if (err instanceof Error && err.name === "ZodError") {
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
