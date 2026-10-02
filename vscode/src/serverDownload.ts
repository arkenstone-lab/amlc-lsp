import { createHash } from "node:crypto";
import { createWriteStream } from "node:fs";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { pipeline } from "node:stream/promises";
import * as tar from "tar";
import * as yauzl from "yauzl";

export const downloadedServerVersion = "0.4.0";
const repository = "arkenstone-lab/amlc-lsp";
const archiveLimit = 50 * 1024 * 1024;
const extractedLimit = 150 * 1024 * 1024;
const fileLimit = 2000;

export interface AssetSpec {
  name: string;
  directory: string;
  executable: string;
  format: "tar.gz" | "zip";
}

export function serverAsset(
  platform: string = process.platform,
  architecture: string = process.arch,
): AssetSpec {
  const targets: Record<string, string> = {
    "darwin-arm64": "aarch64-apple-darwin",
    "darwin-x64": "x86_64-apple-darwin",
    "linux-arm64": "aarch64-unknown-linux-gnu",
    "linux-x64": "x86_64-unknown-linux-gnu",
    "win32-x64": "x86_64-pc-windows-gnu",
  };
  const target = targets[`${platform}-${architecture}`];
  if (!target) {
    throw new Error(
      `No prebuilt amlc-lsp for ${platform}/${architecture}. Configure a local server or use OPAM.`,
    );
  }
  const directory = `amlc-lsp-v${downloadedServerVersion}-${target}`;
  const format = platform === "win32" ? "zip" : "tar.gz";
  return {
    directory,
    format,
    name: `${directory}.${format}`,
    executable: platform === "win32" ? "amlc-lsp.exe" : "amlc-lsp",
  };
}

export function validateDownloadUrl(value: string): URL {
  const url = new URL(value);
  if (
    url.protocol !== "https:" ||
    url.username ||
    url.password ||
    url.port ||
    ![
      "api.github.com",
      "github.com",
      "release-assets.githubusercontent.com",
      "objects.githubusercontent.com",
    ].includes(url.hostname)
  ) {
    throw new Error(
      "Server download must use an official GitHub HTTPS endpoint.",
    );
  }
  return url;
}

async function download(value: string, limit: number): Promise<Buffer> {
  let url = validateDownloadUrl(value);
  const signal = AbortSignal.timeout(120_000);
  for (let redirects = 0; redirects <= 5; redirects++) {
    const response = await fetch(url, {
      redirect: "manual",
      signal,
      headers: {
        "User-Agent": "AppliedML-VSCode",
        Accept:
          url.hostname === "api.github.com"
            ? "application/vnd.github+json"
            : "application/octet-stream",
      },
    });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      await response.body?.cancel();
      if (!location) {
        throw new Error("GitHub returned a redirect without a location.");
      }
      url = validateDownloadUrl(new URL(location, url).href);
      continue;
    }
    if (!response.ok || !response.body) {
      await response.body?.cancel();
      throw new Error(`GitHub download failed (HTTP ${response.status}).`);
    }
    if (Number(response.headers.get("content-length")) > limit) {
      await response.body.cancel();
      throw new Error("Server download exceeds the size limit.");
    }
    const reader = response.body.getReader();
    const chunks: Buffer[] = [];
    let size = 0;
    try {
      for (;;) {
        const part = await reader.read();
        if (part.done) {
          break;
        }
        size += part.value.byteLength;
        if (size > limit) {
          throw new Error("Server download exceeds the size limit.");
        }
        chunks.push(Buffer.from(part.value));
      }
    } finally {
      await reader.cancel().catch(() => undefined);
    }
    return Buffer.concat(chunks);
  }
  throw new Error("Too many GitHub download redirects.");
}

export function archivePath(name: string): string {
  if (name.startsWith("/") || name.includes("\\") || name.includes("\0")) {
    throw new Error(`Unsafe archive path: ${name}`);
  }
  const parts = name.split("/").filter((part) => part !== "." && part !== "");
  if (
    parts.some(
      (part) =>
        part === ".." ||
        part.includes(":") ||
        /[. ]$/.test(part) ||
        /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part),
    )
  ) {
    throw new Error(`Unsafe archive path: ${name}`);
  }
  return parts.join("/");
}

