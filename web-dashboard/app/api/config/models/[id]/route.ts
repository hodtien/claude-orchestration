import { NextResponse } from "next/server";
import { saveModel, deleteModel, findModelReferences } from "@/lib/config";
import { modelEntrySchema } from "@/lib/config-schema";
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
    const validated = modelEntrySchema.parse(entry);
    await saveModel(params.id, validated);
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
    await deleteModel(params.id);
    return NextResponse.json({ success: true });
  } catch (err: unknown) {
    if (err instanceof ReferenceError) {
      const refs = await findModelReferences(params.id);
      return NextResponse.json(
        { success: false, error: err.message, references: refs },
        { status: 409 }
      );
    }
    return NextResponse.json(
      { success: false, error: err instanceof Error ? err.message : String(err) },
      { status: 500 }
    );
  }
}
