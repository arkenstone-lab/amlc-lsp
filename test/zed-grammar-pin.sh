#!/usr/bin/env sh
set -eu

repository=$(sed -n 's/^repository = "\(.*\)"$/\1/p' zed/extension.toml | tail -n 1)
commit=$(sed -n 's/^commit = "\(.*\)"$/\1/p' zed/extension.toml)

if [ -z "$repository" ] || [ -z "$commit" ]; then
  echo "could not read the Zed grammar repository and commit" >&2
  exit 1
fi

checkout=$(mktemp -d "${TMPDIR:-/tmp}/amlc-lsp-zed-grammar.XXXXXX")
trap 'rm -rf "$checkout"' EXIT HUP INT TERM

git -C "$checkout" init --quiet
git -C "$checkout" fetch --quiet --depth 1 "$repository" "$commit"
git -C "$checkout" checkout --quiet FETCH_HEAD

tree-sitter query --grammar-path "$checkout" \
  "$(pwd)/zed/languages/aml/highlights.scm" \
  "$(pwd)/test/fixtures/appliedml_contract.aml" >/dev/null
