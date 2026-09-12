import * as assert from "node:assert/strict";
import * as path from "node:path";
import { test } from "node:test";
import type { CommandResult } from "../../src/opamInstaller";
import {
  findInstalledServerWithOpam,
  installServerWithOpam,
  OpamInstallError,
} from "../../src/opamInstaller";

const success = (stdout = ""): CommandResult => ({
  code: 0,
  stdout,
  stderr: "",
});

test("finds an existing server in the active OPAM switch", async () => {
  const executable = path.join(
    "/opam/bin",
    process.platform === "win32" ? "amlc-lsp.exe" : "amlc-lsp",
  );
  const found = await findInstalledServerWithOpam(
    {
      command: "opam",
      workingDirectory: "/workspace",
    },
    {
      run: async (_command, args, _environment, workingDirectory) => {
        assert.deepEqual(args, ["var", "bin"]);
        assert.equal(workingDirectory, "/workspace");
        return success("/opam/bin\n");
      },
      executableExists: async (candidate) => candidate === executable,
    },
  );
  assert.equal(found, executable);
});

test("installs only the LSP when the required AMLC is present", async () => {
  const calls: string[][] = [];
  let installed = false;
  const executable = path.join(
    "/opam/bin",
    process.platform === "win32" ? "amlc-lsp.exe" : "amlc-lsp",
  );
  const result = await installServerWithOpam(
    { command: "opam" },
    () => undefined,
    {
      run: async (_command, args) => {
        calls.push(args);
        if (args[0] === "show") {
          return success("0.1.0~preview\n");
        }
        if (args[0] === "pin") {
          installed = true;
          return success();
        }
        return success("/opam/bin\n");
      },
      executableExists: async () => installed,
    },
  );

  assert.equal(result, executable);
  assert.deepEqual(calls[1], [
    "show",
    "--field=installed-version",
    "amlc",
  ]);
  assert.deepEqual(calls[2], [
    "pin",
    "add",
    "--yes",
    "--ignore-pin-depends",
    "amlc-lsp.0.3.0",
    "git+https://github.com/arkenstone-lab/amlc-lsp.git#34d5c62c5e45687a0b0bd384d79657621b2deb12",
  ]);
});

test("does not install when AMLC is absent", async () => {
  await assert.rejects(
    installServerWithOpam({ command: "opam" }, () => undefined, {
      run: async (_command, args) =>
        args[0] === "show"
          ? { code: 1, stdout: "", stderr: "not installed" }
          : success("/opam/bin\n"),
      executableExists: async () => false,
    }),
    (error: unknown) =>
      error instanceof OpamInstallError && error.kind === "amlc-missing",
  );
});

test("reports an unavailable OPAM executable", async () => {
  await assert.rejects(
    installServerWithOpam({ command: "missing-opam" }, () => undefined, {
      run: async () => {
        throw new Error("ENOENT");
      },
      executableExists: async () => false,
    }),
    (error: unknown) =>
      error instanceof OpamInstallError && error.kind === "opam-missing",
  );
});

test("does not replace an incompatible AMLC package", async () => {
  const calls: string[][] = [];
  await assert.rejects(
    installServerWithOpam({ command: "opam" }, () => undefined, {
      run: async (_command, args) => {
        calls.push(args);
        return args[0] === "show"
          ? success("0.2.0\n")
          : success("/opam/bin\n");
      },
      executableExists: async () => false,
    }),
    (error: unknown) =>
      error instanceof OpamInstallError && error.kind === "amlc-incompatible",
  );
  assert.equal(calls.some((args) => args[0] === "pin"), false);
});
