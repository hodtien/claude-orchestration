import { NextResponse } from "next/server";
import { saveAgent, deleteAgent } from "@/lib/config";
import { agentEntrySchema } from "@/lib/config-schema";
import { assertSameOrigin } from "@/lib/csrf";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function PATCH(
  req: Request,
  { params }: { params: { id: string } }
) {
  const csrf = assertSameOrigin(req);
  if (csrf) return csrf;
  try {
    const body = await req.json();
    const entry = body.entry ?? body;
    const validated = agentEntrySchema.parse(entry);
    await saveAgent(params.id, validated);
    return NextResponse.json({ success: true, data: { id: params.id } });
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

export async function DELETE(
  req: Request,
  { params }: { params: { id: string } }
) {
  const csrf = assertSameOrigin(req);
  if (csrf) return csrf;
  try {
    await deleteAgent(params.id);
    return NextResponse.json({ success: true });
  } catch (err: unknown) {
    if (err instanceof RangeError) {
      return NextResponse.json(
        { success: false, error: err.message },
        { status: 404 }
      );
    }
    return NextResponse.json(
      { success: false, error: err instanceof Error ? err.message : String(err) },
      { status: 500 }
    );
  }
}
