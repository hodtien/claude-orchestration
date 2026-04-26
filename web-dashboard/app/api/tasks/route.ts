import { NextResponse } from "next/server";
import { readJsonlTail } from "@/lib/jsonl";
import { TASKS_FILE } from "@/lib/paths";
import { eventTimeMs, type TaskEvent } from "@/lib/types";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function GET() {
  const events = await readJsonlTail<TaskEvent>(TASKS_FILE, 500);

  const latest = new Map<string, TaskEvent>();
  for (const ev of events) {
    const tid = ev.task_id;
    if (!tid) continue;
    const prev = latest.get(tid);
    if (!prev || eventTimeMs(ev) >= eventTimeMs(prev)) {
      latest.set(tid, ev);
    }
  }

  const tasks = Array.from(latest.values()).sort(
    (a, b) => eventTimeMs(b) - eventTimeMs(a)
  );

  return NextResponse.json({
    source: TASKS_FILE,
    count: tasks.length,
    tasks: tasks.slice(0, 100)
  });
}
