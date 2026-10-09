import * as assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";

async function wait<T>(read: () => T | undefined, label: string): Promise<T> {
  const deadline = Date.now() + 180_000;
  while (Date.now() < deadline) {
    const result = read();
    if (result !== undefined) {
      return result;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for ${label}`);
}

export async function runPrebuiltTest(): Promise<void> {
  const extension = vscode.extensions.getExtension("arkenstone-labs.appliedml");
  assert.ok(extension);
  const configuration = vscode.workspace.getConfiguration("amlcLsp");
  // This optional network test must use a fresh isolated profile. No system
  // server, compiler, or OPAM is visible to the resolver or downloaded process.
  await configuration.update(
    "server.path",
    "",
    vscode.ConfigurationTarget.Global,
  );
  await configuration.update(
    "server.arguments",
    [],
    vscode.ConfigurationTarget.Global,
  );
  await configuration.update(
    "server.environment",
    { PATH: "" },
    vscode.ConfigurationTarget.Global,
  );
  await configuration.update(
    "opam.path",
    path.join(extension.extensionPath, "nonexistent-opam"),
    vscode.ConfigurationTarget.Global,
  );
  await configuration.update(
    "server.autoDownload",
    true,
    vscode.ConfigurationTarget.Global,
  );
  const directory = await fs.mkdtemp(
    path.join(os.tmpdir(), "amlc-prebuilt-editor-"),
  );
  const uri = vscode.Uri.file(path.join(directory, "example.aml"));
  try {
    await fs.writeFile(
      uri.fsPath,
      "program Example {\n  fn inc(n: int): int { return n + 1 }\n  fn run(): int { return inc(1) }\n}\n",
    );
    const document = await vscode.workspace.openTextDocument(uri);
    await vscode.window.showTextDocument(document);
    const api = await extension.activate();
    const status = await wait(() => {
      const current = api.getServerStatus();
      return current.serverVersion ? current : undefined;
    }, "prebuilt server connection");
    assert.equal(status.serverVersion, "0.4.2");
    assert.equal(status.compatible, true);
    assert.ok(status.command.includes("amlc-lsp-v0.4.2-"));
    const position = new vscode.Position(2, 25);
    const completion =
      await vscode.commands.executeCommand<vscode.CompletionList>(
        "vscode.executeCompletionItemProvider",
        uri,
        position,
      );
    assert.ok(completion?.items.some((item) => item.label === "inc"));
    const definitions = await vscode.commands.executeCommand<unknown[]>(
      "vscode.executeDefinitionProvider",
      uri,
      position,
    );
    assert.ok(definitions && definitions.length > 0);
    const hover = await vscode.commands.executeCommand<unknown[]>(
      "vscode.executeHoverProvider",
      uri,
      position,
    );
    assert.ok(hover && hover.length > 0);
    const edit = new vscode.WorkspaceEdit();
    edit.replace(
      uri,
      document.lineAt(2).range,
      "  fn run(): int { return inc(true) }",
    );
    await vscode.workspace.applyEdit(edit);
    await wait(
      () =>
        vscode.languages.getDiagnostics(uri).length > 0 ? true : undefined,
      "compiler diagnostic",
    );
    const fix = new vscode.WorkspaceEdit();
    fix.replace(
      uri,
      document.lineAt(2).range,
      "  fn run(): int { return inc(1) }",
    );
    await vscode.workspace.applyEdit(fix);
    await wait(
      () =>
        vscode.languages.getDiagnostics(uri).length === 0 ? true : undefined,
      "diagnostic recovery",
    );
    await document.save();
    const executable = status.command;
    const before = (await fs.stat(executable)).mtimeMs;
    await vscode.commands.executeCommand("appliedml.restartServer");
    assert.equal(api.getServerStatus().command, executable);
    assert.equal(api.getServerStatus().serverVersion, "0.4.2");
    assert.equal((await fs.stat(executable)).mtimeMs, before);
    console.log(
      "PREBUILT SERVER PASS: no PATH/OPAM/AMLC; completion, definition, hover, diagnostics, cache restart",
    );
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
}
