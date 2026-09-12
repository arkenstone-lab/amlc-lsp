# amlc-lsp

Compiler-backed diagnostics, completion, and code navigation for Applied Meta
Language (AppliedML) in Visual Studio Code, Zed, and Neovim. Analysis runs
locally; no RPC node is required.

The 0.3.0 server links the official AMLC library supplied by a separate `amlc`
package. OPAM source installs and Nix builds use this implementation. See the
[implementation notes](amlc_adapter/README.md) for verified support and limits.

## Install the server

Choose an installation below, connect your editor, then try the
[example](#check-that-it-works). The editor starts `amlc-lsp` for you; it is not
a terminal REPL.

### Install with OPAM

Version 0.3.0 is distributed as an OPAM-managed source installation. It depends
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
default MinGW toolchain selected during `opam init`. The 0.3.0 qualification
targets macOS, Linux, and native x86_64 Windows; other architectures are not
individually verified.

#### Create a switch

Run `opam init` once if OPAM has not been initialized, then create a dedicated
switch:

```sh
opam switch create amlc-lsp-0.3 4.14.2
```

Unix shells can activate it with:

```sh
eval "$(opam env --switch=amlc-lsp-0.3)"
```

Activation is optional for the remaining commands because they name the switch
explicitly.

#### Install 0.3.0

AMLC is not yet available from the central OPAM repository, so install the
tagged LSP source as a pin:

```sh
opam pin add amlc-lsp.0.3.0 "git+https://github.com/arkenstone-lab/amlc-lsp.git#v0.3.0" --switch=amlc-lsp-0.3
```

Accept the dependent-pin prompt. OPAM then pins the audited, unmodified AMLC
commit and installs AMLC and amlc-lsp as separate packages in the same switch.
An unrelated `amlc` executable on PATH cannot satisfy this build-time library
dependency. Because AMLC is absent from the central repository, 0.3.0 cannot be
installed with `opam install amlc-lsp` alone.

#### Verify the installation

These commands work without activating the switch:

```sh
opam list --installed amlc amlc-lsp --switch=amlc-lsp-0.3
opam exec --switch=amlc-lsp-0.3 -- amlc version
opam var bin --switch=amlc-lsp-0.3
```

The final command prints the directory containing `amlc-lsp` (or
`amlc-lsp.exe` on Windows). Launch the editor from the activated switch, or set
the editor's server path to that executable. Confirm diagnostics and completion
inside the editor; locating the executable alone does not verify the LSP
connection. Both source pins remain visible through
`opam pin list --switch=amlc-lsp-0.3`.

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

Install and compile the development extension, then launch an Extension
Development Host from the checkout:

```sh
cd vscode
npm ci
npm run compile
code --extensionDevelopmentPath="$PWD"
```

The extension uses `amlc-lsp` from PATH by default. If VS Code does not inherit
the selected OPAM or Nix environment, set `amlcLsp.server.path` to the absolute
server executable. Server launch setting changes restart the client
automatically. **AppliedML: Show Server Information** reports the active path
and version, and the extension warns when the server is from a different
major.minor release line. It also provides basic highlighting before semantic
tokens arrive. This is not yet a Visual Studio Marketplace or Open VSX release.

### Zed

1. Make the installed server available to Zed, using the same shell environment
   as the installation or the absolute-path setting below.
2. Install Rust via rustup and make the extension build target available:
   `rustup target add wasm32-wasip2`.
3. Open Zed's command palette, run `zed: install dev extension`, and select
   this checkout's **`zed/` directory**, which contains `extension.toml`.
4. Open your AppliedML project folder and an `.aml` source file.

This is a development extension, not an extension-registry release. Rust is
needed only to build the extension; the language server itself does not require
it. Zed obtains the grammar build SDK automatically.
See [Zed's extension instructions](https://zed.dev/docs/extensions/developing-extensions).

If Zed cannot find the intended server, merge this into the project's
`.zed/settings.json`, replacing the example path:

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

Install the server with OPAM or Nix as described above, then add this to
`init.lua` (or a Lua module loaded by it). This uses Neovim's built-in LSP client;
no LSP configuration plugin is required.

```lua
vim.filetype.add({ extension = { aml = "aml" } })
vim.lsp.config("amlc_lsp", {
  cmd = { "amlc-lsp" }, -- or an absolute path to the server
  init_options = { dialect = "auto" },
  filetypes = { "aml" },
  root_markers = { "project.amlp", ".git" },
})
vim.lsp.enable("amlc_lsp")
```

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

## License

This project is [BSD-3-Clause](LICENSE). Linked AMLC code and the separately
maintained legacy compiler/helper tools are covered by the notices in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Support

The addresses below accept optional donations for Arkenstone Labs' development
and maintenance of amlc-lsp. They are not Octra Labs donation addresses.

- Octra Network: `octApH51ZKHsAhJVEbppSeCmcmct4dLUxgdtBa5XdsGyogC`
- EVM: `0xe0170593c123977eA96C281BFb1a8Cd53E980Df0`
