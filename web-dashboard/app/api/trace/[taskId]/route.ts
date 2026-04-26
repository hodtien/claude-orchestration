import { NextResponse } from "next/server";
import { getTaskTrace } from "@/lib/trace";
import { TASKS_FILE, RESULTS_DIR, REFLEXION_DIR } from "@/lib/paths";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function GET(
  _req: Request,
  { params }: { params: { taskId: string } }
) {
  const taskId = decodeURIComponent(params.taskId || "").trim();
  const result = await getTaskTrace(
    TASKS_FILE,
    RESULTS_DIR,
    REFLEXION_DIR,
    taskId
  );
  return NextResponse.json(result);
}
