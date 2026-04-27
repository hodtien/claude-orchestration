import { NextRequest, NextResponse } from "next/server";
import { COST_LOG } from "@/lib/paths";
import { loadCostTrend } from "@/lib/cost-trend";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function GET(req: NextRequest) {
  const sp = req.nextUrl.searchParams;
  const window = sp.get("window") ?? "24h";
  const rawBucket = sp.get("bucket") ?? "1h";
  const bucket = rawBucket === "1d" ? "1d" : "1h";

  const result = await loadCostTrend(COST_LOG, { window, bucket });
  return NextResponse.json(result);
}
