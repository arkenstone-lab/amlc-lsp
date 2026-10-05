import * as assert from "node:assert/strict";
import { createHash } from "node:crypto";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import * as tar from "tar";
import {
  archivePath,
  downloadServer,
  extractArchive,
  githubRequestHeaders,
  serverAsset,
  validateDownloadUrl,
  type DownloadDependencies,
} from "../../src/serverDownload";

test("selects all five release platforms and rejects unsupported targets", () => {
  for (const [platform, arch, target] of [
    ["darwin", "arm64", "aarch64-apple-darwin"],
    ["darwin", "x64", "x86_64-apple-darwin"],
    ["linux", "arm64", "aarch64-unknown-linux-gnu"],
    ["linux", "x64", "x86_64-unknown-linux-gnu"],
    ["win32", "x64", "x86_64-pc-windows-gnu"],
  ]) {
    const spec = serverAsset(platform, arch);
    assert.ok(spec.name.includes(`v0.4.1-${target}`));
    assert.equal(spec.format, platform === "win32" ? "zip" : "tar.gz");
  }
  assert.throws(() => serverAsset("win32", "arm64"), /No prebuilt/);
  assert.throws(() => serverAsset("linux", "ia32"), /No prebuilt/);
});

test("restricts URLs to GitHub HTTPS hosts, including redirects", () => {
  for (const url of [
    "https://github.com/a",
    "https://api.github.com/a",
    "https://release-assets.githubusercontent.com/a",
  ]) {
    validateDownloadUrl(url);
  }
  for (const url of [
    "http://github.com/a",
    "https://github.com.evil.test/a",
    "https://user:password@github.com/a",
    "https://github.com:444/a",
    "file:///tmp/a",
  ]) {
    assert.throws(() => validateDownloadUrl(url));
  }
});

test("optional credentials are restricted to the pinned release metadata", () => {
  const metadata = new URL(
    "https://api.github.com/repos/arkenstone-lab/amlc-lsp/releases/tags/v0.4.1",
  );
  assert.equal(
    githubRequestHeaders(metadata, "test-token").Authorization,
    "Bearer test-token",
  );
  assert.equal(githubRequestHeaders(metadata, "").Authorization, undefined);
  for (const value of [
    "https://github.com/arkenstone-lab/amlc-lsp/releases/download/v0.4.1/server.tar.gz",
    "https://release-assets.githubusercontent.com/archive",
    "https://objects.githubusercontent.com/archive",
    "https://api.github.com/repos/other/repository/releases/tags/v0.4.1",
    "https://api.github.com/repos/arkenstone-lab/amlc-lsp/releases/tags/v0.4.1?redirected=1",
  ]) {
    assert.equal(
      githubRequestHeaders(new URL(value), "test-token").Authorization,
      undefined,
    );
  }
});

test("rejects traversal, absolute, Windows device, and ambiguous archive paths", () => {
  assert.equal(archivePath("./source/gmp.tar.xz"), "source/gmp.tar.xz");
  for (const name of [
    "../escape",
    "source/../../escape",
    "/tmp/escape",
    "C:/escape",
    "source\\escape",
    "NUL",
    "aux.txt",
    "name.",
    "name ",
    "a\0b",
  ]) {
    assert.throws(() => archivePath(name), /Unsafe/);
  }
});

