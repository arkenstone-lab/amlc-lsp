# Change Log

## 0.3.2

- Finds an existing `amlc-lsp` executable in the active OPAM switch when Visual
  Studio Code does not inherit the switch environment.
- Offers a confirmed OPAM installation of `amlc-lsp` when the compatible AMLC
  package is already installed, without installing or replacing AMLC.

## 0.3.1

- Clarified the Marketplace name and description to identify the extension as
  the AppliedML client for `amlc-lsp`.

## 0.3.0

- Initial Visual Studio Code client for `amlc-lsp`.
- AppliedML language registration and TextMate highlighting for `.aml` files.
- Server launch settings, automatic restart, version compatibility reporting,
  and an Extension Host integration test.
- Marketplace metadata and a temporary AppliedML LSP icon.
