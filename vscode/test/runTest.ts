import * as path from "node:path";
import { runTests } from "@vscode/test-electron";

async function main(): Promise<void> {
  const extensionDevelopmentPath = path.resolve(__dirname, "..");
  const extensionTestsPath = path.resolve(__dirname, "suite", "index");
  const workspacePath = path.resolve(
    extensionDevelopmentPath,
    "test",
    "workspace",
  );

  try {
    await runTests({
      version: "1.100.0",
      extensionDevelopmentPath,
      extensionTestsPath,
      launchArgs: [workspacePath, "--disable-extensions"],
    });
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  }
}

void main();
