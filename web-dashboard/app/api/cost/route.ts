import { NextResponse } from "next/server";
import { readJsonlTail } from "@/lib/jsonl";
import { COST_LOG } from "@/lib/paths";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type CostEntry = {
  timestamp: string;
  agent: string;
  batch_id?: string;
  task_id?: string;
  tokens_input: number;
  tokens_output: number;
  cost_usd: number;
  duration_s?: number;
};

type AgentRollup = {
  agent: string;
  calls: number;
  tokens_in: number;
  tokens_out: number;
  cost_usd: number;
};

export async function GET() {
  const entries = await readJsonlTail<CostEntry>(COST_LOG, 1000);

  const byAgent = new Map<string, AgentRollup>();
  let totalCalls = 0;
  let totalIn = 0;
  let totalOut = 0;
  let totalCost = 0;

  for (const e of entries) {
    if (!e.agent) continue;
    totalCalls += 1;
    totalIn += Number(e.tokens_input) || 0;
    totalOut += Number(e.tokens_output) || 0;
    totalCost += Number(e.cost_usd) || 0;

    const cur = byAgent.get(e.agent) || {
      agent: e.agent,
      calls: 0,
      tokens_in: 0,
      tokens_out: 0,
      cost_usd: 0
    };
    cur.calls += 1;
    cur.tokens_in += Number(e.tokens_input) || 0;
    cur.tokens_out += Number(e.tokens_output) || 0;
    cur.cost_usd += Number(e.cost_usd) || 0;
    byAgent.set(e.agent, cur);
  }

  const per_agent = Array.from(byAgent.values()).sort(
    (a, b) => b.cost_usd - a.cost_usd
  );

  return NextResponse.json({
    source: COST_LOG,
    totals: {
      calls: totalCalls,
      tokens_in: totalIn,
      tokens_out: totalOut,
      cost_usd: totalCost
    },
    per_agent
  });
}
