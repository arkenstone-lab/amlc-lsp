# AppliedML LSP for Visual Studio Code

Language support for Applied Meta Language (AppliedML), powered by `amlc-lsp`.
The extension recognizes `.aml` files, provides basic TextMate highlighting,
and exposes the diagnostics and language features advertised by the server.

## Server setup

The extension starts `amlc-lsp` from `PATH` by default. If that fails, it checks
the active OPAM switch for an existing server. When the switch already contains
the compatible `amlc.0.1.0~preview` package but not the server, choose
**Install with OPAM** in the notification or run **AppliedML: Install Language
Server with OPAM**. After confirmation, the extension installs only
`amlc-lsp.0.3.0` from its immutable release commit and reconnects
automatically. It neither installs nor replaces AMLC.

The installer requires OPAM and AMLC to be available in the same active switch.
It stops with guidance when OPAM is unavailable, AMLC is absent, or the AMLC
version is incompatible. Set **AppliedML › Opam: Path** if the OPAM executable
is not named `opam` or is outside Visual Studio Code's `PATH`.

Nix and manual server installations remain supported. Follow the
[server installation guide](https://github.com/arkenstone-lab/amlc-lsp#install-the-server),
then set **AppliedML › Server: Path** to the absolute `amlc-lsp` executable if
Visual Studio Code cannot find it. On Windows, select `amlc-lsp.exe`. The
extension does not bundle the compiler or language server.

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
| `amlcLsp.opam.path` | OPAM executable used to find or install the server |
| `amlcLsp.dialect` | `auto`, `appliedml`, or `legacy` syntax selection |
| `amlcLsp.trace.server` | LSP message tracing in the AppliedML output channel |

Changes to the server or OPAM path, arguments, or environment restart the
server automatically.
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
