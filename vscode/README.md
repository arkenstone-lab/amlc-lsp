# AppliedML LSP for Visual Studio Code

Language support for Applied Meta Language (AppliedML), powered by `amlc-lsp`.
The extension recognizes `.aml` files, provides basic TextMate highlighting,
and exposes the diagnostics and language features advertised by the server.

## Server setup

Starting with extension 0.4.1, the client prefers `amlcLsp.server.path`, then `amlc-lsp` on
PATH or in the active OPAM switch. When none is available, it downloads the
matching 0.4.0 server from the official GitHub release. The archive includes the
compiler-linked server, GMP, corresponding source and license notices, so no
OCaml, OPAM or separate AMLC installation is required. Downloads are SHA-256
verified, bounded, and cached by version and platform in VS Code's extension
storage. Completed caches work offline and are reused on restart.

Supported hosts are macOS (Apple Silicon and Intel), Linux (ARM64 and x86_64),
and x86_64 Windows. Remote SSH, WSL and Codespaces use the remote host platform.
Linux archives target glibc, not Alpine/musl. Unsupported platforms or restricted
networks require a local server. Set `amlcLsp.server.autoDownload` to `false` to
disable automatic downloads. A broken configured or existing server is reported
rather than silently replaced; existing local servers require manual upgrades.

For an OPAM-based setup, run **AppliedML: Install Language Server with OPAM**.
After confirmation, the extension installs only
`amlc-lsp.0.4.0` from its versioned release tag and reconnects
automatically. It neither installs nor replaces AMLC.

The installer requires OPAM and AMLC to be available in the same active switch.
For 0.4.0, install AMLC from the audited `1f24fa97` source commit. Older source
pins may share the `0.1.0~preview` version but expose an incompatible library
API. Use the linked manual installation guide to update that pin or an existing
server; automatic discovery keeps an existing executable.
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
| `amlcLsp.server.path` | Explicit server path; empty uses local discovery then download |
| `amlcLsp.server.autoDownload` | Download a prebuilt server when none is available (default: true) |
| `amlcLsp.server.arguments` | Additional server arguments |
| `amlcLsp.server.environment` | Environment variables added to the server process |
| `amlcLsp.opam.path` | OPAM executable used to find or install the server |
| `amlcLsp.dialect` | `auto`, `appliedml`, or `legacy` syntax selection |
| `amlcLsp.trace.server` | LSP message tracing in the AppliedML output channel |

Changes to the server or OPAM path, automatic-download setting, arguments, or environment restart the
server automatically.
The **AppliedML: Restart Language Server** command remains available for manual
recovery.

## Privacy and workspace support

Analysis runs locally. This extension does not send source code or telemetry to
Arkenstone Labs. Automatic setup contacts GitHub for public release metadata
and the platform archive; it does not upload workspace contents. Because it
starts a local executable and requires ordinary
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

For the optional real-download test, run `AMLC_PREBUILT_TEST=1 npm test`.
The runner creates and cleans up a fresh isolated profile. It disables PATH and OPAM
discovery, verifies the downloaded compiler-backed server's editor features,
and checks cache reuse on restart. The separate downloaded-server CI job runs
this test on all five supported host targets and preserves Extension Host logs.
It requires public release assets and GitHub connectivity; the regular
extension tests continue to use a local fixture server.

GitHub's anonymous API rate limit is shared by clients on the same public IP.
CI uses its read-only workflow token for release metadata. On restricted shared
networks, optionally set `AMLC_LSP_GITHUB_TOKEN` in the extension host's environment
before launching VS Code. It is used only for this repository's pinned release
metadata request, never for archive downloads or asset redirects, and is not
passed to the language server. No token is
needed for normal setup, and the extension does not request GitHub sign-in.
