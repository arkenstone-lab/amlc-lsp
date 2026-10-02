import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";
import {
  checkAmlcCompatibility,
  findInstalledServerWithOpam,
  installServerWithOpam,
  OpamContext,
  OpamInstallError,
} from "./opamInstaller";
import { downloadServer, downloadedServerVersion } from "./serverDownload";
import { executableExists, findServerOnPath, resolveServer, serverEnvironment } from "./serverResolver";

interface LaunchConfiguration {
  command: string;
  args: string[];
  environment: Record<string, string>;
}

export interface ServerStatus {
  command: string;
  extensionVersion: string;
  serverName?: string;
  serverVersion?: string;
  compatible: boolean;
}

export interface AppliedMLExtensionApi {
  getServerStatus(): ServerStatus;
}

let client: LanguageClient | undefined;
let outputChannel: vscode.OutputChannel | undefined;
let extensionVersion = "unknown";
let activeLaunch: LaunchConfiguration | undefined;
let activeServerName: string | undefined;
let activeServerVersion: string | undefined;
let lastVersionWarning: string | undefined;
let lifecycle: Promise<void> = Promise.resolve();
let installation: Promise<void> | undefined;
let managedServerPath: string | undefined;

const managedServerPathKey = "amlcLsp.managedServerPath";

function launchConfiguration(): LaunchConfiguration {
  const configuration = vscode.workspace.getConfiguration("amlcLsp");
  const configuredPath = configuration.get<string>("server.path", "").trim();
  return {
    command: configuredPath || managedServerPath || "amlc-lsp",
    args: configuration.get<string[]>("server.arguments", []),
    environment: configuration.get<Record<string, string>>(
      "server.environment",
      {},
    ),
  };
}

function opamContext(): OpamContext {
  const command =
    vscode.workspace
      .getConfiguration("amlcLsp")
      .get<string>("opam.path", "opam")
      .trim() || "opam";
  // OPAM resolves a project-local switch from the command's working directory.
  const workingDirectory = vscode.workspace.workspaceFolders?.find(
    (folder) => folder.uri.scheme === "file",
  )?.uri.fsPath;
  return { command, workingDirectory };
}

async function rememberServer(
  context: vscode.ExtensionContext,
  executable: string,
): Promise<void> {
  managedServerPath = executable;
  await context.globalState.update(managedServerPathKey, executable);
}

function serverOptions(launch: LaunchConfiguration): ServerOptions {
  return {
    command: launch.command,
    args: launch.args,
    options: {
      env: serverEnvironment(process.env, launch.environment),
    },
  };
}

function clientOptions(): LanguageClientOptions {
  const configuration = vscode.workspace.getConfiguration("amlcLsp",
    vscode.window.activeTextEditor?.document.uri);
  return {
    documentSelector: [
      { scheme: "file", language: "appliedml" },
      { scheme: "untitled", language: "appliedml" },
    ],
    initializationOptions: {
      dialect: configuration.get<string>("dialect", "auto"),
    },
    outputChannel,
    synchronize: {
      configurationSection: "amlcLsp",
    },
  };
}

function releaseLine(version: string | undefined): string | undefined {
  const match = version?.match(/^(\d+)\.(\d+)(?:\.|$)/);
  return match ? `${match[1]}.${match[2]}` : undefined;
}

function currentStatus(): ServerStatus {
  const expected = releaseLine(extensionVersion);
  const actual = releaseLine(activeServerVersion);
  return {
    command: activeLaunch?.command ?? launchConfiguration().command,
    extensionVersion,
    serverName: activeServerName,
    serverVersion: activeServerVersion,
    compatible:
      activeServerName === "amlc-lsp" &&
      expected !== undefined &&
      actual !== undefined &&
      expected === actual,
  };
}

function reportServerStatus(): ServerStatus {
  const status = currentStatus();
  const server = status.serverVersion ?? "not connected";
  const message =
    `AppliedML extension ${status.extensionVersion}; ` +
    `amlc-lsp ${server}; executable: ${status.command}`;
  outputChannel?.appendLine(message);
  outputChannel?.show(true);
  void vscode.window.showInformationMessage(message);
  return status;
}

