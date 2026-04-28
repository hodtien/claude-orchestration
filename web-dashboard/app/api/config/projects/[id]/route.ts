import { NextResponse } from "next/server";
import { updateProject, deleteProject } from "@/lib/projects-config";
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
    const patch: { name?: string; path?: string } = {};
    if (typeof body.name === "string") patch.name = body.name;
    if (typeof body.path === "string") patch.path = body.path;
    if (Object.keys(patch).length === 0) {
      return NextResponse.json(
        { success: false, error: "provide name and/or path to update" },
        { status: 400 }
      );
    }
    const entry = await updateProject(params.id, patch);
    return NextResponse.json({ success: true, data: entry });
  } catch (err: unknown) {
    if (err instanceof Error && err.name === "ZodError") {
      return NextResponse.json(
        { success: false, error: err.message },
        { status: 400 }
      );
    }
    const msg = err instanceof Error ? err.message : String(err);
    const status = msg.includes("not found") ? 404 : msg.includes("already") ? 409 : 500;
    return NextResponse.json({ success: false, error: msg }, { status });
  }
}

export async function DELETE(
  req: Request,
  { params }: { params: { id: string } }
) {
  const csrf = assertSameOrigin(req);
  if (csrf) return csrf;
  try {
    await deleteProject(params.id);
    return NextResponse.json({ success: true });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    const status = msg.includes("not found") ? 404 : 500;
    return NextResponse.json({ success: false, error: msg }, { status });
  }
}