async function sandbox(run: (directory: string) => Promise<void>) {
  const directory = await fs.mkdtemp(
    path.join(os.tmpdir(), "amlc-download-test-"),
  );
  try {
    await run(directory);
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
}

function fixture(overrides: Record<string, unknown> = {}) {
  const spec = serverAsset();
  const bytes = Buffer.from("verified archive fixture");
  const asset = {
    name: spec.name,
    size: bytes.length,
    digest: `sha256:${createHash("sha256").update(bytes).digest("hex")}`,
    browser_download_url: `https://github.com/arkenstone-lab/amlc-lsp/releases/download/v0.4.1/${spec.name}`,
    ...overrides,
  };
  let downloads = 0;
  const deps: DownloadDependencies = {
    download: async (url) => {
      downloads++;
      return url.includes("api.github.com")
        ? Buffer.from(
            JSON.stringify({
              tag_name: "v0.4.1",
              draft: false,
              assets: [asset],
            }),
          )
        : bytes;
    },
    extract: async (_archive, destination) => {
      for (const name of [
        spec.executable,
        "LICENSE",
        "THIRD_PARTY_NOTICES.md",
      ]) {
        await fs.writeFile(path.join(destination, name), "fixture");
      }
    },
  };
  return { spec, deps, count: () => downloads };
}

test("installs atomically and reuses a complete cache without networking", () =>
  sandbox(async (storage) => {
    const { spec, deps, count } = fixture();
    const executable = await downloadServer(storage, undefined, spec, deps);
    assert.equal(
      executable,
      path.join(storage, "servers", spec.directory, spec.executable),
    );
    assert.equal(count(), 2);
    assert.equal(
      await downloadServer(storage, undefined, spec, deps),
      executable,
    );
    assert.equal(count(), 2);
    assert.deepEqual(await fs.readdir(path.join(storage, "servers")), [
      spec.directory,
    ]);
  }));

test("deduplicates concurrent downloads", () =>
  sandbox(async (storage) => {
    const { spec, deps, count } = fixture();
    const results = await Promise.all([
      downloadServer(storage, undefined, spec, deps),
      downloadServer(storage, undefined, spec, deps),
    ]);
    assert.equal(results[0], results[1]);
    assert.equal(count(), 2);
  }));

test("checksum mismatch is never extracted or cached and can be retried", () =>
  sandbox(async (storage) => {
    const bad = fixture({ digest: `sha256:${"0".repeat(64)}` });
    bad.deps.extract = async () => {
      assert.fail("must not extract an unverified archive");
    };
    await assert.rejects(
      downloadServer(storage, undefined, bad.spec, bad.deps),
      /SHA-256/,
    );
    assert.deepEqual(await fs.readdir(path.join(storage, "servers")), []);
    const good = fixture();
    await downloadServer(storage, undefined, good.spec, good.deps);
  }));

test("rejects absent digests, wrong sizes and unexpected asset destinations", () =>
  sandbox(async (storage) => {
    for (const overrides of [
      { digest: undefined },
      { size: 99 },
      { size: 100 * 1024 * 1024 },
      { browser_download_url: "https://evil.test/server" },
    ]) {
      const { spec, deps } = fixture(overrides);
      await assert.rejects(downloadServer(storage, undefined, spec, deps));
      assert.deepEqual(await fs.readdir(path.join(storage, "servers")), []);
    }
  }));

test("network and extraction failures leave no runnable partial cache", () =>
  sandbox(async (storage) => {
    for (const phase of ["download", "extract"] as const) {
      const { spec, deps } = fixture();
      deps[phase] = async () => {
        throw new Error("fixture failure");
      };
      await assert.rejects(
        downloadServer(storage, undefined, spec, deps),
        /fixture failure/,
      );
      assert.deepEqual(await fs.readdir(path.join(storage, "servers")), []);
    }
  }));

test("repairs only an incomplete version cache and retains other versions", () =>
  sandbox(async (storage) => {
    const { spec, deps } = fixture();
    await fs.mkdir(path.join(storage, "servers", spec.directory), {
      recursive: true,
    });
    const previous = path.join(storage, "servers", "previous-version");
    await fs.mkdir(previous);
    await fs.writeFile(path.join(previous, "keep"), "unchanged");
    await downloadServer(storage, undefined, spec, deps);
    assert.equal(
      await fs.readFile(path.join(previous, "keep"), "utf8"),
      "unchanged",
    );
  }));

test("cache is version-specific", () =>
  sandbox(async (storage) => {
    const { spec, deps } = fixture();
    const directory = path.join(storage, "servers", spec.directory);
    await fs.mkdir(directory, { recursive: true });
    await fs.writeFile(
      path.join(directory, ".installed.json"),
      JSON.stringify({ version: "0.3.0", asset: spec.name }),
    );
    await downloadServer(storage, undefined, spec, deps);
    const marker = JSON.parse(
      await fs.readFile(path.join(directory, ".installed.json"), "utf8"),
    );
    assert.equal(marker.version, "0.4.1");
  }));

test("extracts real tar files and rejects symlinks before writing", () =>
  sandbox(async (root) => {
    const source = path.join(root, "source");
    const destination = path.join(root, "destination");
    await fs.mkdir(source);
    await fs.mkdir(destination);
    await fs.writeFile(path.join(source, "amlc-lsp"), "fixture");
    const archive = path.join(root, "archive.tar.gz");
    await tar.c({ file: archive, gzip: true, cwd: source }, ["amlc-lsp"]);
    await extractArchive(archive, destination, "tar.gz");
    assert.equal(
      await fs.readFile(path.join(destination, "amlc-lsp"), "utf8"),
      "fixture",
    );
    if (process.platform !== "win32") {
      await fs.symlink("/outside", path.join(source, "link"));
      await tar.c({ file: archive, gzip: true, cwd: source }, ["link"]);
      await assert.rejects(
        extractArchive(archive, destination, "tar.gz"),
        /link or special/,
      );
    }
  }));
