import { NextResponse } from "next/server";
import { TASKS_DIR, RESULTS_DIR } from "@/lib/paths";
import { listBatches } from "@/lib/batch";

export const dynamic = "force-dynamic";

export async function GET(): Promise<NextResponse> {
  const batches = await listBatches(TASKS_DIR, RESULTS_DIR, 20);
  return NextResponse.json({ batches });
}
