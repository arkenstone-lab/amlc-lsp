#!/usr/bin/env sh
set -eu

tree-sitter generate
git diff --exit-code -- src/parser.c src/grammar.json src/node-types.json
tree-sitter parse --quiet test/fixtures/appliedml_contract.aml
tree-sitter parse --quiet test/fixtures/legacy_amlc.aml
tree-sitter query --grammar-path . zed/languages/aml/highlights.scm \
  test/fixtures/appliedml_contract.aml >/dev/null

# An incomplete block must remain syntactically invalid, exercising editor
# error recovery without conflating it with compiler-level type diagnostics.
if tree-sitter parse --quiet test/fixtures/tree_sitter_unclosed.aml; then
  echo "expected unclosed AppliedML block to contain a parse error" >&2
  exit 1
fi
