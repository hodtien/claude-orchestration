import { NextResponse } from "next/server";
import { loadPipeline, updateStage } from "@/lib/pipeline";
import {
  getClient,
  DEFAULT_MODEL,
  MAX_TOKENS,
  EXPAND_SYSTEM
} from "@/lib/anthropic-client";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function POST(
  _req: Request,
  { params }: { params: { id: string } }
) {
  const id = params.id;
  const pipeline = await loadPipeline(id);
  if (!pipeline) {
    return NextResponse.json(
      { success: false, error: "not found" },
      { status: 404 }
    );
  }

  await updateStage(id, "expand", { status: "running", startedAt: Date.now() });

  try {
    const client = getClient();
    const msg = await client.messages.create({
      model: DEFAULT_MODEL,
      max_tokens: MAX_TOKENS,
      system: EXPAND_SYSTEM,
      messages: [{ role: "user", content: pipeline.rawIdea }]
    });
    const text = msg.content
      .flatMap((b) => (b.type === "text" ? [b.text] : []))
      .join("\n");

    const next = await updateStage(id, "expand", {
      status: "done",
      endedAt: Date.now(),
      output: text
    });
    return NextResponse.json({ success: true, data: next });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    await updateStage(id, "expand", {
      status: "failed",
      endedAt: Date.now(),
      error: msg
    });
    return NextResponse.json({ success: false, error: msg }, { status: 500 });
  }
}
