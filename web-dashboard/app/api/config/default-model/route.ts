import { NextResponse } from "next/server";
import { setDefaultModel } from "@/lib/config";
import { assertSameOrigin } from "@/lib/csrf";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function PUT(req: Request) {
  const csrf = assertSameOrigin(req);
  if (csrf) return csrf;
  try {
    const body = await req.json();
    const model = body.model ?? body.id;
    if (!model || typeof model !== "string") {
      return NextResponse.json(
        { success: false, error: "model is required" },
        { status: 400 }
      );
    }
    await setDefaultModel(model);
    return NextResponse.json({ success: true, data: { model } });
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