export async function extractArchive(
  archive: string,
  destination: string,
  format: AssetSpec["format"],
): Promise<void> {
  let total = 0;
  let count = 0;
  const names = new Set<string>();
  const inspect = (name: string, size: number, directory: boolean): string => {
    const relative = archivePath(name);
    if (!relative && !directory) {
      throw new Error("Empty archive filename.");
    }
    if (relative && names.has(relative)) {
      throw new Error("Duplicate archive entry.");
    }
    names.add(relative);
    total += size;
    if (
      ++count > fileLimit ||
      !Number.isSafeInteger(size) ||
      size < 0 ||
      total > extractedLimit
    ) {
      throw new Error("Server archive exceeds extraction limits.");
    }
    return relative;
  };
  if (format === "tar.gz") {
    let invalid: Error | undefined;
    // Validate the complete archive before writing any entries. Links and special
    // files are not part of the published server layout and are never extracted.
    await tar.t({
      file: archive,
      strict: true,
      filter: (name, entry) => {
        try {
          if (
            !("type" in entry) ||
            (entry.type !== "File" && entry.type !== "Directory")
          ) {
            throw new Error("Server archive contains a link or special file.");
          }
          inspect(name, entry.size, entry.type === "Directory");
        } catch (error) {
          invalid ??= error as Error;
        }
        return false;
      },
    });
    if (invalid) {
      throw invalid;
    }
    await tar.x({
      file: archive,
      cwd: destination,
      strict: true,
      preserveOwner: false,
      noChmod: true,
      noMtime: true,
    });
    return;
  }
  await new Promise<void>((resolve, reject) => {
    yauzl.open(
      archive,
      { lazyEntries: true, strictFileNames: true, validateEntrySizes: true },
      (error, zip) => {
        if (error || !zip) {
          reject(error ?? new Error("Invalid ZIP archive."));
          return;
        }
        const fail = (failure: unknown) => {
          zip.close();
          reject(failure);
        };
        zip.on("error", fail);
        zip.on("end", resolve);
        zip.on("entry", (entry: yauzl.Entry) => {
          void (async () => {
            const mode = (entry.externalFileAttributes >>> 16) & 0o170000;
            if (mode !== 0 && mode !== 0o100000 && mode !== 0o040000) {
              throw new Error("Server ZIP contains a link or special file.");
            }
            const directory = entry.fileName.endsWith("/");
            const relative = inspect(
              entry.fileName,
              entry.uncompressedSize,
              directory,
            );
            const target = path.join(destination, relative);
            if (directory) {
              await fs.mkdir(target, { recursive: true });
            } else {
              await fs.mkdir(path.dirname(target), { recursive: true });
              await new Promise<void>((done, failed) =>
                zip.openReadStream(entry, (streamError, stream) => {
                  if (streamError || !stream) {
                    failed(streamError);
                    return;
                  }
                  void pipeline(
                    stream,
                    createWriteStream(target, { flags: "wx", mode: 0o600 }),
                  ).then(done, failed);
                }),
              );
            }
            zip.readEntry();
          })().catch(fail);
        });
        zip.readEntry();
      },
    );
  });
}

export interface DownloadDependencies {
  download: (url: string, limit: number) => Promise<Buffer>;
  extract: typeof extractArchive;
}
const dependencies: DownloadDependencies = {
  download,
  extract: extractArchive,
};
const pending = new Map<string, Promise<string>>();

async function cachedExecutable(
  directory: string,
  spec: AssetSpec,
): Promise<string | undefined> {
  const executable = path.join(directory, spec.executable);
  try {
    const marker = JSON.parse(
      await fs.readFile(path.join(directory, ".installed.json"), "utf8"),
    );
    if (
      marker.asset !== spec.name ||
      marker.version !== downloadedServerVersion
    ) {
      return undefined;
    }
    const stat = await fs.lstat(executable);
    if (!stat.isFile()) {
      return undefined;
    }
    await fs.access(
      executable,
      process.platform === "win32" ? fs.constants.F_OK : fs.constants.X_OK,
    );
    return executable;
  } catch {
    return undefined;
  }
}

