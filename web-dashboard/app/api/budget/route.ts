import { NextResponse } from "next/server";
import path from "node:path";
import { COST_LOG, PROJECT_ROOT } from "@/lib/paths";
import { loadBudgetState } from "@/lib/cost-trend";

export const dynamic = "force-dynamic";
export const revalidate = 0;

const BUDGET_PATH = path.join(PROJECT_ROOT, "config", "budget.yaml");

export async function GET() {
  const state = await loadBudgetState(COST_LOG, BUDGET_PATH);
  return NextResponse.json(state);
}
