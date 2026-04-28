import { NextResponse } from "next/server";
import path from "node:path";
import { promises as fs } from "node:fs";
import { loadPipeline, updateStage, updatePipelineField } from "@/lib/pipeline";
import { TASKS_DIR } from "@/lib/paths";
import {
  createMessageWithRetry,
  DECOMPOSE_SYSTEM,
  MAX_TOKENS,
  resolveModel
} from "@/lib/anthropic-client";

export const dynamic = "force-dynamic";
export const revalidate = 0;

interface DecomposedUnit {
  id: string;
  title: string;
  body: string;
}

const TASK_FRONTMATTER = (taskId: string, title: string) => `---
id: ${taskId}
title: ${title.replace(/\n/g, " ").slice(0, 200)}
agent: dev
agents: copilot gemini
priority: medium
timeout: 600
---

`;

function extractJsonArray(text: string): unknown {
  const trimmed = text.trim();
  if (trimmed.startsWith("[")) {
    return JSON.parse(trimmed);
  }
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced) return JSON.parse(fenced[1]);
  const start = trimmed.indexOf("[");
  const end = trimmed.lastIndexOf("]");
  if (start !== -1 && end !== -1 && end > start) {
    return JSON.parse(trimmed.slice(start, end + 1));
  }
  throw new Error("decomposer did not return a JSON array");
}

function validateUnits(raw: unknown): DecomposedUnit[] {
  if (!Array.isArray(raw)) throw new Error("decomposer output is not an array");
  if (raw.length === 0) throw new Error("decomposer returned no units");
  if (raw.length > 12) throw new Error("decomposer returned too many units");
  return raw.map((u, i) => {
    if (!u || typeof u !== "object")
      throw new Error(`unit ${i} is not an object`);
    const obj = u as Record<string, unknown>;
    const idRaw = typeof obj.id === "string" ? obj.id : `unit-${String(i + 1).padStart(2, "0")}`;
    const id = idRaw.replace(/[^a-z0-9-]/gi, "-").toLowerCase() || `unit-${i + 1}`;
    const title = typeof obj.title === "string" ? obj.title : `Unit ${i + 1}`;
    const body = typeof obj.body === "string" ? obj.body : "";
    if (!body.trim()) throw new Error(`unit ${i} has empty body`);
    return { id, title, body };
  });
}

export async function POST(
  req: Request,
  { params }: { params: { id: string } }
) {
  const id = params.id;
  const url = new URL(req.url);
  const model = await resolveModel(url.searchParams.get("model"));
  const pipeline = await loadPipeline(id);
  if (!pipeline) {
    return NextResponse.json(
      { success: false, error: "not found" },
      { status: 404 }
    );
  }

  const spec =
    pipeline.stages.council.output || pipeline.stages.expand.output;
  if (!spec) {
    return NextResponse.json(
      {
        success: false,
        error: "no expand or council output available to decompose"
      },
      { status: 400 }
    );
  }

  if (pipeline.stages.decompose.status === "running") {
    return NextResponse.json(
      { success: false, error: "decompose is already running" },
      { status: 409 }
    );
  }

  await updateStage(id, "decompose", {
    status: "running",
    startedAt: Date.now(),
    model
  });

  try {
    const msg = await createMessageWithRetry({
      model,
      max_tokens: MAX_TOKENS,
      system: DECOMPOSE_SYSTEM,
      messages: [{ role: "user", content: `Specification:\n\n${spec}` }]
    });
    const text = msg.content
      .flatMap((b) => (b.type === "text" ? [b.text] : []))
      .join("\n");
    const units = validateUnits(extractJsonArray(text));

    const batchId = `batch-${id}`;
    const batchDir = path.join(TASKS_DIR, batchId);
    await fs.mkdir(batchDir, { recursive: true });

    const written: string[] = [];
    for (let i = 0; i < units.length; i++) {
      const u = units[i];
      const baseId = u.id.startsWith("unit-")
        ? u.id
        : `unit-${String(i + 1).padStart(2, "0")}`;
      const taskId = `task-${id.replace(/^pipe-/, "")}-${baseId}`;
      const file = path.join(batchDir, `${baseId}.md`);
      const body = `${TASK_FRONTMATTER(taskId, u.title)}# ${u.title}\n\n${u.body.trim()}\n`;
      await fs.writeFile(file, body, "utf8");
      written.push(file);
    }

    const batchConf = path.join(batchDir, "batch.conf");
    await fs.writeFile(
      batchConf,
      "auto_decompose: false\nfailure_mode: continue\n",
      "utf8"
    );

    await updatePipelineField(id, { batchId });
    const summary =
      `Decomposed into ${units.length} unit(s) in ${batchDir}\n\n` +
      units
        .map(
          (u, i) =>
            `${String(i + 1).padStart(2, "0")}. ${u.title}\n   → ${written[i]}`
        )
        .join("\n");
    const next = await updateStage(id, "decompose", {
      status: "done",
      endedAt: Date.now(),
      output: summary,
      model
    });
    return NextResponse.json({ success: true, data: next });
  } catch (err: unknown) {
    const errMsg = err instanceof Error ? err.message : String(err);
    await updateStage(id, "decompose", {
      status: "failed",
      endedAt: Date.now(),
      error: errMsg
    });
    return NextResponse.json({ success: false, error: errMsg }, { status: 500 });
  }
}
