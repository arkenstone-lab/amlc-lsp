import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";

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

function launchConfiguration(): LaunchConfiguration {
  const configuration = vscode.workspace.getConfiguration("amlcLsp");
  const configuredPath = configuration.get<string>("server.path", "").trim();
  return {
    command: configuredPath || "amlc-lsp",
    args: configuration.get<string[]>("server.arguments", []),
    environment: configuration.get<Record<string, string>>(
      "server.environment",
      {},
    ),
  };
}

function serverOptions(launch: LaunchConfiguration): ServerOptions {
  return {
    command: launch.command,
    args: launch.args,
    options: {
      env: { ...process.env, ...launch.environment },
    },
  };
}

function clientOptions(): LanguageClientOptions {
  const configuration = vscode.workspace.getConfiguration("amlcLsp");
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

async function startClient(): Promise<void> {
  const launch = launchConfiguration();
  outputChannel?.appendLine(`Starting amlc-lsp: ${launch.command}`);
  const nextClient = new LanguageClient(
    "amlcLsp",
    "AppliedML Language Server",
    serverOptions(launch),
    clientOptions(),
  );
  await nextClient.start();
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

async function startClientWithMessage(): Promise<void> {
  try {
    await startClient();
  } catch (error) {
    client = undefined;
    activeLaunch = undefined;
    activeServerName = undefined;
    activeServerVersion = undefined;
    outputChannel?.appendLine(`Failed to start amlc-lsp: ${String(error)}`);
    void vscode.window
      .showErrorMessage(
        "AppliedML could not start amlc-lsp. Install the server or configure " +
          "amlcLsp.server.path. See the AppliedML output channel for details.",
        "Open Settings",
        "Installation Guide",
      )
      .then((selection) => {
        if (selection === "Open Settings") {
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

async function restartClient(): Promise<void> {
  if (client) {
    await client.stop();
    client = undefined;
  }
  activeServerName = undefined;
  activeServerVersion = undefined;
  await startClientWithMessage();
}

function queueRestart(): Promise<void> {
  lifecycle = lifecycle.then(restartClient, restartClient);
  return lifecycle;
}

export async function activate(
  context: vscode.ExtensionContext,
): Promise<AppliedMLExtensionApi> {
  extensionVersion = String(context.extension.packageJSON.version ?? "unknown");
  outputChannel = vscode.window.createOutputChannel("AppliedML");
  context.subscriptions.push(outputChannel);
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "appliedml.restartServer",
      queueRestart,
    ),
    vscode.commands.registerCommand(
      "appliedml.showServerInformation",
      reportServerStatus,
    ),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (
        event.affectsConfiguration("amlcLsp.server.path") ||
        event.affectsConfiguration("amlcLsp.server.arguments") ||
        event.affectsConfiguration("amlcLsp.server.environment")
      ) {
        void queueRestart();
      }
    }),
  );
  await startClientWithMessage();
  return { getServerStatus: currentStatus };
}

export async function deactivate(): Promise<void> {
  await lifecycle;
  if (client) {
    await client.stop();
    client = undefined;
  }
}
