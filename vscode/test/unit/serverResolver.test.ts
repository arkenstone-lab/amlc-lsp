import * as assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import {
  executableExists,
  findServerOnPath,
  serverEnvironment,
  resolveServer,
  type ResolutionDependencies,
} from "../../src/serverResolver";

test("discovers an executable on PATH and ignores missing locations", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "amlc-path-test-"));
  try {
    const executable = path.join(
      directory,
      process.platform === "win32" ? "amlc-lsp.exe" : "amlc-lsp",
    );
    await fs.writeFile(executable, "fixture", { mode: 0o755 });
    const environment = {
      PATH: [path.join(directory, "missing"), directory].join(path.delimiter),
    };
    assert.equal(await findServerOnPath(environment), executable);
    assert.equal(await executableExists(directory), false);
    assert.equal(await findServerOnPath({ PATH: "" }), undefined);
    if (process.platform === "win32") {
      assert.equal(
        await findServerOnPath(
          serverEnvironment({ Path: directory }, { PATH: "" }),
        ),
        undefined,
      );
    }
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});

test("Windows environment overrides collapse case-insensitive keys", () => {
  assert.deepEqual(
    serverEnvironment(
      { Path: "/system", SYSTEMROOT: "/windows" },
      { PATH: "", SystemRoot: "/custom" },
      "win32",
    ),
    { PATH: "", SYSTEMROOT: "/custom" },
  );
  assert.deepEqual(
    serverEnvironment({ PATH: "/system" }, { Path: "/custom" }, "win32"),
    { PATH: "/custom" },
  );
  assert.deepEqual(
    serverEnvironment({ PATH: "/system" }, { Path: "/custom" }, "linux"),
    { PATH: "/system", Path: "/custom" },
  );
});

test("download credentials are not passed to the language server", () => {
  for (const platform of ["win32", "darwin", "linux"]) {
    assert.equal(
      serverEnvironment({ AMLC_LSP_GITHUB_TOKEN: "test-token" }, {}, platform)
        .AMLC_LSP_GITHUB_TOKEN,
      undefined,
    );
  }
});

function fixture(path?: string, opam?: string) {
  const calls: string[] = [];
  const deps: ResolutionDependencies = {
    findPath: async () => {
      calls.push("path");
      return path;
    },
    findOpam: async () => {
      calls.push("opam");
      return opam;
    },
    exists: async () => {
      calls.push("exists");
      return true;
    },
    download: async () => {
      calls.push("download");
      return "/downloaded/server";
    },
  };
  return { deps, calls };
}

test("explicit configuration bypasses discovery and downloads even if broken", async () => {
  const { deps, calls } = fixture();
  assert.equal(
    await resolveServer(
      { configured: "/custom/server", autoDownload: true },
      deps,
    ),
    "/custom/server",
  );
  assert.deepEqual(calls, []);
});
test("PATH wins over OPAM and cached installers", async () => {
  const { deps, calls } = fixture("/path/server", "/opam/server");
  assert.equal(
    await resolveServer(
      { remembered: "/remembered/server", autoDownload: true },
      deps,
    ),
    "/path/server",
  );
  assert.deepEqual(calls, ["path"]);
});
test("OPAM wins over remembered paths and downloads", async () => {
  const { deps, calls } = fixture(undefined, "/opam/server");
  assert.equal(
    await resolveServer(
      { remembered: "/remembered/server", autoDownload: true },
      deps,
    ),
    "/opam/server",
  );
  assert.deepEqual(calls, ["path", "opam"]);
});
test("valid manually installed paths remain usable without downloading", async () => {
  const { deps, calls } = fixture();
  assert.equal(
    await resolveServer(
      { remembered: "/remembered/server", autoDownload: true },
      deps,
    ),
    "/remembered/server",
  );
  assert.deepEqual(calls, ["path", "opam", "exists"]);
});
test("stale remembered paths fall back to a matching download", async () => {
  const { deps, calls } = fixture();
  deps.exists = async () => false;
  assert.equal(
    await resolveServer(
      { remembered: "/missing/server", autoDownload: true },
      deps,
    ),
    "/downloaded/server",
  );
  assert.deepEqual(calls, ["path", "opam", "download"]);
});
test("disabling automatic download performs no network installation", async () => {
  const { deps, calls } = fixture();
  await assert.rejects(
    resolveServer({ autoDownload: false }, deps),
    /disabled/,
  );
  assert.deepEqual(calls, ["path", "opam"]);
});
test("unavailable servers are downloaded once resolution needs them", async () => {
  const { deps, calls } = fixture();
  assert.equal(
    await resolveServer({ autoDownload: true }, deps),
    "/downloaded/server",
  );
  assert.deepEqual(calls, ["path", "opam", "download"]);
});