function warnIfIncompatible(): void {
  const status = currentStatus();
  if (status.compatible) {
    lastVersionWarning = undefined;
    return;
  }
  const key = `${status.serverName ?? "unknown"}:${status.serverVersion ?? "unknown"}`;
  if (lastVersionWarning === key) {
    return;
  }
  lastVersionWarning = key;
  const reportedName = status.serverName ?? "an unknown language server";
  const reported = status.serverVersion ?? "an unknown version";
  void vscode.window
    .showWarningMessage(
      `AppliedML ${status.extensionVersion} connected to ${reportedName} ${reported}. ` +
        "Use the same major.minor release line to avoid missing or incompatible features.",
      "Show Server Information",
    )
    .then((selection) => {
      if (selection) {
        void vscode.commands.executeCommand("appliedml.showServerInformation");
      }
    });
}

async function startClient(context: vscode.ExtensionContext): Promise<void> {
  const launch = launchConfiguration();
  const configuration = vscode.workspace.getConfiguration("amlcLsp");
  launch.command = await resolveServer({
    configured: configuration.get<string>("server.path", "").trim(),
    remembered: managedServerPath,
    autoDownload: configuration.get<boolean>("server.autoDownload", true),
  }, {
    findPath: () => findServerOnPath(serverEnvironment(process.env, launch.environment)),
    findOpam: () => findInstalledServerWithOpam(opamContext()),
    exists: executableExists,
    download: async () => {
      if (!vscode.workspace.isTrusted) {
        throw new Error("Trust the workspace before downloading and running amlc-lsp.");
      }
      return vscode.window.withProgress({
        location: vscode.ProgressLocation.Notification,
        title: `Preparing amlc-lsp ${downloadedServerVersion}`,
        cancellable: false,
      }, () => downloadServer(context.globalStorageUri.fsPath,
        message => outputChannel?.appendLine(message)));
    },
  });
  outputChannel?.appendLine(`Starting amlc-lsp: ${launch.command}`);
  const nextClient = new LanguageClient(
    "amlcLsp",
    "AppliedML Language Server",
    serverOptions(launch),
    clientOptions(),
  );
  try { await nextClient.start(); }
  catch (error) {
    await nextClient.stop().catch(() => undefined);
    nextClient.dispose();
    throw error;
  }
  client = nextClient;
  activeLaunch = launch;
  activeServerName = nextClient.initializeResult?.serverInfo?.name;
  activeServerVersion = nextClient.initializeResult?.serverInfo?.version;
  outputChannel?.appendLine(
    `Connected to ${activeServerName ?? "unknown server"} ` +
      `${activeServerVersion ?? "with no reported version"}.`,
  );
  warnIfIncompatible();
}

async function startClientWithMessage(
  context: vscode.ExtensionContext,
): Promise<void> {
  try {
    await startClient(context);
  } catch (error) {
    client = undefined;
    activeLaunch = undefined;
    activeServerName = undefined;
    activeServerVersion = undefined;
    outputChannel?.appendLine(`Failed to start amlc-lsp: ${String(error)}`);
    void vscode.window
      .showErrorMessage(
        `AppliedML could not start amlc-lsp: ${String(error)}. ` +
          "Configure a local server or install with OPAM. See the AppliedML output channel for details.",
        "Install with OPAM",
        "Open Settings",
        "Installation Guide",
      )
      .then((selection) => {
        if (selection === "Install with OPAM") {
          void vscode.commands.executeCommand("appliedml.installServer");
        } else if (selection === "Open Settings") {
          void vscode.commands.executeCommand(
            "workbench.action.openSettings",
            "@ext:arkenstone-labs.appliedml amlcLsp.server.path",
          );
        } else if (selection === "Installation Guide") {
          void vscode.env.openExternal(
            vscode.Uri.parse(
              "https://github.com/arkenstone-lab/amlc-lsp#install-the-server",
            ),
          );
        }
      });
  }
}

function installErrorMessage(error: unknown): string {
  if (!(error instanceof OpamInstallError)) {
    return "AppliedML could not install amlc-lsp. See the AppliedML output channel.";
  }
  switch (error.kind) {
    case "opam-missing":
      return "AppliedML could not run OPAM. Install OPAM or configure amlcLsp.opam.path.";
    case "amlc-missing":
      return "AMLC is not installed in the active OPAM switch. Install AMLC first, then retry.";
    case "amlc-incompatible":
      return error.message;
    case "install-failed":
      return "AppliedML could not install amlc-lsp. See the AppliedML output channel.";
  }
}

