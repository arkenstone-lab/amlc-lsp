# amlc-lsp

Compiler-backed diagnostics, completion, and code navigation for Applied Meta
Language (AppliedML) in Visual Studio Code, Zed, and Neovim. Analysis runs
locally; no RPC node is required.

The 0.4.1 server links the official AMLC library supplied at build time by a
separate `amlc` package. OPAM source installs and Nix builds use this
implementation. Prebuilt native server archives contain the resulting linked
server and do not require an OPAM switch or an `amlc` executable at runtime.
See the [implementation notes](amlc_adapter/README.md) for verified support and
limits.

## Install the server

Choose an installation below, connect your editor, then try the
[example](#check-that-it-works). The editor starts `amlc-lsp` for you; it is not
a terminal REPL.

### Install with OPAM

Version 0.4.1 is distributed as an OPAM-managed source installation. It depends
on the separate `amlc.0.1.0~preview` package and links that package's public
`amlc.vm` library. It does not bundle or install a private compiler or the
legacy `rehovot-check` helper.

#### Requirements

- OPAM 2.x
- a C build toolchain, `pkg-config`, and GMP development headers
- OCaml 4.14.2 exactly, as required by the pinned AMLC package

System package names vary by platform and Linux distribution. For example,
Homebrew users on macOS can run `brew install pkg-config gmp`, while
Debian/Ubuntu users can run
`sudo apt install build-essential pkg-config libgmp-dev`. On other Linux
distributions, install the equivalent compiler, `pkg-config`, and GMP development
packages with the system package manager.

On native x86_64 Windows, install OPAM with its
[official Windows installer](https://opam.ocaml.org/doc/Install.html) and use the
default MinGW toolchain selected during `opam init`. The 0.4.1 qualification
targets macOS, Linux, and native x86_64 Windows; other architectures are not
individually verified.

#### Create a switch

Run `opam init` once if OPAM has not been initialized, then create a dedicated
switch:

```sh
opam switch create amlc-lsp-0.4 4.14.2
```

Unix shells can activate it with:

```sh
eval "$(opam env --switch=amlc-lsp-0.4)"
```

Activation is optional for the remaining commands because they name the switch
explicitly.

#### Install 0.4.1

AMLC is not yet available from the central OPAM repository, so install the
tagged LSP source as a pin:

```sh
opam pin add amlc-lsp.0.4.1 "git+https://github.com/arkenstone-lab/amlc-lsp.git#v0.4.1" --switch=amlc-lsp-0.4
```

Accept the dependent-pin prompt. OPAM then pins the audited, unmodified AMLC
commit and installs AMLC and amlc-lsp as separate packages in the same switch.
For 0.4.1, the audited AMLC commit is `f3a2924`. Older AMLC commits can use
the same `0.1.0~preview` version string but expose a different library API;
when upgrading, accept the dependent-pin update in this manual installation.
An unrelated `amlc` executable on PATH cannot satisfy this build-time library
dependency. Because AMLC is absent from the central repository, 0.4.1 cannot be
installed with `opam install amlc-lsp` alone.

#### Verify the installation

These commands work without activating the switch:

```sh
opam list --installed amlc amlc-lsp --switch=amlc-lsp-0.4
opam exec --switch=amlc-lsp-0.4 -- amlc version
opam var bin --switch=amlc-lsp-0.4
```

The final command prints the directory containing `amlc-lsp` (or
`amlc-lsp.exe` on Windows). Launch the editor from the activated switch, or set
the editor's server path to that executable. Confirm diagnostics and completion
inside the editor; locating the executable alone does not verify the LSP
connection. Both source pins remain visible through
`opam pin list --switch=amlc-lsp-0.4`.

### Build with Nix

The default Nix package builds against the unmodified AMLC library. It does not
install a private compiler/helper or set executable overrides.

From the checkout root, with Nix flakes enabled:

```sh
nix build .#
```

Use the absolute path to `result/bin/amlc-lsp` as your editor's server executable.
Keep the checkout and build output available while using that path. To use the
separate AMLC command as well, enter `nix shell .#amlc .#default` from the checkout.
The LSP does not need to launch that command for analysis.

This builds locally; it does not install into your global Nix profile.
The flake declares `aarch64-darwin` and `x86_64-linux` packages.
Nix uses its pinned OCaml 4.14 package set rather than OPAM's solver; the upstream
OPAM constraint of exactly 4.14.2 still applies to OPAM installations.

## Connect your editor

### Visual Studio Code

Install **AppliedML LSP** from the
[Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=arkenstone-labs.appliedml)
or [Open VSX](https://open-vsx.org/extension/arkenstone-labs/appliedml). For
Visual Studio Code, it can also be installed from the command line:

```sh
code --install-extension arkenstone-labs.appliedml
```

For a manual installation, download `appliedml-lsp-0.4.2.vsix` from the
[v0.4.1 release](https://github.com/arkenstone-lab/amlc-lsp/releases/tag/v0.4.1)
and run **Extensions: Install from VSIX**. The Visual Studio Code client is
versioned independently at the patch level and does not bundle the server or
compiler.

Starting with extension 0.4.1, the client prefers an explicitly configured server, then one
on PATH or in the active OPAM switch. If none is available, it downloads the
matching 0.4.1 server archive from GitHub Releases into VS Code's extension
storage. It verifies the release asset's SHA-256 before extracting and running
it, preserving the bundled libraries, corresponding GMP source and license
notices. No OCaml, OPAM or separate AMLC installation is needed for this path.
macOS (Apple Silicon and Intel), Linux (ARM64 and x86_64), and x86_64 Windows
are supported. Remote workspaces download for the extension host's platform.
Set `amlcLsp.server.autoDownload` to `false` for a manual-only setup.

Alternatively, when an OPAM switch already contains `amlc.0.1.0~preview`, run
**AppliedML: Install Language Server with OPAM**. After
confirmation, the extension installs only `amlc-lsp.0.4.1` from the versioned
`v0.4.1` release tag. It does not install, replace, or repin AMLC. It then records
the server's absolute path and reconnects automatically. Use the manual source
installation above to upgrade an older server or AMLC source pin; automatic
discovery keeps an existing executable.

Set `amlcLsp.opam.path` when the OPAM executable is not available as `opam`. Nix
and other manual installations can instead set `amlcLsp.server.path` to the
absolute server executable. Server launch setting changes restart the client
automatically. **AppliedML: Show Server Information** reports the active path
and version, and the extension warns when the server is from a different
major.minor release line. It also provides basic highlighting before semantic
tokens arrive.

### Zed

Once the AppliedML extension is available in Zed's extension registry, install
it from **zed: extensions**. The extension honors an explicitly configured
server first, then an `amlc-lsp` executable already on `PATH`. Otherwise it
downloads the matching 0.4.1 server release on macOS (Apple Silicon or Intel),
Linux (AArch64 or x86_64), and x86_64 Windows. The archive includes the exact
corresponding GMP source and third-party notices alongside the dynamically
linked GMP library. macOS and Linux archives carry the upstream GMP source;
the Windows archive carries the official MSYS2 6.3.0-2 source archive, including
its packaging recipe and patches. The extension does not modify an OPAM switch
or an AMLC installation.

To load this checkout as a development extension:

1. Install Rust via rustup and make the extension build target available:
   `rustup target add wasm32-wasip2`.
2. Open Zed's command palette, run `zed: install dev extension`, and select
   this checkout's **`zed/` directory**, which contains `extension.toml`.
3. Open your AppliedML project folder and an `.aml` source file.

The numbered steps load a development extension rather than the registry
release. Rust is needed only for that development build; the language server
itself does not require it. Zed obtains the grammar build SDK automatically.
See [Zed's extension instructions](https://zed.dev/docs/extensions/developing-extensions).

To force a particular local server, merge this into the project's
`.zed/settings.json` and replace the example path:

```json
{
  "lsp": {
    "amlc-lsp": {
      "binary": {
        "path": "/absolute/path/to/amlc-lsp"
      }
    }
  }
}
```

For the Nix build, the path ends in `result/bin/amlc-lsp`. For OPAM, use the
platform-specific path described in the installation section. Do not overwrite
unrelated project settings. Windows paths may use forward slashes in this JSON,
for example `C:/path/to/amlc-lsp.exe`.

### Neovim 0.11+

The `nvim/` runtime in this repository provides the language configuration and
OPAM integration. Add that directory to `runtimepath` from `init.lua`, replacing
the example with the location of your checkout:

```lua
vim.opt.runtimepath:prepend("/absolute/path/to/amlc-lsp/nvim")
```

The runtime uses `amlc-lsp` from `PATH`, or `opam exec -- amlc-lsp` when only
OPAM is visible. If the active or project-local switch already contains
`amlc.0.1.0~preview` but not the server, run `:AmlcLspInstall`. Neovim asks for
confirmation, installs `amlc-lsp.0.4.1` from the versioned release tag, and
reconnects. The command refuses missing or incompatible AMLC and uses
`--ignore-pin-depends`, so it never installs, replaces, or repins AMLC. Set
`vim.g.amlc_lsp_opam_path` before adding the runtime when the OPAM executable
has a nonstandard name or location.

Use the manual source installation above when upgrading an older server or
AMLC source pin. The installer checks AMLC's package version; it does not
upgrade a same-version compiler from an older source commit.

For a configuration without the repository runtime, install the server
manually and use the built-in LSP snippet from `nvim/lsp/amlc_lsp.lua`.
Open an `.aml` file and run `:checkhealth vim.lsp` to check the client
connection.

## Check that it works

Create `example.aml` in your project folder:

```aml
program Example {
  private fn increment(n: int): int {
    return n + 1
  }
  fn run(): int {
    return increment(1)
  }
}
```

With the default dialect setting:

1. The complete example should have no diagnostics.
2. Request completion: the declared function `increment` should be offered.
3. Use your editor's Go to Definition action on the `increment` call:
   it should select the function declaration.
4. Replace that call's argument with `true`: a type-mismatch diagnostic should
   appear. Restore `1`: the diagnostic should disappear without saving.

See [Use the LSP features](#use-the-lsp-features) for editor commands.

For an OPAM installation, check the separate compiler with:

```sh
opam exec -- amlc version
```

This checks the dependency, not the LSP connection. Confirm diagnostics and
completion in the editor too; highlighting alone does not confirm a connection.

## Use the LSP features

Use your editor's LSP actions with the cursor on the relevant symbol. For the
example above, Neovim's built-in completion is available with `Ctrl-X Ctrl-O`
in Insert mode, and definition lookup with `:lua vim.lsp.buf.definition()`.
In Zed, use the completion and Go to Definition actions.

For editor actions and key bindings, see
[Neovim's LSP documentation](https://neovim.io/doc/user/lsp.html) or
[Zed's language features](https://zed.dev/docs/languages).

References and rename operate on verified occurrences in the current checked
file. For official AMLC interfaces, they also connect the declaration with
matching `import` and `implements` occurrences across the workspace. Quick fixes
are offered only for a small set of compiler-reported missing tokens and are
rechecked before being returned. Formatting adjusts indentation without
rewriting expressions.

## Features and limits

- Official compiler diagnostics, including direct interface imports and unsaved
  dependencies.
- Keyword and declaration completion, plus scoped parameters and local bindings,
  with bounded recovery for unfinished statements.
- Member completion for `self` storage fields/struct paths, collection `length`
  properties, indexed state paths, and enum variants. Root state-list statements
  also offer typed `push`, `delete`, `len` and `pop` methods.
- Document symbols, verified hover, and same-file definition/declaration,
  references and rename, including root state fields and enum/struct types.
- Guarded workspace references and rename for official AMLC interface
  declarations, matching imports and `implements` sites. Incomplete scans can
  return verified references but never authorize rename.
- Validated quick fixes for compiler-reported missing delimiters and selected
  required keywords; stale or fabricated diagnostics do not produce edits.
- Typed signature help for user functions and forms, including unfinished/nested
  calls and explicit form capture/argument lists.
- Indentation formatting for checked callable and term code, preserving strings,
  comments and line endings.
- Semantic highlighting of verified declarations and uses; unindexed syntax
  retains the editor's grammar highlighting.
- Folding and selection ranges; editor Tree-sitter highlighting remains
  independent.

Offline diagnostics are not a deployment or VM-verification guarantee.
See the [implementation notes](amlc_adapter/README.md) for the detailed contracts
and current limits.

## Configuration

Normally leave `initializationOptions.dialect` at `auto`. The explicit values
`legacy` and `appliedml` select term and callable syntax in official AMLC; these
are compatibility setting names, not separate language names. Neovim's
`init_options` above exposes that setting. Configuration notifications may also
set `settings.amlcLsp.dialect`. Comments and strings do not affect auto routing;
ambiguous form-only AMLC files may need `legacy`.

The server uses the AMLC library selected at build time; it does not invoke an
`amlc` executable found on PATH.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the build, test, and implementation
workflow, and [CHANGELOG.md](CHANGELOG.md) for user-visible changes.

## Release preparation

Keep release history in [CHANGELOG.md](CHANGELOG.md) and GitHub Releases, without
a separate release-notes file. Use `v0.4.1` as the GitHub release title, matching
the previous releases. Write the Markdown body when preparing the GitHub release,
following the 0.3.0 structure: a short introduction, Highlights, Install the
server, Visual Studio Code, and Current limits. Include the compiler-pin upgrade
instructions and the status of Zed distribution where relevant.

Before publishing 0.4.1:

1. Finish the release PR and require all platform checks to pass on the final
   commit, including the release documentation changes.
2. Merge the release preparation and create `v0.4.1` at the merged commit. Never
   move a published version tag: the editor source installers use that tag.
3. Create a draft GitHub release using that format. Run **Publish
   Zed server assets** with `release_tag: v0.4.1` to build and attach the five
   tagged server archives.
4. Attach `appliedml-lsp-0.4.2.vsix` from the `appliedml-vsix` artifact of a
   successful CI run for the tagged source. Inspect the draft's files and
   confirm that its server archives passed tests before publishing the release.
5. After the server release is public, rerun its tag-triggered CI and require
   the live download matrix to pass. Publish the VS Code extension to the
   Visual Studio Marketplace and Open VSX, and submit the Zed registry update
   for the released extension revision.
6. Verify installation through each editor's published distribution. Neovim
   users update this repository runtime and use the source installation guide
   to upgrade an existing server.

## License

This project is [BSD-3-Clause](LICENSE). Linked AMLC code and the separately
maintained legacy compiler/helper tools are covered by the notices in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Support

The addresses below accept optional donations for Arkenstone Labs' development
and maintenance of amlc-lsp. They are not Octra Labs donation addresses.

- Octra Network: `octApH51ZKHsAhJVEbppSeCmcmct4dLUxgdtBa5XdsGyogC`
- EVM: `0xe0170593c123977eA96C281BFb1a8Cd53E980Df0`
