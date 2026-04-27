import * as vscode from "vscode";
import { InboxViewProvider } from "./views/inbox";
import { CostViewProvider } from "./views/cost";
import { DispatchViewProvider } from "./views/dispatch";
import { resolveProjectRoot } from "./cli";

export function activate(context: vscode.ExtensionContext): void {
  const projectRoot = resolveProjectRoot();

  const inboxProvider = new InboxViewProvider(context.extensionUri, projectRoot);
  const costProvider = new CostViewProvider(context.extensionUri, projectRoot);
  const dispatchProvider = new DispatchViewProvider(
    context.extensionUri,
    projectRoot
  );

  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider("orchInbox", inboxProvider),
    vscode.window.registerWebviewViewProvider("orchCost", costProvider),
    vscode.window.registerWebviewViewProvider("orchDispatch", dispatchProvider)
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("claude-orch.refreshInbox", () => {
      inboxProvider.refresh();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("claude-orch.dispatch", async () => {
      const work = await vscode.window.showInputBox({
        prompt: "Describe the work to dispatch",
        placeHolder: "e.g. implement auth middleware",
      });
      if (work) {
        dispatchProvider.dispatch(work);
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("claude-orch.showStatus", () => {
      inboxProvider.showStatus();
    })
  );
}

export function deactivate(): void {}
