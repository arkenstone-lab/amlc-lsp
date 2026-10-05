# Change Log

## 0.4.2

- Download amlc-lsp 0.4.1, built with the updated official AMLC dependency.
- Target the `v0.4.1` source tag for confirmed OPAM server installation.

## 0.4.1

- Download and verify the matching prebuilt server when no configured, PATH,
  or OPAM server is available. Cache the complete installation by version and
  platform without installing or changing AMLC or OPAM.
- Add `amlcLsp.server.autoDownload` to keep a manual-only setup.
- Validate SHA-256, archive paths and extraction sizes before running a download.
- Ignore stale installer paths and preserve explicit server configuration.
- Test downloaded servers in VS Code on all five supported host targets.
- Allow a scoped environment token for release metadata on shared networks;
  report API rate limits without forwarding credentials to assets or the server.

## 0.4.0

- Target the amlc-lsp 0.4 release line and install the server from the `v0.4.0`
  source tag when the required AMLC package is already installed.
- Expose improved compiler diagnostic locations and same-file symbol tracking
  for nested storage fields, term parameters and calls, and named types in
  `equal[Type]`.
- Keep the existing PATH and OPAM server setup. Prebuilt server downloads for
  Visual Studio Code are planned separately.

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
