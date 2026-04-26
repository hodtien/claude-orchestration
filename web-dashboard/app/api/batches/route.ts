import { NextResponse } from "next/server";
import { TASKS_DIR } from "@/lib/paths";
import { listBatches } from "@/lib/batch";

export const dynamic = "force-dynamic";

export async function GET(): Promise<NextResponse> {
  const batches = await listBatches(TASKS_DIR);
  return NextResponse.json({ batches: batches.slice(0, 20) });
}
