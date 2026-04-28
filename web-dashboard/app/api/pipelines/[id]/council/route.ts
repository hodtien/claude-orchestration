import { NextResponse } from "next/server";
import { loadPipeline, updateStage } from "@/lib/pipeline";
import {
  createMessageWithRetry,
  MAX_TOKENS,
  COUNCIL_PROMPTS,
  resolveModel
} from "@/lib/anthropic-client";

export const dynamic = "force-dynamic";
export const revalidate = 0;

async function callVoice(
  voice: keyof typeof COUNCIL_PROMPTS,
  expandedSpec: string,
  priorVoices?: string,
  userNote?: string
): Promise<string> {
  const parts = [`Spec under review:\n\n${expandedSpec}`];
  if (priorVoices) parts.push(`Council feedback so far:\n\n${priorVoices}`);
  if (userNote) parts.push(`User guidance for this round:\n${userNote}`);
  const userContent = parts.join("\n\n---\n\n");
  const resolved = await resolveModel(null);
  const msg = await createMessageWithRetry({
    model: resolved,
    max_tokens: MAX_TOKENS,
    system: COUNCIL_PROMPTS[voice],
    messages: [{ role: "user", content: userContent }]
  });
  return msg.content
    .flatMap((b) => (b.type === "text" ? [b.text] : []))
    .join("\n");
}

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
  const expanded = pipeline.stages.expand.output;
  if (!expanded) {
    return NextResponse.json(
      { success: false, error: "expand stage has no output; run expand first" },
      { status: 400 }
    );
  }

  if (pipeline.stages.council.status === "running") {
    return NextResponse.json(
      { success: false, error: "council is already running" },
      { status: 409 }
    );
  }

  await updateStage(id, "council", { status: "running", startedAt: Date.now() });

  try {
    const expandNote = pipeline.stages.expand.userNote?.trim() || undefined;
    const councilNote = pipeline.stages.council.userNote?.trim() || undefined;
    const [skeptic, pragmatist, critic] = await Promise.all([
      callVoice("skeptic", expanded, undefined, expandNote),
      callVoice("pragmatist", expanded, undefined, expandNote),
      callVoice("critic", expanded, undefined, expandNote)
    ]);
    const priorBlock = `### Skeptic\n${skeptic}\n\n### Pragmatist\n${pragmatist}\n\n### Critic\n${critic}`;
    const architect = await callVoice("architect", expanded, priorBlock, councilNote);

    const output = [
      "## Skeptic",
      skeptic,
      "",
      "## Pragmatist",
      pragmatist,
      "",
      "## Critic",
      critic,
      "",
      "## Architect (synthesis)",
      architect
    ].join("\n");

    const next = await updateStage(id, "council", {
      status: "done",
      endedAt: Date.now(),
      output
    });
    return NextResponse.json({ success: true, data: next });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    await updateStage(id, "council", {
      status: "failed",
      endedAt: Date.now(),
      error: msg
    });
    return NextResponse.json({ success: false, error: msg }, { status: 500 });
  }
}
