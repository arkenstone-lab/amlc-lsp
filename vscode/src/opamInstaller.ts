import { spawn } from "node:child_process";
import * as fs from "node:fs/promises";
import * as path from "node:path";

const requiredAmlcVersion = "0.1.0~preview";
const serverPackage = "amlc-lsp.0.3.0";
const serverSource =
  "git+https://github.com/arkenstone-lab/amlc-lsp.git#34d5c62c5e45687a0b0bd384d79657621b2deb12";

export interface CommandResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

export type CommandRunner = (
  command: string,
  args: string[],
  environment: NodeJS.ProcessEnv,
  workingDirectory?: string,
  onOutput?: (text: string) => void,
) => Promise<CommandResult>;

export interface OpamContext {
  command: string;
  workingDirectory?: string;
}

interface InstallerDependencies {
  run: CommandRunner;
  executableExists: (executable: string) => Promise<boolean>;
}

const run: CommandRunner = (
  command: string,
  args: string[],
  environment: NodeJS.ProcessEnv,
  workingDirectory?: string,
  onOutput?: (text: string) => void,
): Promise<CommandResult> => {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: workingDirectory,
      env: environment,
      shell: false,
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => {
      const text = chunk.toString();
      stdout += text;
      onOutput?.(text);
    });
    child.stderr.on("data", (chunk: Buffer) => {
      const text = chunk.toString();
      stderr += text;
      onOutput?.(text);
    });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
};

async function executableExists(executable: string): Promise<boolean> {
  try {
    await fs.access(executable);
    return true;
  } catch {
    return false;
  }
}

const defaultDependencies: InstallerDependencies = { run, executableExists };

function opamEnvironment(): NodeJS.ProcessEnv {
  return {
    ...process.env,
    OPAMCOLOR: "never",
    OPAMUTF8: "never",
  };
}

export class OpamInstallError extends Error {
  constructor(
    message: string,
    readonly kind:
      | "opam-missing"
      | "amlc-missing"
      | "amlc-incompatible"
      | "install-failed",
  ) {
    super(message);
  }
}

function executableIn(binDirectory: string): string {
  return path.join(
    binDirectory,
    process.platform === "win32" ? "amlc-lsp.exe" : "amlc-lsp",
  );
}

export async function findInstalledServerWithOpam(
  opam: OpamContext,
  dependencies: InstallerDependencies = defaultDependencies,
): Promise<string | undefined> {
  const result = await dependencies
    .run(
      opam.command,
      ["var", "bin"],
      opamEnvironment(),
      opam.workingDirectory,
    )
    .catch(() => undefined);
  if (!result || result.code !== 0 || !result.stdout.trim()) {
    return undefined;
  }
  const executable = executableIn(result.stdout.trim());
  return (await dependencies.executableExists(executable))
    ? executable
    : undefined;
}

export async function checkAmlcCompatibility(
  opam: OpamContext,
  dependencies: InstallerDependencies = defaultDependencies,
): Promise<void> {
  const environment = opamEnvironment();
  let versionResult: CommandResult;
  try {
    versionResult = await dependencies.run(
      opam.command,
      ["show", "--field=installed-version", "amlc"],
      environment,
      opam.workingDirectory,
    );
  } catch (error) {
    throw new OpamInstallError(
      `Could not run ${opam.command}: ${String(error)}`,
      "opam-missing",
    );
  }

  const installedVersion = versionResult.stdout.trim();
  if (versionResult.code !== 0 || !installedVersion) {
    throw new OpamInstallError(
      "AMLC is not installed in the active OPAM switch.",
      "amlc-missing",
    );
  }
  if (installedVersion !== requiredAmlcVersion) {
    throw new OpamInstallError(
      `The active OPAM switch contains amlc ${installedVersion}; amlc-lsp 0.3.0 requires ${requiredAmlcVersion}.`,
      "amlc-incompatible",
    );
  }
}

export async function installServerWithOpam(
  opam: OpamContext,
  onOutput: (text: string) => void,
  dependencies: InstallerDependencies = defaultDependencies,
): Promise<string> {
  const existing = await findInstalledServerWithOpam(opam, dependencies);
  if (existing) {
    onOutput(`Using the existing language server at ${existing}\n`);
    return existing;
  }

  await checkAmlcCompatibility(opam, dependencies);

  const environment = opamEnvironment();
  onOutput(`Installing ${serverPackage} from ${serverSource}\n`);
  // Manual installs may use the package's AMLC source pin. The editor must
  // preserve the AMLC package that passed the compatibility check above.
  const installResult = await dependencies.run(
    opam.command,
    [
      "pin",
      "add",
      "--yes",
      "--ignore-pin-depends",
      serverPackage,
      serverSource,
    ],
    environment,
    opam.workingDirectory,
    onOutput,
  );
  if (installResult.code !== 0) {
    const detail = installResult.stderr.trim();
    throw new OpamInstallError(
      detail || `opam exited with status ${String(installResult.code)}`,
      "install-failed",
    );
  }

  const binResult = await dependencies.run(
    opam.command,
    ["var", "bin"],
    environment,
    opam.workingDirectory,
  );
  if (binResult.code !== 0 || !binResult.stdout.trim()) {
    throw new OpamInstallError(
      "OPAM installed amlc-lsp but did not report the switch bin directory.",
      "install-failed",
    );
  }
  const executable = executableIn(binResult.stdout.trim());
  if (!(await dependencies.executableExists(executable))) {
    throw new OpamInstallError(
      `OPAM completed, but ${executable} was not found.`,
      "install-failed",
    );
  }
  return executable;
}
