# Pinned AMLC compatibility patch

The Nix package fetches AMLC at commit
`db1080cae60e4ffbbfa31b3f94dfbd0a974573e9` and applies
`patches/amlc-editor-interface.patch`.

The patch adds the JSON Lines diagnostics contract, declaration locations,
verified direct-form occurrences, semantic tokens, and project metadata that
this server requires. Its editor recovery entry point is separate from AMLC's
strict parser, so the upstream parser and regression contracts remain intact.
Treat it as a compatibility layer against that exact upstream commit; it is not
an assertion that these flags exist in an unmodified AMLC release.

When updating AMLC, rebase these changes in a dedicated fork, verify the
compiler regression suite, regenerate the patches, then run:

```sh
dune runtest
nix build .# # optional reproducible package check
```

Do not edit generated patch context whitespace manually: unified-diff
context may contain a required leading space on blank source lines.
