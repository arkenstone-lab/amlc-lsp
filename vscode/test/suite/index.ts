import * as assert from "node:assert/strict";
import * as path from "node:path";
import * as vscode from "vscode";

interface ServerStatus {
  command: string;
  extensionVersion: string;
  serverName?: string;
  serverVersion?: string;
  compatible: boolean;
}

interface AppliedMLExtensionApi {
  getServerStatus(): ServerStatus;
}

async function waitFor<T>(
  read: () => T | undefined,
  description: string,
): Promise<T> {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const value = read();
    if (value !== undefined) {
      return value;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for ${description}`);
}

export async function run(): Promise<void> {
  const extension = vscode.extensions.getExtension<AppliedMLExtensionApi>(
    "arkenstone-labs.appliedml",
  );
  assert.ok(extension, "AppliedML extension is not installed in the test host");

  const fakeServer = path.join(
    extension.extensionPath,
    "test",
    "fixtures",
    "fake-lsp.js",
  );
  const configuration = vscode.workspace.getConfiguration("amlcLsp");
  await configuration.update(
    "server.path",
    process.execPath,
    vscode.ConfigurationTarget.Global,
  );
  await configuration.update(
    "server.arguments",
    [fakeServer],
    vscode.ConfigurationTarget.Global,
  );

  const document = await vscode.workspace.openTextDocument(
    path.join(extension.extensionPath, "test", "workspace", "example.aml"),
  );
  await vscode.window.showTextDocument(document);
  const api = await extension.activate();

  const connected = await waitFor(() => {
    const status = api.getServerStatus();
    return status.serverVersion ? status : undefined;
  }, "the language server connection");
  assert.equal(document.languageId, "appliedml");
  assert.equal(connected.serverName, "amlc-lsp");
  assert.equal(connected.serverVersion, "0.3.0");
  assert.equal(connected.compatible, true);
  assert.equal(connected.command, process.execPath);

  const diagnostics = await waitFor(() => {
    const current = vscode.languages.getDiagnostics(document.uri);
    return current.length > 0 ? current : undefined;
  }, "published diagnostics");
  assert.equal(diagnostics[0].message, "extension-host diagnostic");

  const completions = await vscode.commands.executeCommand<
    vscode.CompletionList
  >(
    "vscode.executeCompletionItemProvider",
    document.uri,
    new vscode.Position(0, 0),
  );
  assert.ok(completions.items.some((item) => item.label === "increment"));

  const commands = await vscode.commands.getCommands(true);
  assert.ok(commands.includes("appliedml.restartServer"));
  assert.ok(commands.includes("appliedml.showServerInformation"));

  await configuration.update(
    "server.arguments",
    [fakeServer, "--server-version=0.2.1"],
    vscode.ConfigurationTarget.Global,
  );
  const mismatched = await waitFor(() => {
    const status = api.getServerStatus();
    return status.serverVersion === "0.2.1" ? status : undefined;
  }, "the restarted language server");
  assert.equal(mismatched.compatible, false);
}
