# Legacy compatibility patches

The default OPAM and Nix packages use the unmodified `amlc.vm` library from
AMLC commit `db1080cae60e4ffbbfa31b3f94dfbd0a974573e9`. They do not apply either
patch in this directory.

The explicitly selected Nix `legacy` environment applies
`amlc-editor-interface.patch` to that AMLC revision. It adds the old subprocess
JSON/editor contract used only as a regression baseline.
`rehovot-form-types.patch` applies separately to Lite Node compiler components
when building the opt-in `rehovot-check` regression helper. See
`THIRD_PARTY_NOTICES.md` for their sources and licenses.

The Lite Node form checker shares a source file with VM emission.
`scripts/prepare-form-check` extracts its checking section at a named boundary
and reads the call-depth limit from the same revision; missing boundaries or
constants fail the build. `rehovot-form-types.patch` connects `use` expressions
to that checker and restores the defining module's scope. It does not implement
a separate type system.

The standalone legacy helper installer requires `AMLC_LSP_LEGACY_TOOLS=1` and a
dedicated `PREFIX`. It must never be used by the default LSP package.

When updating either upstream revision, regenerate its patch from the audited
source, review the derived-code boundary, and run:

```sh
nix build .#
nix develop .#legacy --command dune build --profile legacy --force @runtest @neovim-smoke
nix develop .#legacy --command sh test/compiler-contract.sh
nix develop .#legacy --command python3 test/compiler-completion.py rehovot-check
```

Add `--benchmark` to the final command to measure helper query latency. Those
timings are informational and are not CI pass/fail gates.

Do not hand-edit patch context to make it apply to a different upstream
revision; regenerate and review the patch instead.
