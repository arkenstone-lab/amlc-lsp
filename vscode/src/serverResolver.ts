import * as fs from "node:fs/promises";
import * as path from "node:path";

export function serverEnvironment(
  base: NodeJS.ProcessEnv,
  overrides: NodeJS.ProcessEnv,
  platform: string = process.platform,
): NodeJS.ProcessEnv {
  if (platform !== "win32") {
    const result = { ...base, ...overrides };
    delete result.AMLC_LSP_GITHUB_TOKEN;
    return result;
  }
  // Windows keys are case-insensitive. Avoid passing both Path and PATH to
  // Node's process launcher, which would otherwise discard one of them.
  const result: NodeJS.ProcessEnv = {};
  for (const [key, value] of [
    ...Object.entries(base),
    ...Object.entries(overrides),
  ]) {
    result[key.toUpperCase()] = value;
  }
  delete result.AMLC_LSP_GITHUB_TOKEN;
  return result;
}

export async function executableExists(executable: string): Promise<boolean> {
  try {
    if (!(await fs.stat(executable)).isFile()) {
      return false;
    }
    await fs.access(
      executable,
      process.platform === "win32" ? fs.constants.F_OK : fs.constants.X_OK,
    );
    return true;
  } catch {
    return false;
  }
}

export async function findServerOnPath(
  environment: NodeJS.ProcessEnv,
): Promise<string | undefined> {
  const value =
    process.platform === "win32"
      ? Object.entries(environment).find(
          ([key]) => key.toLowerCase() === "path",
        )?.[1]
      : environment.PATH;
  for (const directory of (value ?? "").split(path.delimiter).filter(Boolean)) {
    const executable = path.resolve(
      directory,
      process.platform === "win32" ? "amlc-lsp.exe" : "amlc-lsp",
    );
    if (await executableExists(executable)) {
      return executable;
    }
  }
  return undefined;
}

export interface ServerResolution {
  configured?: string;
  remembered?: string;
  autoDownload: boolean;
}
export interface ResolutionDependencies {
  findPath: () => Promise<string | undefined>;
  findOpam: () => Promise<string | undefined>;
  exists: (executable: string) => Promise<boolean>;
  download: () => Promise<string>;
}

export async function resolveServer(
  options: ServerResolution,
  deps: ResolutionDependencies,
): Promise<string> {
  if (options.configured) {
    return options.configured;
  }
  const local = (await deps.findPath()) ?? (await deps.findOpam());
  if (local) {
    return local;
  }
  if (options.remembered && (await deps.exists(options.remembered))) {
    return options.remembered;
  }
  if (options.autoDownload) {
    return deps.download();
  }
  throw new Error(
    "No local amlc-lsp found and automatic server download is disabled.",
  );
}
