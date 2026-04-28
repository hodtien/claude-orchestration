import { NextResponse } from "next/server";
import { loadAgents, saveAgent } from "@/lib/config";
import { agentEntrySchema } from "@/lib/config-schema";
import { assertSameOrigin } from "@/lib/csrf";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function GET() {
  try {
    const data = await loadAgents();
    return NextResponse.json({ success: true, data });
  } catch (err: unknown) {
    return NextResponse.json(
      { success: false, error: err instanceof Error ? err.message : String(err) },
      { status: 500 }
    );
  }
}

export async function POST(req: Request) {
  const csrf = assertSameOrigin(req);
  if (csrf) return csrf;
  try {
    const body = await req.json();
    const id = body.id;
    if (!id || typeof id !== "string") {
      return NextResponse.json(
        { success: false, error: "id is required" },
        { status: 400 }
      );
    }
    if (!body.entry || typeof body.entry !== "object") {
      return NextResponse.json(
        { success: false, error: "entry is required" },
        { status: 400 }
      );
    }
    const validated = agentEntrySchema.parse(body.entry);
    await saveAgent(id, validated);
    return NextResponse.json({ success: true, data: { id } }, { status: 201 });
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
