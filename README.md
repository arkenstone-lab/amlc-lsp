# amlc-lsp

`amlc-lsp` brings compiler-backed diagnostics and AML keyword completion to
editors that support the Language Server Protocol. It supports legacy AML and
the Octra AppliedML contract dialect without using an RPC node.

## Install

Until the package is accepted into the OPAM repository, install from a source checkout:

```sh
opam switch create . 4.14.2
eval "$(opam env)"
opam install .
```

Once the package is available from the OPAM repository, install it with:

```sh
opam install amlc-lsp
```

`amlc-lsp` requires a compatible `amlc` executable on `PATH`. Set
`AMLC=/absolute/path/to/amlc` to select another executable. It must support
`amlc check file.aml --diagnostics=json`: one JSON diagnostic per stdout line,
with `message`, `severity`, and `start`/`end` positions. The server reports an
explicit diagnostic rather than guessing from human-readable compiler output.
The server still starts when the executable is absent, but reports that
compiler-backed AML diagnostics are unavailable.

For offline AppliedML contract diagnostics, also provide `rehovot-check` on
`PATH` or set `REHOVOT_CHECK=/absolute/path/to/rehovot-check`. The OPAM package
does not bundle this checker. Build the pinned helper separately when needed:

```sh
# macOS: brew install pkg-config gmp
# Debian/Ubuntu: sudo apt install pkg-config libgmp-dev
opam install zarith yojson dune
PREFIX="$HOME/.local" sh scripts/build-rehovot-check
```

Nix remains available as an optional reproducible development environment; it
is not required for installation or editor use.

### Dialect routing

By default the server detects legacy AMLC from `form`/`term` declarations and
routes contracts, current `program` files, and interfaces to AppliedML's
offline checker. Comments and strings do not affect that choice. For an
ambiguous file or a workspace that deliberately uses one dialect, set the
server dialect to `legacy`, `appliedml`, or `auto` (the default). Clients may
send it as `initializationOptions.dialect` or in
`workspace/didChangeConfiguration` as `settings.amlcLsp.dialect`.

## Editor support

### Neovim 0.11+

```lua
vim.filetype.add({ extension = { aml = "aml" } })
vim.lsp.config("amlc_lsp", {
  cmd = { "amlc-lsp" },
  init_options = { dialect = "auto" }, -- or "legacy" / "appliedml"
  filetypes = { "aml" },
  root_markers = { "project.amlp", ".git" },
  single_file_support = true,
})
vim.lsp.enable("amlc_lsp")
```

### Zed

Install `amlc-lsp` so it is on `PATH`, install the repository's `zed`
directory as a development extension, then open an `.aml` file. The extension
uses Tree-sitter for syntax highlighting and starts `amlc-lsp`.

Zed compiles a *development* extension locally. For that workflow, Cargo must
provide the `wasm32-wasip2` target (for example,
`rustup target add wasm32-wasip2`). This is not a runtime requirement for a
published extension; an extension-registry release is not published yet.

## Supported features

- Compiler-backed diagnostics for AML files whose compiler implements the JSON
  diagnostics interface.
- Push and pull diagnostics backed by the same compiler result cache.
- Offline AppliedML contract diagnostics when `rehovot-check` is installed.
- AML and AppliedML keyword completion, plus compiler-known declarations.
- Document symbols for top-level declarations.
- Hover and signature help for compiler-known declarations.
- Definition lookup for compiler-known declarations with a compiler source range.
- Declaration lookup for compiler-known declarations with a compiler source range.
- Workspace-symbol search across compiler-indexed open documents and AML projects.
- References for declarations whose compiler output includes verified occurrences.
- Safe same-document rename for declarations with verified occurrences.
- Document highlights and return-type inlay hints derived from compiler symbols.
- Brace-based folding ranges and progressively broader selection ranges.
- Semantic tokens derived from compiler-reported token roles; AMLC falls back to
  compiler-verified function declarations and calls until it supplies roles.
- Compiler-diagnostic quick fixes for unambiguous missing delimiters and keywords.
- Compiler-validated whitespace and indentation formatting for single-line strings/comments.
- Tree-sitter syntax highlighting in Zed.

Semantic highlighting uses compiler-reported token roles when available. The
legacy AMLC fallback intentionally covers only compiler-verified functions;
syntax highlighting remains the responsibility of the editor grammar.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the OCaml/opam build and test
workflow. Nix is optional.

## License

This project is [BSD-3-Clause](LICENSE). AMLC and Lite Node code used by the
optional Nix package and Rehovot checker are covered by the notices in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
