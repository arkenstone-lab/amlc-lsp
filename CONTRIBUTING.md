# Contributing

## Prerequisites

Contributors need:

- OCaml 4.14.2 or newer and opam
- Neovim for the integration smoke test

Create a project-local switch and install the package dependencies:

```sh
opam switch create . 4.14.2
eval "$(opam env)"
opam install . --deps-only --with-test
```

To exercise real AML diagnostics, provide a compatible `amlc` on `PATH` or set
`AMLC`. To exercise AppliedML diagnostics, build `rehovot-check` with the
README helper; it requires `pkg-config`, GMP development files, Git, and the
`zarith`/`yojson` OPAM packages.

Nix is optional. `nix develop` provides the same pinned compiler, checker,
OCaml/Dune, Neovim, and Tree-sitter tooling in one shell for contributors who
already use Nix.

## Validation

Run the OCaml tests before opening a pull request:

```sh
dune runtest
```

This includes protocol tests and a headless Neovim smoke test. If you modify
the grammar, install the Tree-sitter CLI and also run:

```sh
tree-sitter generate
sh test/tree-sitter-fixtures.sh
```

For the reproducible package check, optionally run:

```sh
nix build .#
```

## Pull requests

- Keep changes focused and include regression coverage when behaviour changes.
- Preserve the LSP/AMLC boundary: do not add text-scanned refactors or semantic
  editor features without compiler-provided symbol IDs and ranges.
- Update README when user-visible behaviour changes.
- Do not commit build artefacts, local profiles, or credentials.

Report a reproducible bug with the AML source, expected behaviour, actual
behaviour, and Neovim/LSP version where relevant.
