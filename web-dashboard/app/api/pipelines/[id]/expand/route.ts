import { NextResponse } from "next/server";
import { loadPipeline, updateStage } from "@/lib/pipeline";
import {
  createMessageWithRetry,
  MAX_TOKENS,
  EXPAND_SYSTEM,
  resolveModel
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

  if (pipeline.stages.expand.status === "running") {
    return NextResponse.json(
      { success: false, error: "expand is already running" },
      { status: 409 }
    );
  }

  await updateStage(id, "expand", { status: "running", startedAt: Date.now() });

  try {
    const ideaNote = pipeline.stages.idea.userNote?.trim();
    const userContent = ideaNote
      ? `${pipeline.rawIdea}\n\n---\n\nUser clarification / refinement:\n${ideaNote}`
      : pipeline.rawIdea;
    const model = await resolveModel(null);
    const msg = await createMessageWithRetry({
      model,
      max_tokens: MAX_TOKENS,
      system: EXPAND_SYSTEM,
      messages: [{ role: "user", content: userContent }]
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
