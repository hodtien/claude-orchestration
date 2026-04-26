import { NextResponse } from "next/server";
import { RESULTS_DIR, TASKS_FILE } from "@/lib/paths";
import { loadRecentFailures, computeSloSummary } from "@/lib/failures";

export const dynamic = "force-dynamic";

const SAFE_SINCE = /^\d+[hd]$/;

export async function GET(req: Request) {
  const url = new URL(req.url);
  const limitRaw = url.searchParams.get("limit");
  const sinceRaw = url.searchParams.get("since") ?? undefined;

  let limit = 10;
  if (limitRaw !== null) {
    if (!/^\d+$/.test(limitRaw)) {
      return NextResponse.json({ error: "invalid_limit" }, { status: 400 });
    }
    const n = parseInt(limitRaw, 10);
    if (n > 0 && n <= 200) limit = n;
  }

  let since: string | undefined;
  if (sinceRaw) {
    if (!SAFE_SINCE.test(sinceRaw)) {
      return NextResponse.json({ error: "invalid_since" }, { status: 400 });
    }
    since = sinceRaw;
  }

  try {
    const [failures, slo] = await Promise.all([
      loadRecentFailures(RESULTS_DIR, TASKS_FILE, { limit, since }),
      computeSloSummary(RESULTS_DIR),
    ]);
    return NextResponse.json({ ...failures, slo });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : "internal error";
    return NextResponse.json({ error: msg }, { status: 500 });
  }
}
