import { NextResponse } from "next/server";
import { readJsonlTail } from "@/lib/jsonl";
import { TASKS_FILE } from "@/lib/paths";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type TaskEvent = {
  ts?: string;
  timestamp?: string;
  event?: string;
  task_id?: string;
  trace_id?: string;
  parent_task_id?: string;
  batch_id?: string;
  agent?: string;
  project?: string;
  status?: string;
  duration_s?: number;
  prompt_chars?: number;
  output_chars?: number;
  outcome?: string;
  error?: string;
};

export async function GET() {
  const events = await readJsonlTail<TaskEvent>(TASKS_FILE, 500);

  // Dedupe by task_id, keeping the latest event by ts
  const latest = new Map<string, TaskEvent>();
  for (const ev of events) {
    const tid = ev.task_id;
    if (!tid) continue;
    const prev = latest.get(tid);
    const ts = ev.ts || ev.timestamp || "";
    const prevTs = prev ? prev.ts || prev.timestamp || "" : "";
    if (!prev || ts >= prevTs) {
      latest.set(tid, ev);
    }
  }

  const tasks = Array.from(latest.values()).sort((a, b) => {
    const ta = a.ts || a.timestamp || "";
    const tb = b.ts || b.timestamp || "";
    return tb.localeCompare(ta);
  });

  return NextResponse.json({
    source: TASKS_FILE,
    count: tasks.length,
    tasks: tasks.slice(0, 100)
  });
}
