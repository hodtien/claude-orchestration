import { NextResponse } from "next/server";
import { listProjects, createProject } from "@/lib/projects-config";
import { assertSameOrigin } from "@/lib/csrf";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function GET() {
  try {
    const data = await listProjects();
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
    const name = body.name;
    const projPath = body.path;
    if (!name || typeof name !== "string") {
      return NextResponse.json(
        { success: false, error: "name is required" },
        { status: 400 }
      );
    }
    if (!projPath || typeof projPath !== "string") {
      return NextResponse.json(
        { success: false, error: "path is required" },
        { status: 400 }
      );
    }
    const entry = await createProject({ name, path: projPath });
    return NextResponse.json({ success: true, data: entry }, { status: 201 });
  } catch (err: unknown) {
    if (err instanceof Error && err.name === "ZodError") {
      return NextResponse.json(
        { success: false, error: err.message },
        { status: 400 }
      );
    }
    const msg = err instanceof Error ? err.message : String(err);
    const status = msg.includes("already") ? 409 : 500;
    return NextResponse.json({ success: false, error: msg }, { status });
  }
}
