import { NextResponse } from "next/server";
import { TASKS_DIR, RESULTS_DIR, TASKS_FILE } from "@/lib/paths";
import { getBatchDag } from "@/lib/batch";

export const dynamic = "force-dynamic";

const SAFE_BATCH_ID = /^[A-Za-z0-9._-]+$/;

export async function GET(
  _req: Request,
  { params }: { params: { batchId: string } }
): Promise<NextResponse> {
  const batchId = params.batchId;
  if (!batchId || !SAFE_BATCH_ID.test(batchId)) {
    return NextResponse.json(
      { error: "invalid_batch_id" },
      { status: 400 }
    );
  }

  const dag = await getBatchDag(
    TASKS_DIR,
    RESULTS_DIR,
    TASKS_FILE,
    batchId
  );

  if (!dag) {
    return NextResponse.json(
      { error: "batch_not_found" },
      { status: 404 }
    );
  }

  return NextResponse.json(dag);
}
