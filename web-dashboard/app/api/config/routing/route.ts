import { NextResponse } from "next/server";
import { loadRouting, saveRoutingEntry } from "@/lib/config";
import { taskMappingEntrySchema } from "@/lib/config-schema";
import { assertSameOrigin } from "@/lib/csrf";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function GET() {
  try {
    const data = await loadRouting();
    return NextResponse.json({ success: true, data });
  } catch (err: unknown) {
    return NextResponse.json(
      { success: false, error: err instanceof Error ? err.message : String(err) },
      { status: 500 }
    );
  }
}

export async function PUT(req: Request) {
  const csrf = assertSameOrigin(req);
  if (csrf) return csrf;
  try {
    const body = await req.json();
    const entries = body.task_mapping;
    if (!entries || typeof entries !== "object") {
      return NextResponse.json(
        { success: false, error: "task_mapping object is required" },
        { status: 400 }
      );
    }
    for (const [taskType, entry] of Object.entries(entries)) {
      const validated = taskMappingEntrySchema.parse(entry);
      await saveRoutingEntry(taskType, validated);
    }
    return NextResponse.json({ success: true });
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
