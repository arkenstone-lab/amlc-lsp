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

core_symbols=$(amlc check test/fixtures/aml_program_sort4.aml --symbols=json)
case "$core_symbols" in
  *'"version":2'*'"id":"aml:Sort4:program:Sort4"'*'"kind":"form"'*'"name":"order"'*'"role":"reference"'*'"semanticTokens"'*) ;;
  *) echo "current AML Program compiler contract changed: $core_symbols" >&2; exit 1 ;;
esac

sequence_diagnostics=$(amlc check test/fixtures/aml_program_sequence.aml --diagnostics=json)
test -z "$sequence_diagnostics" || {
  echo "current AML Program sequence was rejected: $sequence_diagnostics" >&2
  exit 1
}

contract_symbols=$(rehovot-check check test/fixtures/appliedml_contract.aml --symbols=json)
case "$contract_symbols" in
  *'"version":2'*'"id":"rehovot:Token:contract:Token"'*'"kind":"function"'*'"name":"safe_add"'*'"selectionRange"'*'"occurrences"'*'"role":"reference"'*'"semanticTokens"'*'"type":"keyword"'*'"type":"function"'*) ;;
  *) echo "rehovot symbols contract changed: $contract_symbols" >&2; exit 1 ;;
esac

program_symbols=$(rehovot-check check test/fixtures/aml_program_core.aml --symbols=json)
case "$program_symbols" in
  *'"version":2'*'"id":"rehovot:Mixed:program:Mixed"'*'"kind":"form"'*'"name":"plus"'*'"signature":"plus(many left: u128, many right: u128) ->[many] u128"'*'"role":"reference"'*'"type":"function"'*) ;;
  *) echo "AML Program symbols contract changed: $program_symbols" >&2; exit 1 ;;
esac

main_symbols=$(rehovot-check check test/fixtures/aml_program_main.aml --symbols=json)
case "$main_symbols" in
  *'"kind":"form"'*'"name":"main"'*'"selectionRange"'*) ;;
  *) echo "AML Program main symbol is missing: $main_symbols" >&2; exit 1 ;;
esac

program_diagnostics=$(rehovot-check check test/fixtures/aml_program_invalid.aml --diagnostics=json || true)
case "$program_diagnostics" in
  *'"code":"REHOVOTV-signed_value_parameter"'*'"start":{"line":2,"column":12}'*) ;;
  *) echo "AML Program diagnostic location changed: $program_diagnostics" >&2; exit 1 ;;
esac

diagnostics=$(amlc check test/fixtures/legacy_invalid_lexical.aml --diagnostics=json || true)
case "$diagnostics" in
  *'"message"'*'"start"'*'"end"'*) ;;
  *) echo "amlc diagnostics contract changed: $diagnostics" >&2; exit 1 ;;
esac
