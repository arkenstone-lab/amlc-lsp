# AppliedML for Visual Studio Code

Language support for Applied Meta Language (AppliedML), powered by `amlc-lsp`.
The extension recognizes `.aml` files, provides basic TextMate highlighting,
and exposes the diagnostics and language features advertised by the server.

## Requirement

Install `amlc-lsp` before using the extension. Follow the
[server installation guide](https://github.com/arkenstone-lab/amlc-lsp#install-the-server)
for the supported OPAM, Nix, and source-install paths. The extension does not
download or bundle the compiler or language server.

The extension searches `PATH` by default. If Visual Studio Code does not inherit
the intended OPAM or Nix environment, set **AppliedML › Server: Path** to the
absolute `amlc-lsp` executable. On Windows, select `amlc-lsp.exe`.

Use **AppliedML: Show Server Information** from the Command Palette to inspect
the executable and connected version. The extension warns when the server uses
a different major.minor release line.

## Features

- Compiler-backed diagnostics and completion
- Hover, signature help, and symbol navigation
- References and guarded rename
- Quick fixes and indentation formatting
- Semantic tokens, folding, and selection ranges

Exact behavior and cross-file limits are documented in the
[server README](https://github.com/arkenstone-lab/amlc-lsp#features-and-limits).

## Settings

| Setting | Purpose |
| --- | --- |
| `amlcLsp.server.path` | Absolute server path; empty searches `PATH` |
| `amlcLsp.server.arguments` | Additional server arguments |
| `amlcLsp.server.environment` | Environment variables added to the server process |
| `amlcLsp.dialect` | `auto`, `appliedml`, or `legacy` syntax selection |
| `amlcLsp.trace.server` | LSP message tracing in the AppliedML output channel |

Changes to the path, arguments, or environment restart the server automatically.
The **AppliedML: Restart Language Server** command remains available for manual
recovery.

## Privacy and workspace support

Analysis runs locally. This extension does not send source code or telemetry to
Arkenstone Labs. Because it starts a local executable and requires ordinary
files, it is disabled for untrusted and virtual workspaces. Remote SSH, WSL, and
Codespaces run the extension and server in the remote workspace environment.

## Development

```sh
cd vscode
npm ci
npm run compile
code --extensionDevelopmentPath="$PWD"
```

Run `npm test` for the Extension Host integration test. It downloads VS Code
1.100.0 into the ignored `.vscode-test` directory and verifies activation,
diagnostics, completion, automatic restart, and version compatibility.
