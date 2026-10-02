import * as path from "node:path";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import { runTests } from "@vscode/test-electron";

async function main(): Promise<void> {
  const extensionDevelopmentPath = path.resolve(__dirname, "..");
  const extensionTestsPath = path.resolve(__dirname, "suite", "index");
  const workspacePath = path.resolve(
    extensionDevelopmentPath,
    "test",
    "workspace",
  );
  const prebuiltProfile =
    process.env.AMLC_PREBUILT_TEST === "1"
      ? await fs.mkdtemp(path.join(os.tmpdir(), "amlc-vsc-"))
      : undefined;
  const profileArgs = prebuiltProfile
    ? [
        "--user-data-dir",
        path.join(prebuiltProfile, "user-data"),
        "--extensions-dir",
        path.join(prebuiltProfile, "extensions"),
        "--disable-workspace-trust",
      ]
    : [];

  try {
    await runTests({
      version: "1.100.0",
      extensionDevelopmentPath,
      extensionTestsPath,
      launchArgs: [workspacePath, "--disable-extensions", ...profileArgs],
    });
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  } finally {
    if (prebuiltProfile) {
      if (process.env.CI) {
        await fs
          .cp(
            path.join(prebuiltProfile, "user-data", "logs"),
            path.join(__dirname, "prebuilt-logs"),
            { recursive: true },
          )
          .catch((error) =>
            console.warn("Could not preserve test logs:", error),
          );
      }
      await fs.rm(prebuiltProfile, { recursive: true, force: true });
    }
  }
}

void main();
