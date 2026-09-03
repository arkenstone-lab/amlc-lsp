# Pinned AMLC compatibility patch

The Nix package fetches AMLC at commit
`b080a645d27a7f40369896d8bd1a85c377bea308` and applies the patches in this
order:

1. `patches/amlc-json-diagnostics.patch`
2. `patches/amlc-term-recovery.patch`
3. `patches/amlc-symbol-locations.patch`
4. `patches/amlc-symbol-occurrences.patch`

Together the patches add the JSON Lines diagnostics contract, declaration
locations, and verified direct-form occurrences that this server requires.
The recovery patch lets the compiler report multiple independent source errors
in one editor check. Treat all four patches as a compatibility layer against
that exact upstream commit; they are not an assertion that these flags exist in
an unmodified AMLC release.

When updating AMLC, rebase these changes in a dedicated fork, verify the
compiler regression suite, regenerate the patches, then run:

```sh
dune runtest
nix build .# # optional reproducible package check
```

Do not edit generated patch context whitespace mechanically: unified-diff
context may contain a required leading space on blank source lines.
