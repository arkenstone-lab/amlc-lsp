let fail message = failwith message
let expect condition message = if not condition then fail message

let test_initialize_capabilities () =
  let initialized = Amlc_lsp.initialize_result |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains initialized "completionProvider") "missing keyword completion capability";
  expect (Amlc_lsp.contains initialized "diagnosticProvider") "missing pull-diagnostic capability";
  expect (Amlc_lsp.contains initialized "documentSymbolProvider") "missing document-symbol capability";
  expect (Amlc_lsp.contains initialized "hoverProvider") "missing hover capability";
  expect (Amlc_lsp.contains initialized "signatureHelpProvider") "missing signature-help capability";
  expect (Amlc_lsp.contains initialized "definitionProvider") "missing definition capability";
  expect (Amlc_lsp.contains initialized "declarationProvider") "missing declaration capability";
  expect (Amlc_lsp.contains initialized "referencesProvider") "missing references capability";
  expect (Amlc_lsp.contains initialized "renameProvider") "missing rename capability";
  expect (Amlc_lsp.contains initialized "codeActionProvider") "missing code-action capability";
  let code_action_provider =
    Amlc_lsp.initialize_result
    |> Yojson.Safe.Util.member "capabilities"
    |> Yojson.Safe.Util.member "codeActionProvider"
  in
  expect (code_action_provider = `Bool true)
    "code-action capability must use a standard LSP boolean or options object";
  expect (Amlc_lsp.contains initialized "documentFormattingProvider") "missing formatting capability";
  expect (Amlc_lsp.contains initialized "documentHighlightProvider") "missing document-highlight capability";
  expect (Amlc_lsp.contains initialized "inlayHintProvider") "missing inlay-hint capability";
  expect (Amlc_lsp.contains initialized "foldingRangeProvider") "missing folding-range capability";
  expect (Amlc_lsp.contains initialized "selectionRangeProvider") "missing selection-range capability";
  expect (Amlc_lsp.contains initialized "prepareProvider") "missing rename preparation capability";
  expect (Amlc_lsp.contains initialized "workspaceSymbolProvider") "missing workspace-symbol capability";
  expect (Amlc_lsp.contains initialized "workspaceFolders") "missing workspace-folder capability";
  expect (Amlc_lsp.contains initialized "semanticTokensProvider") "compiler-backed semantic-token capability is missing";
  expect (Amlc_lsp.contains initialized "\"function\"") "semantic-token legend is missing compiler-backed functions"

let test_machine_diagnostics_contract () =
  let valid = "{\"message\":\"unexpected\",\"start\":{},\"end\":{}}\n" in
  expect (Amlc_lsp.has_machine_diagnostics valid) "valid JSON diagnostics were rejected";
  expect (Amlc_lsp.has_machine_diagnostics "") "an empty successful diagnostics stream was rejected";
  expect (not (Amlc_lsp.has_machine_diagnostics "unknown option --diagnostics=json\n"))
    "human compiler output was accepted as a machine interface"

let test_json_lines_diagnostics () =
  let output =
    "not a diagnostic\n"
    ^ "{\"message\":\"unexpected token\",\"severity\":\"error\",\"start\":{\"line\":2,\"column\":3},\"end\":{\"line\":2,\"column\":7}}\n"
    ^ "{\"message\":\"unused name\",\"severity\":\"warning\",\"start\":{\"line\":4,\"column\":1},\"end\":{\"line\":4,\"column\":5}}\n"
  in
  match Amlc_lsp.parse_diagnostics output with
  | [ error; warning ] ->
      expect (error.start_position.line = 1 && error.start_position.character = 2) "did not convert one-based position";
      expect (error.severity = 1 && error.code = "AMLC100") "error diagnostic was not preserved";
      expect (warning.severity = 2) "warning severity was not preserved"
  | _ -> fail "did not parse JSON Lines diagnostics"

let test_document_limits_and_deduplication () =
  let text = String.make (Amlc_lsp.max_document_bytes + 1) 'x' in
  let oversized = Amlc_lsp.too_large_diagnostic text in
  expect (oversized.code = "AMLC900" && oversized.severity = 2) "large document diagnostic is incorrect";
  let diagnostic = {
    Amlc_lsp.message = "duplicate"; code = "AMLC100"; severity = 1;
    start_position = { line = 0; character = 0; offset = Some 0 };
    end_position = { line = 0; character = 1; offset = Some 1 };
  } in
  expect (List.length (Amlc_lsp.dedupe_diagnostics [diagnostic; diagnostic]) = 1)
    "duplicate diagnostics were retained"

let test_format_safety_boundary () =
  expect (not (Amlc_lsp.has_multiline_sensitive_lexeme "contract C {\n  fn f() {}\n}"))
    "ordinary source was rejected by formatter boundary";
  expect (Amlc_lsp.has_multiline_sensitive_lexeme "contract C {\n  const x = \"a\nb\"\n}")
    "multiline string was accepted by formatter boundary"

let test_dialect_routing_and_completion () =
  let legacy = "program Demo {\n  form add [] (many value: int) ->[many] int marks {} = value\n  term add(1)\n}" in
  let applied = "contract Demo {\n  fn add(value: int): int { value }\n}" in
  expect (Amlc_lsp.document_dialect legacy = Amlc_lsp.Legacy_amlc)
    "legacy program was routed to AppliedML";
  expect (Amlc_lsp.document_dialect applied = Amlc_lsp.Appliedml)
    "AppliedML contract was routed to preview AMLC";
  expect (List.mem "contract" (Amlc_lsp.completion_keywords_for applied))
    "AppliedML completion omitted contract";
  expect (List.mem "option" (Amlc_lsp.completion_keywords_for applied))
    "AppliedML completion omitted the documented option spelling";
  expect (not (List.mem "Option" (Amlc_lsp.completion_keywords_for applied)))
    "AppliedML completion preferred an undocumented Option spelling";
  expect (not (List.mem "Contract" (Amlc_lsp.completion_keywords_for applied)))
    "AppliedML completion suggested legacy Contract spelling";
  expect (List.mem "form" (Amlc_lsp.completion_keywords_for legacy))
    "legacy completion omitted form";
  expect (not (List.mem "form" (Amlc_lsp.completion_keywords_for applied)))
    "AppliedML completion leaked legacy form";
  begin match Amlc_lsp.canonical_declaration_diagnostics "Contract Demo {}" with
  | [diagnostic] ->
      expect (diagnostic.code = "REHOVOT001" && diagnostic.severity = 2)
        "Contract compatibility spelling did not produce a style diagnostic"
  | _ -> fail "Contract compatibility spelling was not diagnosed"
  end

let test_versioned_symbol_contract () =
  let json = Yojson.Safe.from_string
    "{\"version\":2,\"symbols\":[{\"id\":\"aml:function:Demo:add\",\"kind\":\"function\",\"name\":\"add\",\"type\":\"int\",\"signature\":\"add(value: int): int\",\"selectionRange\":{\"start\":{\"line\":2,\"column\":6,\"offset\":21},\"end\":{\"line\":2,\"column\":9,\"offset\":24}}}]}" in
  match Yojson.Safe.Util.member "symbols" json with
  | `List [value] ->
      begin match Amlc_lsp.symbol_of_json value with
      | Some symbol ->
          expect (symbol.id = Some "aml:function:Demo:add") "symbol ID was not preserved";
          expect (symbol.selection_start = Some { line = 1; character = 5; offset = Some 21 })
            "symbol selection start was not converted"
      | None -> fail "versioned symbol was rejected"
      end
  | _ -> fail "versioned symbol envelope is malformed"

let test_workspace_folder_changes () =
  Amlc_lsp.workspace_roots := ["file:///one"];
  Amlc_lsp.apply_workspace_folder_change (Yojson.Safe.from_string
    "{\"event\":{\"added\":[{\"uri\":\"file:///two\"}],\"removed\":[{\"uri\":\"file:///one\"}]}}");
  expect (!(Amlc_lsp.workspace_roots) = ["file:///two"])
    "workspace folder changes did not update roots"

let test_document_symbols () =
  let uri = "file:///tmp/demo.aml" in
  let source = "program Demo {\n  form add [] (many value: int) ->[many] int marks {} = value\n  term add(1)\n}" in
  Hashtbl.replace Amlc_lsp.documents uri { text = source; version = Some 1 };
  Hashtbl.replace Amlc_lsp.diagnostic_cache source [{
    message = "example"; code = "AMLC100"; severity = 1;
    start_position = { line = 0; character = 0; offset = None };
    end_position = { line = 0; character = 1; offset = None };
  }];
  Hashtbl.replace Amlc_lsp.symbol_cache source [
    { id = Some "aml:Demo:program:Demo"; kind = "program"; name = "Demo"; typ = "program";
      signature = None;
      selection_start = Some { line = 0; character = 8; offset = None };
      selection_end = Some { line = 0; character = 12; offset = None }; occurrences = [] };
    { id = Some "aml:Demo:form:add"; kind = "form"; name = "add"; typ = "int";
      signature = Some "add(value: int): int";
      selection_start = Some { line = 1; character = 7; offset = None };
      selection_end = Some { line = 1; character = 10; offset = None }; occurrences = [] };
  ];
  let params = Yojson.Safe.from_string
    "{\"textDocument\":{\"uri\":\"file:///tmp/demo.aml\"}}" in
  match Amlc_lsp.request_result "textDocument/documentSymbol" params with
  | `List [`Assoc program; `Assoc form] ->
      expect (List.assoc_opt "name" program = Some (`String "Demo")) "program symbol is missing";
      expect (List.assoc_opt "name" form = Some (`String "add")) "form symbol is missing"
  | _ -> fail "document symbols have an invalid shape"

let test_compiler_backed_editor_help () =
  let uri = "file:///tmp/help.aml" in
  let source = "program Demo {\n  term add(1, 2)\n}" in
  let symbol : Amlc_lsp.compiler_symbol = {
    id = Some "aml:function:Demo:add"; kind = "function"; name = "add";
    typ = "int"; signature = Some "add(value: int): int";
    selection_start = Some { line = 1; character = 7; offset = None };
    selection_end = Some { line = 1; character = 10; offset = None };
    occurrences = [
      "declaration", { line = 1; character = 7; offset = None }, { line = 1; character = 10; offset = None };
      "reference", { line = 1; character = 7; offset = None }, { line = 1; character = 10; offset = None };
    ];
  } in
  Hashtbl.replace Amlc_lsp.documents uri { text = source; version = Some 1 };
  Hashtbl.replace Amlc_lsp.symbol_cache source [symbol];
  let with_position line character = Yojson.Safe.from_string
    (Printf.sprintf
       "{\"textDocument\":{\"uri\":\"%s\"},\"position\":{\"line\":%d,\"character\":%d}}"
       uri line character) in
  let hover = Amlc_lsp.request_result "textDocument/hover" (with_position 1 8)
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains hover "add(value: int): int") "hover did not use the compiler signature";
  let pull_diagnostics = Amlc_lsp.request_result "textDocument/diagnostic"
    (Yojson.Safe.from_string "{\"textDocument\":{\"uri\":\"file:///tmp/help.aml\"}}") |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains pull_diagnostics "\"kind\":\"full\"")
    "pull diagnostics did not return a full report";
  let signature = Amlc_lsp.request_result "textDocument/signatureHelp" (with_position 1 11)
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains signature "add(value: int): int") "signature help did not use the compiler signature";
  let second_parameter = Amlc_lsp.request_result "textDocument/signatureHelp" (with_position 1 15)
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains second_parameter "\"activeParameter\":1")
    "signature help did not identify the active argument";
  let completion = Amlc_lsp.request_result "textDocument/completion" (with_position 1 0)
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains completion "add(value: int): int") "completion did not include compiler symbol";
  let definition = Amlc_lsp.request_result "textDocument/definition" (with_position 1 8)
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains definition "\"character\":7") "definition did not use compiler selection range";
  let declaration = Amlc_lsp.request_result "textDocument/declaration" (with_position 1 8)
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains declaration "\"character\":7") "declaration did not use compiler selection range";
  let workspace = Amlc_lsp.request_result "workspace/symbol"
    (Yojson.Safe.from_string "{\"query\":\"add\"}") |> Yojson.Safe.to_string in
  expect (not (Amlc_lsp.contains workspace "aml:function:Demo:add"))
    "workspace symbols exposed an internal compiler ID";
  expect (Amlc_lsp.contains workspace "file:///tmp/help.aml")
    "workspace symbols did not use the compiler declaration range";
  let references = Amlc_lsp.request_result "textDocument/references" (with_position 1 8)
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains references "file:///tmp/help.aml")
    "references did not use compiler occurrences";
  let rename = Amlc_lsp.request_result "textDocument/rename"
    (Yojson.Safe.from_string
      "{\"textDocument\":{\"uri\":\"file:///tmp/help.aml\"},\"position\":{\"line\":1,\"character\":8},\"newName\":\"sum\"}")
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains rename "\"newText\":\"sum\"")
    "rename did not use compiler occurrences";
  let prepared = Amlc_lsp.request_result "textDocument/prepareRename" (with_position 1 8)
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains prepared "\"placeholder\":\"add\"")
    "rename preparation did not require a compiler occurrence";
  let highlights = Amlc_lsp.request_result "textDocument/documentHighlight" (with_position 1 8)
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains highlights "\"kind\":3")
    "document highlights did not preserve compiler declaration roles";
  let hints = Amlc_lsp.request_result "textDocument/inlayHint"
    (Yojson.Safe.from_string "{\"textDocument\":{\"uri\":\"file:///tmp/help.aml\"}}")
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains hints "Compiler-reported return type of add")
    "inlay hints did not use compiler symbols";
  let tokens = Amlc_lsp.request_result "textDocument/semanticTokens/full"
    (Yojson.Safe.from_string "{\"textDocument\":{\"uri\":\"file:///tmp/help.aml\"}}")
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains tokens "\"data\":[1,7,3,2,0,0,0,3,2,0]")
    "semantic tokens did not use compiler occurrence ranges";
  Hashtbl.replace Amlc_lsp.semantic_token_cache source [
    { token_type = "keyword";
      token_start = { line = 0; character = 0; offset = None };
      token_end = { line = 0; character = 7; offset = None } };
    { token_type = "type";
      token_start = { line = 1; character = 18; offset = None };
      token_end = { line = 1; character = 21; offset = None } };
  ];
  let compiler_tokens = Amlc_lsp.request_result "textDocument/semanticTokens/full"
    (Yojson.Safe.from_string "{\"textDocument\":{\"uri\":\"file:///tmp/help.aml\"}}")
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains compiler_tokens "\"data\":[0,0,7,0,0,1,18,3,1,0]")
    "semantic tokens did not preserve compiler token roles";
  let folding = Amlc_lsp.request_result "textDocument/foldingRange"
    (Yojson.Safe.from_string "{\"textDocument\":{\"uri\":\"file:///tmp/help.aml\"}}")
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains folding "\"startLine\":0")
    "folding ranges did not include the enclosing declaration";
  let selections = Amlc_lsp.request_result "textDocument/selectionRange"
    (Yojson.Safe.from_string "{\"textDocument\":{\"uri\":\"file:///tmp/help.aml\"},\"positions\":[{\"line\":1,\"character\":8}]}")
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains selections "\"parent\"")
    "selection ranges did not include enclosing source ranges";
  let actions = Amlc_lsp.request_result "textDocument/codeAction"
    (Yojson.Safe.from_string
      "{\"textDocument\":{\"uri\":\"file:///tmp/help.aml\"},\"context\":{\"diagnostics\":[{\"code\":\"AMLC101\",\"range\":{\"start\":{\"line\":1,\"character\":10},\"end\":{\"line\":1,\"character\":10}}}]}}")
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains actions "Insert missing ')'")
    "compiler diagnostic quick fix was not offered";
  let canonical_action = Amlc_lsp.request_result "textDocument/codeAction"
    (Yojson.Safe.from_string
      "{\"textDocument\":{\"uri\":\"file:///tmp/help.aml\"},\"context\":{\"diagnostics\":[{\"code\":\"REHOVOT001\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":8}}}]}}")
    |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains canonical_action "Use canonical 'contract'")
    "canonical Contract quick fix was not offered"

let () =
  test_initialize_capabilities ();
  test_machine_diagnostics_contract ();
  test_json_lines_diagnostics ();
  test_document_limits_and_deduplication ();
  test_format_safety_boundary ();
  test_dialect_routing_and_completion ();
  test_versioned_symbol_contract ();
  test_workspace_folder_changes ();
  test_document_symbols ();
  test_compiler_backed_editor_help ()