async function install(
  storage: string,
  spec: AssetSpec,
  log: (message: string) => void,
  deps: DownloadDependencies,
): Promise<string> {
  const parent = path.join(storage, "servers");
  const destination = path.join(parent, spec.directory);
  const cached = await cachedExecutable(destination, spec);
  if (cached) {
    return cached;
  }
  await fs.mkdir(parent, { recursive: true });
  const stage = await fs.mkdtemp(path.join(parent, ".download-"));
  try {
    log(
      `Downloading ${spec.name} from GitHub release v${downloadedServerVersion}.`,
    );
    const metadata = JSON.parse(
      (
        await deps.download(
          `https://api.github.com/repos/${repository}/releases/tags/v${downloadedServerVersion}`,
          2 * 1024 * 1024,
        )
      ).toString("utf8"),
    );
    if (
      metadata.tag_name !== `v${downloadedServerVersion}` ||
      metadata.draft ||
      metadata.prerelease
    ) {
      throw new Error("GitHub returned an unexpected server release.");
    }
    const asset = metadata.assets?.find(
      (candidate: { name: string }) => candidate.name === spec.name,
    );
    if (
      !asset ||
      !/^sha256:[a-f0-9]{64}$/.test(asset.digest ?? "") ||
      !Number.isSafeInteger(asset.size) ||
      asset.size <= 0 ||
      asset.size > archiveLimit
    ) {
      throw new Error(`Release is missing a verified ${spec.name} asset.`);
    }
    const expectedUrl = `https://github.com/${repository}/releases/download/v${downloadedServerVersion}/${spec.name}`;
    if (asset.browser_download_url !== expectedUrl) {
      throw new Error("Unexpected server asset URL.");
    }
    const bytes = await deps.download(expectedUrl, archiveLimit);
    const digest = `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
    if (bytes.length !== asset.size || digest !== asset.digest) {
      throw new Error(
        "Server archive size or SHA-256 does not match GitHub release metadata.",
      );
    }
    const archive = path.join(stage, "archive");
    const extracted = path.join(stage, "content");
    await fs.writeFile(archive, bytes, { flag: "wx", mode: 0o600 });
    await fs.mkdir(extracted);
    await deps.extract(archive, extracted, spec.format);
    const executable = path.join(extracted, spec.executable);
    if (!(await fs.lstat(executable)).isFile()) {
      throw new Error("Server archive has no executable.");
    }
    for (const notice of ["LICENSE", "THIRD_PARTY_NOTICES.md"]) {
      if (!(await fs.lstat(path.join(extracted, notice))).isFile()) {
        throw new Error(`Server archive is missing ${notice}.`);
      }
    }
    if (spec.format !== "zip") {
      await fs.chmod(executable, 0o755);
    }
    await fs.writeFile(
      path.join(extracted, ".installed.json"),
      JSON.stringify({
        version: downloadedServerVersion,
        asset: spec.name,
        digest,
      }),
    );
    // Another extension host may finish the same installation first.
    const concurrent = await cachedExecutable(destination, spec);
    if (concurrent) {
      return concurrent;
    }
    try {
      await fs.rename(extracted, destination);
    } catch (error) {
      const ready = await cachedExecutable(destination, spec);
      if (ready) {
        return ready;
      }
      if (
        !(await fs.lstat(destination).catch(() => undefined))?.isDirectory()
      ) {
        throw error;
      }
      // Quarantine only this version's incomplete cache, never a local server.
      // Restore it if replacement fails, and leave other versions untouched.
      const previous = path.join(stage, "previous");
      await fs.rename(destination, previous);
      try {
        await fs.rename(extracted, destination);
      } catch (replacementError) {
        await fs.rename(previous, destination);
        throw replacementError;
      }
    }
    log(
      `Installed verified server: ${path.join(destination, spec.executable)}`,
    );
    return path.join(destination, spec.executable);
  } finally {
    await fs.rm(stage, { recursive: true, force: true });
  }
}

export function downloadServer(
  storage: string,
  log: (message: string) => void = () => undefined,
  spec: AssetSpec = serverAsset(),
  deps: DownloadDependencies = dependencies,
): Promise<string> {
  const key = path.join(storage, spec.directory);
  const existing = pending.get(key);
  if (existing) {
    return existing;
  }
  const promise = install(storage, spec, log, deps).finally(() =>
    pending.delete(key),
  );
  pending.set(key, promise);
  return promise;
}
