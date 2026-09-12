# Contributing

## Prerequisites

Contributors need:

- OCaml 4.14.2 and opam on Linux, macOS, or native x86_64 Windows (the current
  AMLC OPAM constraint)
- Neovim 0.11+ and Python 3 for integration tests

Create a project-local switch and install the package dependencies:

```sh
opam switch create . 4.14.2
eval "$(opam env)"
opam install . --with-test
```

The `eval` line is for Unix shells. Native Windows contributors can run the
remaining commands directly and locate installed tools under `opam var bin`.

The package's `pin-depends` entry selects the audited official AMLC commit for
source pins and checkout installs. It does not patch or privately bundle the
compiler, and it has no effect after publication through an OPAM repository.
Run the library-backed server with:

```sh
dune exec amlc-lsp
```

Alternatively, `nix develop` provides unmodified AMLC, OCaml/Dune, Neovim,
Python and Tree-sitter tooling. The old helper and patched compiler are available
only in `nix develop .#legacy` for regression work. Default Dune builds select
the official-library server; the old launcher requires `--profile legacy`.

## Validation

Run the OCaml tests before opening a pull request:

```sh
dune build @amlc_adapter/runtest @amlc_adapter/official-lsp-smoke @test/runtest
```

This tests the adapter, real LSP requests and protocol behavior without launching
an external compiler. The unmodified `amlc.vm` library must be available.

After `opam install .`, verify the installed server and separate dependency without
relying on compiler executables from PATH:

```sh
python3 amlc_adapter/install_test.py "$(opam var prefix)" --dependency-switch
```

Test the current server with Neovim, then the previous server separately as a
regression baseline (the latter is not evidence of current feature parity):

```sh
nix develop --command dune build @neovim-smoke
nix develop .#legacy --command dune build --profile legacy @neovim-smoke
```

For legacy helper cursor queries (local/member completion and imported definitions), run:

```sh
nix develop .#legacy --command python3 test/compiler-completion.py rehovot-check
```

See [PATCHES.md](PATCHES.md) before changing the pinned legacy sources or their
derived patches.

When new files are still untracked, use `nix develop path:.` so Nix includes them.

If you modify the grammar, install the Tree-sitter CLI and also run:

```sh
tree-sitter generate
sh test/tree-sitter-fixtures.sh
```

For Zed extension changes, also check the pinned grammar and build the extension
with Rust's `wasm32-wasip2` target installed:

```sh
nix develop --command sh test/zed-grammar-pin.sh
cargo build --manifest-path zed/Cargo.toml --locked --target wasm32-wasip2 --target-dir _build/zed-target
```

For Visual Studio Code extension changes, type-check and build the bundled
client from its locked dependency graph:

```sh
cd vscode
npm ci
npm test
```

The test downloads a matching VS Code runtime into `vscode/.vscode-test` and
checks activation, diagnostics, completion, launch-setting restart, and version
compatibility. CI runs it on Linux, macOS, and Windows and preserves the Linux
VSIX for inspection.

For the reproducible package check, optionally run:

```sh
nix build .#
nix develop --command python3 amlc_adapter/install_test.py result --nix
```

## Release qualification

Pull requests install the checkout directly. Pushes to `main` run the native
OPAM matrix on Linux, macOS, and native x86_64 Windows against the public Git
commit, allowing that exact SHA to qualify before tagging. Tags matching `v*`
repeat the installation through the public tag URL and must match the package
version. Publish the GitHub release only after those checks pass.

Keep the legacy regression environment until the official adapter has shipped
through at least one stable release and every failure unique to the legacy suite
has equivalent official-library coverage. Real project fixtures must have clear
redistribution terms; do not copy deployed source into the test suite without
permission.

## Pull requests

- Keep changes focused and include regression coverage when behaviour changes.
- Preserve the LSP/compiler boundary: do not add text-scanned refactors or semantic
  editor features without compiler-provided symbol IDs and ranges.
- Update README when user-visible behaviour changes.
- Do not commit build artefacts, local profiles, or credentials.

Report a reproducible bug with the AppliedML source, expected behaviour, actual
behaviour, and Neovim/LSP version where relevant.
