{
  description = "Local AMLC language-server development environment";

  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";

  outputs =
    { nixpkgs, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      perSystem = system:
        let
          pkgs = import nixpkgs { inherit system; };
          ocamlPackages = pkgs.ocaml-ng.ocamlPackages_4_14;
          amlcSrc = pkgs.fetchFromGitHub {
            owner = "octra-labs";
            repo = "amlc";
            rev = "db1080cae60e4ffbbfa31b3f94dfbd0a974573e9";
            hash = "sha256-rF5hDFhnmk/gJGPTN5OsKbR2Qea4CnHWuDEt1YMsi70=";
          };
          amlc = ocamlPackages.buildDunePackage rec {
            pname = "amlc";
            version = "0.1.0-preview-db1080c";
            src = amlcSrc;
            propagatedBuildInputs = with ocamlPackages; [ zarith base64 digestif ];
            doCheck = true;
          };
          legacyAmlc = amlc.overrideAttrs (_: {
            name = "amlc-legacy-checker";
            patches = [ ./patches/amlc-editor-interface.patch ];
          });
          liteNodeSrc = pkgs.fetchFromGitHub {
            owner = "octra-labs";
            repo = "lite_node";
            rev = "9e7ee19af38ba020497566ac73c268f42b20b9a4";
            hash = "sha256-K4X5UJYGFaU4V1ydc7Yy23PvWFUkyhy1d/2xLN5nA6w=";
          };
          rehovotSrc = pkgs.runCommand "rehovot-check-source" {} ''
            mkdir -p "$out"
            cp ${./rehovot}/dune "$out/dune"
            cp ${./rehovot}/dune-project "$out/dune-project"
            cp ${./rehovot}/rehovot_check.ml "$out/rehovot_check.ml"
            cp ${./rehovot}/editor_queries.ml ${./rehovot}/editor_queries.mli "$out/"
            cp ${./rehovot}/source_graph.ml ${./rehovot}/source_graph.mli "$out/"
            cp ${liteNodeSrc}/lib/vm/aml/core/c_rule.ml "$out/c_rule.ml"
            cp ${liteNodeSrc}/lib/vm/aml/core/c_nat.ml "$out/c_nat.ml"
            cp ${liteNodeSrc}/lib/vm/aml/core/c_limit.ml "$out/c_limit.ml"
            cp ${liteNodeSrc}/lib/vm/aml/core/c_text.ml "$out/c_text.ml"
            cp ${liteNodeSrc}/lib/vm/aml/analysis/c_eff.ml "$out/c_eff.ml"
            cp ${liteNodeSrc}/lib/vm/compiler/oct_lang.ml "$out/oct_lang.ml"
            cp ${liteNodeSrc}/lib/vm/compiler/oct_lex.ml "$out/oct_lex.ml"
            cp ${liteNodeSrc}/lib/vm/compiler/oct_scope.ml "$out/oct_scope.ml"
            cp ${liteNodeSrc}/lib/vm/compiler/oct_parse.ml "$out/oct_parse.ml"
            cp ${liteNodeSrc}/lib/vm/compiler/oct_types.ml ${liteNodeSrc}/lib/vm/compiler/oct_check.ml "$out/"
            cp ${liteNodeSrc}/lib/vm/compiler/aml_verify.ml "$out/aml_verify.ml"
            cp ${liteNodeSrc}/lib/vm/runtime/program_limits.ml "$out/program_limits.ml"
            sh ${./scripts/prepare-form-check} ${liteNodeSrc} "$out"
            chmod u+w "$out/oct_check.ml"
            patch --batch -d "$out" -p1 < ${./patches/rehovot-form-types.patch}
          '';
          rehovotCheck = ocamlPackages.buildDunePackage {
            pname = "rehovot_check";
            version = "1.0-rehovot-9e7ee19";
            src = rehovotSrc;
            propagatedBuildInputs = with ocamlPackages; [ zarith yojson ];
            postInstall = ''
              install -Dm644 ${./LICENSE} "$out/share/doc/rehovot-check/LICENSE"
              install -Dm644 ${./THIRD_PARTY_NOTICES.md} "$out/share/doc/rehovot-check/THIRD_PARTY_NOTICES.md"
            '';
          };
          amlcLsp = ocamlPackages.buildDunePackage {
            pname = "amlc-lsp";
            version = "0.3.0";
            src = ./.;
            buildInputs = [ ocamlPackages.yojson amlc ];
            nativeCheckInputs = [ pkgs.python3 ];
            doCheck = true;
            checkPhase = ''
              runHook preCheck
              dune build @amlc_adapter/runtest @amlc_adapter/official-lsp-smoke @test/runtest
              runHook postCheck
            '';
            postInstall = ''
              install -Dm644 nvim/plugin/amlc_lsp.lua \
                "$out/share/nvim/site/plugin/amlc_lsp.lua"
              install -Dm644 nvim/lsp/amlc_lsp.lua \
                "$out/share/nvim/site/lsp/amlc_lsp.lua"
              install -Dm644 nvim/lua/amlc_lsp/opam.lua \
                "$out/share/nvim/site/lua/amlc_lsp/opam.lua"
              install -Dm644 nvim/syntax/aml.vim \
                "$out/share/nvim/site/syntax/aml.vim"
              install -Dm644 LICENSE "$out/share/doc/amlc-lsp/LICENSE"
              install -Dm644 THIRD_PARTY_NOTICES.md \
                "$out/share/doc/amlc-lsp/THIRD_PARTY_NOTICES.md"
            '';
          };
        in
        {
          packages.default = amlcLsp;
          packages.amlc = amlc;
          packages."rehovot-check" = rehovotCheck;
          apps.default = {
            type = "app";
            program = "${amlcLsp}/bin/amlc-lsp";
          };
          apps."rehovot-check" = {
            type = "app";
            program = "${rehovotCheck}/bin/rehovot-check";
          };
          devShells.default = pkgs.mkShellNoCC {
            inputsFrom = [ amlc ];
            packages = (with ocamlPackages; [
              amlc
              dune_3
              findlib
              ocamlformat
              yojson
            ]) ++ [ pkgs.neovim pkgs.tree-sitter pkgs.python3 ];

            shellHook = ''
              echo "amlc-lsp development shell active"
              echo "amlc: $(amlc version 2>/dev/null || echo unavailable)"
              echo "run: dune build && dune exec amlc-lsp"
            '';
          };
          devShells.legacy = pkgs.mkShellNoCC {
            inputsFrom = [ legacyAmlc ];
            packages = [ legacyAmlc rehovotCheck ocamlPackages.dune_3
              ocamlPackages.findlib ocamlPackages.yojson pkgs.neovim
              pkgs.tree-sitter pkgs.python3 ];
          };
        };
    in
    {
      packages = forAllSystems (system: (perSystem system).packages);
      apps = forAllSystems (system: (perSystem system).apps);
      devShells = forAllSystems (system: (perSystem system).devShells);
    };
}