async function showInstallationError(error: unknown): Promise<void> {
  outputChannel?.appendLine(`OPAM installation failed: ${String(error)}`);
  outputChannel?.show(true);
  const selection = await vscode.window.showErrorMessage(
    installErrorMessage(error),
    "Installation Guide",
  );
  if (selection) {
    await vscode.env.openExternal(
      vscode.Uri.parse(
        "https://github.com/arkenstone-lab/amlc-lsp#install-the-server",
      ),
    );
  }
}

async function runServerInstallation(
  context: vscode.ExtensionContext,
): Promise<void> {
  const opam = opamContext();
  const existing = await findInstalledServerWithOpam(opam);
  if (existing) {
    await rememberServer(context, existing);
    void vscode.window.showInformationMessage(
      "AppliedML found amlc-lsp in the active OPAM switch.",
    );
    await queueRestart(context);
    return;
  }

  try {
    await checkAmlcCompatibility(opam);
  } catch (error) {
    await showInstallationError(error);
    return;
  }

  const confirmation = await vscode.window.showInformationMessage(
    "Install amlc-lsp 0.4.0 from its audited GitHub release into the active " +
      "OPAM switch? The existing AMLC package will not be installed or replaced.",
    { modal: true },
    "Install",
  );
  if (confirmation !== "Install") {
    return;
  }

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: "Installing amlc-lsp in the active OPAM switch",
      cancellable: false,
    },
    async () => {
      outputChannel?.appendLine(
        `Running the OPAM installer through: ${opam.command}`,
      );
      try {
        const executable = await installServerWithOpam(opam, (text) => {
          outputChannel?.append(text);
        });
        await rememberServer(context, executable);
        outputChannel?.appendLine(
          `Using installed language server: ${executable}`,
        );
        void vscode.window.showInformationMessage(
          "AppliedML installed amlc-lsp in the active OPAM switch.",
        );
        await queueRestart(context);
      } catch (error) {
        await showInstallationError(error);
      }
    },
  );
}

async function installServer(context: vscode.ExtensionContext): Promise<void> {
  if (installation) {
    return installation;
  }
  installation = runServerInstallation(context);
  try {
    await installation;
  } finally {
    installation = undefined;
  }
}

async function restartClient(context: vscode.ExtensionContext): Promise<void> {
  if (client) {
    await client.stop();
    client = undefined;
  }
  activeServerName = undefined;
  activeServerVersion = undefined;
  await startClientWithMessage(context);
}

function queueRestart(context: vscode.ExtensionContext): Promise<void> {
  const restart = () => restartClient(context);
  lifecycle = lifecycle.then(restart, restart);
  return lifecycle;
}

export async function activate(
  context: vscode.ExtensionContext,
): Promise<AppliedMLExtensionApi> {
  extensionVersion = String(context.extension.packageJSON.version ?? "unknown");
  managedServerPath = context.globalState.get<string>(managedServerPathKey);
  outputChannel = vscode.window.createOutputChannel("AppliedML");
  context.subscriptions.push(outputChannel);
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "appliedml.restartServer",
      () => queueRestart(context),
    ),
    vscode.commands.registerCommand(
      "appliedml.showServerInformation",
      reportServerStatus,
    ),
    vscode.commands.registerCommand("appliedml.installServer", () =>
      installServer(context),
    ),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (
        event.affectsConfiguration("amlcLsp.server.path") ||
        event.affectsConfiguration("amlcLsp.server.autoDownload") ||
        event.affectsConfiguration("amlcLsp.server.arguments") ||
        event.affectsConfiguration("amlcLsp.server.environment") ||
        event.affectsConfiguration("amlcLsp.opam.path")
      ) {
        if (event.affectsConfiguration("amlcLsp.opam.path")) {
          managedServerPath = undefined;
          void context.globalState.update(managedServerPathKey, undefined);
        }
        void queueRestart(context);
      }
    }),
  );
  await queueRestart(context);
  return { getServerStatus: currentStatus };
}

export async function deactivate(): Promise<void> {
  await lifecycle;
  if (client) {
    await client.stop();
    client = undefined;
  }
}
