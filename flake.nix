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
          amlcSrc = pkgs.applyPatches {
            name = "amlc-lsp-amlc-source";
            src = pkgs.fetchFromGitHub {
              owner = "octra-labs";
              repo = "amlc";
              rev = "b080a645d27a7f40369896d8bd1a85c377bea308";
              hash = "sha256-0wzRKVfs2PauYTu/iUSG8WV64cJil4KJ5oAd4Ieq4Ic=";
            };
            patches = [
              ./patches/amlc-json-diagnostics.patch
              ./patches/amlc-term-recovery.patch
              ./patches/amlc-symbol-locations.patch
              ./patches/amlc-symbol-occurrences.patch
              ./patches/amlc-semantic-tokens.patch
            ];
          };
          amlc = ocamlPackages.buildDunePackage rec {
            pname = "amlc";
            version = "0.1.0-preview-b080a645";
            src = amlcSrc;
            propagatedBuildInputs = with ocamlPackages; [ zarith base64 digestif ];
            doCheck = true;
          };
          liteNodeSrc = pkgs.fetchFromGitHub {
            owner = "octra-labs";
            repo = "lite_node";
            rev = "c54167b827ede56b20d94608f8d3a9f5fa138c09";
            hash = "sha256-rPdmCJ6lS4iZiXI+OAJKFny4YhvhtBmjFNO+x/ImXKE=";
          };
          rehovotSrc = pkgs.runCommand "rehovot-check-source" {} ''
            mkdir -p "$out"
            cp ${./rehovot}/dune "$out/dune"
            cp ${./rehovot}/dune-project "$out/dune-project"
            cp ${./rehovot}/rehovot_check.ml "$out/rehovot_check.ml"
            cp ${liteNodeSrc}/lib/vm/compiler/oct_lang.ml "$out/oct_lang.ml"
            cp ${liteNodeSrc}/lib/vm/compiler/oct_lex.ml "$out/oct_lex.ml"
            cp ${liteNodeSrc}/lib/vm/compiler/oct_parse.ml "$out/oct_parse.ml"
            cp ${liteNodeSrc}/lib/vm/compiler/aml_verify.ml "$out/aml_verify.ml"
            cp ${liteNodeSrc}/lib/vm/runtime/program_limits.ml "$out/program_limits.ml"
          '';
          rehovotCheck = ocamlPackages.buildDunePackage {
            pname = "rehovot_check";
            version = "1.0-rehovot-c54167b";
            src = rehovotSrc;
            propagatedBuildInputs = with ocamlPackages; [ zarith yojson ];
            postInstall = ''
              install -Dm644 ${./LICENSE} "$out/share/doc/rehovot-check/LICENSE"
              install -Dm644 ${./THIRD_PARTY_NOTICES.md} "$out/share/doc/rehovot-check/THIRD_PARTY_NOTICES.md"
            '';
          };
          amlcLsp = ocamlPackages.buildDunePackage {
            pname = "amlc-lsp";
            version = "0.2.0";
            src = ./.;
            buildInputs = with ocamlPackages; [ yojson ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postInstall = ''
              # Expose the pinned compiler as well as the server.  Existing
              # editor ftplugins (and users' :AmlCheck commands) invoke
              # [amlc] directly; keeping it only inside amlc-lsp's wrapper
              # makes those integrations falsely report that AMLC is absent.
              ln -s ${amlc}/bin/amlc "$out/bin/amlc"
              wrapProgram "$out/bin/amlc-lsp" \
                --set AMLC ${amlc}/bin/amlc \
                --set REHOVOT_CHECK ${rehovotCheck}/bin/rehovot-check \
                --prefix PATH : ${pkgs.lib.makeBinPath [ amlc rehovotCheck ]}
              install -Dm644 nvim/plugin/amlc_lsp.lua \
                "$out/share/nvim/site/plugin/amlc_lsp.lua"
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
              rehovotCheck
              dune_3
              findlib
              ocamlformat
              yojson
            ]) ++ [ pkgs.neovim pkgs.tree-sitter ];

            shellHook = ''
              echo "amlc-lsp development shell active"
              echo "amlc: $(amlc version 2>/dev/null || echo unavailable)"
              echo "run: dune build && dune exec amlc-lsp"
            '';
          };
        };
    in
    {
      packages = forAllSystems (system: (perSystem system).packages);
      apps = forAllSystems (system: (perSystem system).apps);
      devShells = forAllSystems (system: (perSystem system).devShells);
    };
}
