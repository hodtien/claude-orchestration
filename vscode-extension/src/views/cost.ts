import * as vscode from "vscode";
import { runDashboard, getRefreshInterval } from "../cli";

export class CostViewProvider implements vscode.WebviewViewProvider {
  private view?: vscode.WebviewView;
  private timer?: ReturnType<typeof setInterval>;

  constructor(
    private readonly extensionUri: vscode.Uri,
    private readonly projectRoot: string
  ) {}

  resolveWebviewView(webviewView: vscode.WebviewView): void {
    this.view = webviewView;
    webviewView.webview.options = { enableScripts: true };
    this.refresh();
    this.timer = setInterval(() => this.refresh(), getRefreshInterval());
    webviewView.onDidDispose(() => {
      if (this.timer) clearInterval(this.timer);
    });
  }

  async refresh(): Promise<void> {
    if (!this.view) return;
    const [costResult, budgetResult] = await Promise.all([
      runDashboard(this.projectRoot, "cost"),
      runDashboard(this.projectRoot, "budget"),
    ]);

    let costData: Record<string, unknown> = {};
    let budgetData: Record<string, unknown> = {};
    try {
      costData = JSON.parse(costResult.stdout);
    } catch {
      costData = { error: costResult.stderr || "Failed to parse cost" };
    }
    try {
      budgetData = JSON.parse(budgetResult.stdout);
    } catch {
      budgetData = {};
    }

    this.view.webview.html = renderCost(costData, budgetData);
  }
}

function renderCost(
  cost: Record<string, unknown>,
  budget: Record<string, unknown>
): string {
  const error = (cost.error ?? budget.error) as string | undefined;
  if (error) {
    return `<!DOCTYPE html><html><body><p style="color:#e55;">Error: ${escapeHtml(error)}</p></body></html>`;
  }

  const agents = (cost.agents ?? []) as Array<Record<string, unknown>>;
  const utilization = budget.utilization_pct ?? "—";
  const burnRate = budget.burn_rate ?? "—";
  const projected = budget.projected_exhaustion ?? "—";

  const agentRows = agents
    .slice(0, 15)
    .map(
      (a) =>
        `<tr><td>${escapeHtml(String(a.agent ?? ""))}</td><td>${a.tokens ?? 0}</td><td>${a.tasks ?? 0}</td></tr>`
    )
    .join("");

  return `<!DOCTYPE html>
<html>
<head><style>
  body { font-family: var(--vscode-font-family); color: var(--vscode-foreground); padding: 8px; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 16px; }
  th, td { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--vscode-panel-border); }
  th { font-weight: 600; opacity: 0.7; font-size: 0.85em; }
  h3 { margin: 12px 0 4px; font-size: 1em; }
  .metric { display: flex; justify-content: space-between; padding: 4px 0; }
  .metric-label { opacity: 0.7; }
  .metric-value { font-weight: 600; }
</style></head>
<body>
  <h3>Budget</h3>
  <div class="metric"><span class="metric-label">Utilization</span><span class="metric-value">${escapeHtml(String(utilization))}%</span></div>
  <div class="metric"><span class="metric-label">Burn rate</span><span class="metric-value">${escapeHtml(String(burnRate))}</span></div>
  <div class="metric"><span class="metric-label">Projected exhaustion</span><span class="metric-value">${escapeHtml(String(projected))}</span></div>
  <h3>Cost by Agent</h3>
  <table><tr><th>Agent</th><th>Tokens</th><th>Tasks</th></tr>${agentRows || "<tr><td colspan=3>No data</td></tr>"}</table>
</body></html>`;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
