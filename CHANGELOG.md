# Changelog

## 0.3.0

### Added

- Analysis through the official `amlc.vm` library, supplied by a separate,
  unmodified `amlc` package.
- Git-pinned OPAM installation for 0.3.0 while AMLC is absent from the central
  OPAM repository, plus a reproducible Nix package.
- Compiler diagnostics for saved and unsaved sources, including bounded direct
  interface imports and open-buffer dependency updates.
- Keyword, declaration, local-binding, member and enum-variant completion, with
  conservative recovery while editing incomplete statements.
- Verified hover, document symbols and navigation for functions, forms,
  constructors, locals, state fields, enums, variants, structs and named types.
- Same-file references and rename for verified symbols, plus guarded workspace
  references and rename for interface declarations, imports and `implements`
  sites.
- Typed signature help, validated missing-token quick fixes, indentation
  formatting, semantic tokens, folding and selection ranges.
- Editor clients and setup guidance for Visual Studio Code, Zed, and Neovim
  0.11, including basic VS Code TextMate highlighting, server version reporting,
  OPAM-aware server discovery, and confirmed installation from Visual Studio
  Code and Neovim without modifying AMLC.

### Fixed

- Analysis results now follow document versions, dependency changes and request
  cancellation so stale results are not returned after edits.
- Published diagnostics include their document version so clients can discard
  notifications superseded by a newer edit.
- Analysis-backed editor requests now wait for the worker's full deadline
  instead of returning an empty fallback while analysis is still running.
- Release inputs retain LF line endings on Windows checkouts so shell-based
  metadata validation remains portable.
- Native Windows coalesces burst edits, isolates bounded worker I/O, and carries
  open-buffer imports and dialect settings into each analysis worker.
- Imported-document changes recheck affected open files without invalidating
  unrelated analysis.
- Completion consistently recommends lowercase compatibility spellings, and
  rename rejects every spelling reserved by the compiler.
- Zed no longer receives duplicate automatic diagnostics.
- Zed now honors configured language-server paths, arguments, and environment
  variables before searching the worktree environment. When no local server is
  available, it installs a platform-matched server archive from the versioned
  0.3.0 GitHub release without modifying AMLC or an OPAM switch.
- Nix installations now include the Neovim OPAM integration module required by
  the packaged runtime.
- File URI handling, buffered JSON-RPC input, shutdown handling and server
  version reporting.

### Compatibility

- Default Dune, OPAM and Nix builds use the official-library server. The previous
  helper-based implementation remains only as an explicit regression baseline.
- The pinned AMLC OPAM dependency requires OCaml 4.14.2. Package metadata targets
  macOS, Linux, and native x86_64 Windows. Windows uses bounded one-shot server
  workers because OCaml's POSIX `fork` primitive is unavailable there.
- Cross-file references and rename are limited to official AMLC interface
  imports. Other indexed symbols remain same-file operations.
- Completion and signature guidance do not extend compiler syntax or suppress
  diagnostics in unfinished documents.
- Offline analysis does not validate deployment or network linking.
