#!/usr/bin/env sh
set -eu

workdir=$(mktemp -d "${TMPDIR:-/tmp}/amlc-lsp-contract.XXXXXX")
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT HUP INT TERM

legacy="$workdir/legacy.aml"
printf '%s\n' \
  'program Demo {' \
  '  form add [] (many value: int) ->[many] int marks {} = value' \
  '  term add(1)' \
  '}' > "$legacy"

legacy_symbols=$(amlc check "$legacy" --symbols=json)
case "$legacy_symbols" in
  *'"version":2'*'"id":"aml:Demo:program:Demo"'*'"kind":"form"'*'"name":"add"'*'"selectionRange"'*'"occurrences"'*'"role":"reference"'*'"semanticTokens"'*'"type":"keyword"'*'"type":"function"'*) ;;
  *) echo "amlc symbols contract changed: $legacy_symbols" >&2; exit 1 ;;
esac

contract_symbols=$(rehovot-check check test/fixtures/appliedml_contract.aml --symbols=json)
case "$contract_symbols" in
  *'"version":2'*'"id":"rehovot:Token:contract:Token"'*'"kind":"function"'*'"name":"safe_add"'*'"selectionRange"'*'"occurrences"'*'"role":"reference"'*'"semanticTokens"'*'"type":"keyword"'*'"type":"function"'*) ;;
  *) echo "rehovot symbols contract changed: $contract_symbols" >&2; exit 1 ;;
esac

diagnostics=$(amlc check test/fixtures/legacy_invalid_lexical.aml --diagnostics=json || true)
case "$diagnostics" in
  *'"message"'*'"start"'*'"end"'*) ;;
  *) echo "amlc diagnostics contract changed: $diagnostics" >&2; exit 1 ;;
esac
