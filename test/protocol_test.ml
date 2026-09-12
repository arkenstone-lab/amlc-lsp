let fail message = failwith message
let expect condition message = if not condition then fail message

let test_initialize_capabilities () =
  let info = Yojson.Safe.Util.member "serverInfo" Amlc_lsp.initialize_result in
  expect (Yojson.Safe.Util.member "name" info = `String "amlc-lsp")
    "serverInfo must be a sibling of capabilities";
  let initialized = Amlc_lsp.initialize_result |> Yojson.Safe.to_string in
  expect (Amlc_lsp.contains initialized "completionProvider") "missing keyword completion capability";
  let completion_triggers =
    Amlc_lsp.initialize_result
    |> Yojson.Safe.Util.member "capabilities"
    |> Yojson.Safe.Util.member "completionProvider"
    |> Yojson.Safe.Util.member "triggerCharacters"
  in
  expect (completion_triggers = `List [`String "."])
    "member completion must trigger on dot";
  expect (not (Amlc_lsp.contains initialized "diagnosticProvider"))
    "push diagnostics must not also register an automatic pull provider";
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
  Amlc_lsp.set_dialect_override None;
  expect (Amlc_lsp.document_dialect legacy = Amlc_lsp.Legacy_amlc)
    "legacy program was routed to AppliedML";
  expect (Amlc_lsp.document_dialect "program Batch {\n  input once xs: seq[4, int]\n}" = Amlc_lsp.Legacy_amlc)
    "AML Program input was routed to Rehovot";
  expect (Amlc_lsp.document_dialect applied = Amlc_lsp.Appliedml)
    "AppliedML contract was routed to preview AMLC";
  let program_core =
    "program Mixed {\n  form plus [many left: int] (many right: int) ->[many] int marks {} = left + right\n}"
  in
  expect (Amlc_lsp.document_dialect program_core = Amlc_lsp.Appliedml)
    "AML Program core form was routed to preview AMLC";
  expect (List.mem "contract" (Amlc_lsp.completion_keywords_for applied))
    "AppliedML completion omitted contract";
  expect (List.mem "option" (Amlc_lsp.completion_keywords_for applied))
    "AppliedML completion omitted the documented option spelling";
  expect (List.mem "some" (Amlc_lsp.completion_keywords_for applied)
          && List.mem "none" (Amlc_lsp.completion_keywords_for applied))
    "AppliedML completion omitted lowercase option constructors";
  List.iter (fun spelling ->
    expect (not (List.mem spelling (Amlc_lsp.completion_keywords_for applied)))
      ("AppliedML completion suggested compatibility spelling " ^ spelling))
    ["Program"; "Contract"; "Option"; "Some"; "None"];
  List.iter (fun reserved ->
    expect (not (Amlc_lsp.valid_rename_identifier reserved))
      ("rename accepted reserved spelling " ^ reserved))
    ["program"; "Program"; "contract"; "Contract"; "option"; "Option";
     "some"; "Some"; "none"; "None"];
  expect (List.mem "form" (Amlc_lsp.completion_keywords_for legacy))
    "legacy completion omitted form";
  expect (List.mem "input" (Amlc_lsp.completion_keywords_for legacy))
    "AML Program completion omitted input";
  expect (List.mem "uint" (Amlc_lsp.completion_keywords_for legacy))
    "AML Program completion omitted sized integers";
  expect (List.mem "fold" (Amlc_lsp.completion_keywords_for legacy))
    "AML Program completion omitted fold";
  expect (List.mem "form" (Amlc_lsp.completion_keywords_for program_core))
    "AML Program completion omitted form";
  expect (List.mem "many" (Amlc_lsp.completion_keywords_for program_core))
    "AML Program completion omitted multiplicity";
  expect (List.mem "orbit" (Amlc_lsp.completion_keywords_for program_core))
    "AML Program completion omitted core expression";
  begin match Amlc_lsp.canonical_declaration_diagnostics "Contract Demo {}" with
  | [diagnostic] ->
      expect (diagnostic.code = "REHOVOT001" && diagnostic.severity = 2)
        "Contract compatibility spelling did not produce a style diagnostic"
  | _ -> fail "Contract compatibility spelling was not diagnosed"
  end;
  expect (Amlc_lsp.document_dialect "// form obsolete\ncontract Demo {}" = Amlc_lsp.Appliedml)
    "commented legacy declaration changed dialect routing";
  expect (Amlc_lsp.document_dialect "Interface Demo {}" = Amlc_lsp.Legacy_amlc)
    "unsupported capitalized Interface spelling selected AppliedML";
  expect ((Amlc_lsp.canonical_declaration_diagnostics
            "contract Real {}\n// Contract Demo {}\nconst label = \"Program Demo {}\"") = [])
    "comments or strings produced canonicalisation diagnostics";
  expect ((Amlc_lsp.canonical_declaration_diagnostics
            "contract Real {}\n/*\nProgram Demo {}\n*/") = [])
    "block comment produced a canonicalisation diagnostic";
  expect (Amlc_lsp.dialect_of_string "legacy" = Some Amlc_lsp.Legacy_amlc)
    "legacy dialect setting was not recognised";
  expect (Amlc_lsp.dialect_of_string "appliedml" = Some Amlc_lsp.Appliedml)
    "AppliedML dialect setting was not recognised";
  Amlc_lsp.set_dialect_override (Some Amlc_lsp.Appliedml);
  expect (Amlc_lsp.document_dialect legacy = Amlc_lsp.Appliedml)
    "explicit dialect setting did not override automatic routing";
  Amlc_lsp.set_dialect_override None

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
  Hashtbl.replace Amlc_lsp.documents uri { uri; text = source; version = Some 1 };
  Hashtbl.replace Amlc_lsp.diagnostic_cache (uri, source) [{
    message = "example"; code = "AMLC100"; severity = 1;
    start_position = { line = 0; character = 0; offset = None };
    end_position = { line = 0; character = 1; offset = None };
  }];
  Hashtbl.replace Amlc_lsp.symbol_cache (uri, source) [
    { id = Some "aml:Demo:program:Demo"; kind = "program"; name = "Demo"; typ = "program";
      signature = None; completion_scopes = [];
      selection_start = Some { line = 0; character = 8; offset = None };
      selection_end = Some { line = 0; character = 12; offset = None }; occurrences = [] };
    { id = Some "aml:Demo:form:add"; kind = "form"; name = "add"; typ = "int";
      signature = Some "add(value: int): int"; completion_scopes = [];
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
    typ = "int"; signature = Some "add(value: int): int"; completion_scopes = [];
    selection_start = Some { line = 1; character = 7; offset = None };
    selection_end = Some { line = 1; character = 10; offset = None };
    occurrences = [
      "declaration", { line = 1; character = 7; offset = None }, { line = 1; character = 10; offset = None };
      "reference", { line = 1; character = 7; offset = None }, { line = 1; character = 10; offset = None };
    ];
  } in
  Hashtbl.replace Amlc_lsp.documents uri { uri; text = source; version = Some 1 };
  Hashtbl.replace Amlc_lsp.symbol_cache (uri, source) [symbol];
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
  Hashtbl.replace Amlc_lsp.semantic_token_cache (uri, source) [
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
  Hashtbl.replace Amlc_lsp.diagnostic_cache (uri, source) [
    { message = "missing )"; code = "AMLC101"; severity = 1;
      start_position = { line = 1; character = 10; offset = None };
      end_position = { line = 1; character = 10; offset = None } };
    { message = "canonical spelling"; code = "REHOVOT001"; severity = 2;
      start_position = { line = 0; character = 0; offset = None };
      end_position = { line = 0; character = 8; offset = None } };
  ];
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

let test_uri_paths () =
  let path = "/nonexistent aml-lsp/한글 + #% file.aml" in
  let uri = Amlc_lsp.uri_of_path path in
  expect (Amlc_lsp.contains uri "%20") "file URI did not escape spaces";
  expect (Amlc_lsp.contains uri "%23%25") "file URI did not escape reserved bytes";
  expect (Amlc_lsp.path_of_uri uri = path) "file URI round trip changed the path";
  expect (Amlc_lsp.path_of_uri "file://localhost/nonexistent%20aml-lsp/a+b.aml"
          = "/nonexistent aml-lsp/a+b.aml") "localhost or literal plus decoded incorrectly";
  expect (Amlc_lsp.path_of_uri "file:///nonexistent%2520aml.aml"
          = "/nonexistent%20aml.aml") "file URI decoded twice"

let test_analysis_delivery () =
  let uri = "file:///nonexistent/a/main.aml" in
  let other_uri = "file:///nonexistent/b/main.aml" in
  let document : Amlc_lsp.document = { uri; text = "same source"; version = Some 1 } in
  let other = { document with uri = other_uri } in
  let diagnostic : Amlc_lsp.compiler_diagnostic = {
    message = "import missing"; code = "REHOVOT201"; severity = 1;
    start_position = { line = 0; character = 0; offset = None };
    end_position = { line = 0; character = 1; offset = None };
  } in
  let analysis : Amlc_lsp.document_analysis = {
    diagnostics = [diagnostic]; symbols = []; semantic_tokens = []; members = []; signatures = []; formatting = None; dependencies = Some [];
  } in
  Hashtbl.reset Amlc_lsp.diagnostic_cache;
  Hashtbl.replace Amlc_lsp.documents uri document;
  Hashtbl.replace Amlc_lsp.documents other_uri other;
  let finish snapshot =
    let read_fd, write_fd = Unix.pipe () in
    Unix.close write_fd;
    let job : Amlc_lsp.diagnostic_job = {
      pid = 0; document = snapshot; output = read_fd;
      temporary_files = Some (Filename.temp_file "amlc-worker-" ".aml", Filename.temp_file "amlc-worker-" ".json");
      buffer = Buffer.create 256; started_at = 0.; eof = false;
      status = Some (Unix.WEXITED 0);
    } in
    Buffer.add_string job.buffer (Marshal.to_string (Ok analysis) []);
    let output = open_out_bin (if Sys.win32 then "NUL" else "/dev/null") in
    Fun.protect ~finally:(fun () -> close_out_noerr output)
      (fun () -> Amlc_lsp.finish_diagnostic_job output uri job);
    let source, overlays = Option.get job.temporary_files in
    expect (not (Sys.file_exists source || Sys.file_exists overlays))
      "finished worker retained temporary files"
  in
  finish document;
  let pull uri = Amlc_lsp.request_result "textDocument/diagnostic"
    (`Assoc ["textDocument", `Assoc ["uri", `String uri]])
    |> Yojson.Safe.Util.member "items" in
  expect (pull uri = `List [Amlc_lsp.diagnostic document.text diagnostic])
    "worker diagnostics were not committed for pull requests";
  expect (pull other_uri = `List []) "analysis leaked across equal-content files";
  Hashtbl.reset Amlc_lsp.diagnostic_cache;
  Hashtbl.reset Amlc_lsp.symbol_cache;
  Hashtbl.replace Amlc_lsp.documents uri { document with text = "new source"; version = Some 2 };
  finish document;
  expect (Hashtbl.length Amlc_lsp.diagnostic_cache = 0
          && Hashtbl.length Amlc_lsp.symbol_cache = 0)
    "stale worker results modified the caches";
  Hashtbl.remove Amlc_lsp.documents uri;
  Hashtbl.remove Amlc_lsp.documents other_uri

let test_windows_worker_request () =
  let uri = "file:///nonexistent/project/main.aml" in
  let dependency = "file:///nonexistent/project/types.aml" in
  Hashtbl.replace Amlc_lsp.documents uri
    { uri; text = "program Main {}"; version = Some 2 };
  Hashtbl.replace Amlc_lsp.documents dependency
    { uri = dependency; text = "interface Types {}"; version = Some 3 };
  Amlc_lsp.set_dialect_override (Some Amlc_lsp.Appliedml);
  let request = Amlc_lsp.windows_worker_request uri "program Main {}" in
  expect (Yojson.Safe.Util.member "dialect" request = `String "appliedml")
    "Windows worker request lost the configured dialect";
  let overlays = Yojson.Safe.Util.member "documents" request |> Yojson.Safe.Util.to_list in
  expect (List.exists (fun overlay ->
    Yojson.Safe.Util.member "uri" overlay = `String dependency
    && Yojson.Safe.Util.member "text" overlay = `String "interface Types {}"
    && Yojson.Safe.Util.member "version" overlay = `Int 3) overlays)
    "Windows worker request lost an open import overlay";
  expect (not (List.exists (fun overlay ->
    Yojson.Safe.Util.member "uri" overlay = `String uri) overlays))
    "Windows worker request duplicated its primary document"

let test_worker_descriptor_reuse () =
  let uri = "file:///nonexistent/reused-worker.aml" in
  let document : Amlc_lsp.document = { uri; text = "program P {}"; version = Some 1 } in
  Hashtbl.replace Amlc_lsp.documents uri document;
  let output = open_out_bin "/dev/null" in
  Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
    let read_fd, write_fd = Unix.pipe () in
    Unix.close write_fd;
    let job : Amlc_lsp.diagnostic_job = {
      pid = 0; temporary_files = None; document; output = read_fd;
      buffer = Buffer.create 16; started_at = 0.; eof = false;
      status = Some (Unix.WEXITED 0);
    } in
    Amlc_lsp.collect_job_output job;
    expect job.eof "worker EOF was not collected";
    let next_read, next_write = Unix.pipe () in
    Fun.protect ~finally:(fun () ->
      Amlc_lsp.close_noerr next_read; Amlc_lsp.close_noerr next_write) (fun () ->
      expect (next_read = read_fd) "test requires descriptor reuse after EOF";
      ignore (Unix.write_substring next_write "x" 0 1);
      Amlc_lsp.finish_diagnostic_job output uri job;
      expect (Unix.read next_read (Bytes.create 1) 0 1 = 1)
        "finishing an EOF worker closed another worker's descriptor"))

let test_shutdown_exit () =
  Amlc_lsp.initialized := true;
  Amlc_lsp.shutting_down := true;
  let output = open_out_bin (if Sys.win32 then "NUL" else "/dev/null") in
  let exited = Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
    try Amlc_lsp.handle_message output (`Assoc ["method", `String "exit"]); false
    with Exit -> true) in
  Amlc_lsp.initialized := false;
  Amlc_lsp.shutting_down := false;
  expect exited "exit notification was ignored after shutdown"

let test_cancelled_worker_cleanup () =
  let uri = "file:///nonexistent/worker.aml" in
  let document : Amlc_lsp.document = { uri; text = "program P {}"; version = Some 1 } in
  let output = open_out_bin (if Sys.win32 then "NUL" else "/dev/null") in
  Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
    List.iter (fun (timeout, files) ->
      let temporary_files = if files then Some
        (Filename.temp_file "amlc-worker-" ".aml", Filename.temp_file "amlc-worker-" ".json")
        else None in
      let read_fd, write_fd = Unix.pipe () in
      let pid = Unix.fork () in
      if pid = 0 then begin
        Unix.close read_fd;
        ignore (Unix.setsid ());
        ignore (Unix.write_substring write_fd "ready" 0 5);
        while true do Unix.pause () done
      end;
      Unix.close write_fd;
      let ready = Bytes.create 5 in
      ignore (Unix.read read_fd ready 0 5);
      let job : Amlc_lsp.diagnostic_job = {
        pid; temporary_files; document; output = read_fd;
        buffer = Buffer.create 16; started_at = 0.; eof = false; status = None;
      } in
      Hashtbl.replace Amlc_lsp.diagnostic_jobs uri job;
      Fun.protect ~finally:(fun () -> Amlc_lsp.cancel_diagnostic_job uri) (fun () ->
        if timeout then Amlc_lsp.poll_diagnostic_jobs output []
        else Amlc_lsp.cancel_diagnostic_job uri;
        Option.iter (fun (source, overlays) ->
          expect (not (Sys.file_exists source || Sys.file_exists overlays))
            "cancelled or timed-out worker retained temporary files") temporary_files;
        expect (not (Hashtbl.mem Amlc_lsp.diagnostic_jobs uri)) "cancelled worker retained its job"))
      [false, false; false, true; true, false; true, true])

let test_running_analysis_replacement () =
  let uri = "file:///nonexistent/running-analysis.aml" in
  let original : Amlc_lsp.document = { uri; text = "old"; version = Some 1 } in
  let ready_read, ready_write = Unix.pipe () in
  let gate_read, gate_write = Unix.pipe () in
  let output_read, output_write = Unix.pipe () in
  let output = Unix.out_channel_of_descr output_write in
  let position : Amlc_lsp.position = { line = 0; character = 0; offset = Some 0 } in
  let analysis text : Amlc_lsp.document_analysis = {
    diagnostics = [{ message = text; code = "TEST"; severity = 2;
      start_position = position; end_position = position }];
    symbols = [{ id = None; kind = "function"; name = text; typ = "int";
      signature = Some text; selection_start = Some position; selection_end = Some position;
      completion_scopes = []; occurrences = [] }];
    semantic_tokens = [{ token_type = text; token_start = position; token_end = position }];
    members = [{ member_start = position; member_end = position;
      member_items = [`Assoc ["label", `String text]] }];
    signatures = [{ signature_start = position; signature_end = position;
      signature_help = `String text }];
    formatting = Some [0, 0, (if text = "old" then 1 else 2)]; dependencies = Some [];
  } in
  let wait_readable descriptor message =
    let ready, _, _ = Unix.select [descriptor] [] [] 5. in
    expect (ready <> []) message in
  Fun.protect ~finally:(fun () ->
    Amlc_lsp.cancel_diagnostic_job uri;
    close_out_noerr output;
    List.iter Amlc_lsp.close_noerr [ready_read; ready_write; gate_read; gate_write; output_read]) (fun () ->
    List.iter (fun blocked ->
      Amlc_lsp.set_dialect_override None;
      Hashtbl.replace Amlc_lsp.documents uri original;
      Amlc_lsp.library_analyzer := Some (fun _ text ->
        if text = "old" then begin
          ignore (Unix.write_substring ready_write "r" 0 1);
          if blocked then ignore (Unix.read gate_read (Bytes.create 1) 0 1)
        end;
        analysis text);
      Amlc_lsp.start_diagnostic_job uri original;
      let old_job = Hashtbl.find Amlc_lsp.diagnostic_jobs uri in
      expect (old_job.temporary_files = None) "library worker created helper/source files";
      wait_readable ready_read "old analyzer never entered its callback";
      expect (Unix.read ready_read (Bytes.create 1) 0 1 = 1) "missing analyzer handshake";
      if blocked then
        expect (fst (Unix.waitpid [Unix.WNOHANG] old_job.pid) = 0) "old analyzer was not running"
      else wait_readable old_job.output "old result never reached its output pipe";
      Amlc_lsp.handle_notification output "textDocument/didChange" (`Assoc [
        "textDocument", `Assoc ["uri", `String uri; "version", `Int 2];
        "contentChanges", `List [`Assoc ["text", `String "new"]]]);
      expect (not (Hashtbl.mem Amlc_lsp.diagnostic_jobs uri)) "edit retained the old analysis worker";
      let reaped = try ignore (Unix.waitpid [Unix.WNOHANG] old_job.pid); false
        with Unix.Unix_error (Unix.ECHILD, _, _) -> true in
      expect reaped "cancelled analysis worker was not reaped";
      expect (not (Hashtbl.mem Amlc_lsp.diagnostic_cache (uri, "old"))) "old analysis entered the cache";
      let current = Hashtbl.find Amlc_lsp.documents uri in
      Hashtbl.replace Amlc_lsp.pending_checks uri (current, 0.);
      Amlc_lsp.flush_due_diagnostics output;
      let deadline = Unix.gettimeofday () +. 5. in
      while Hashtbl.mem Amlc_lsp.diagnostic_jobs uri && Unix.gettimeofday () < deadline do
        let job = Hashtbl.find Amlc_lsp.diagnostic_jobs uri in
        let readable, _, _ = Unix.select (if job.eof then [] else [job.output]) [] [] 0.02 in
        Amlc_lsp.poll_diagnostic_jobs output readable
      done;
      expect (not (Hashtbl.mem Amlc_lsp.diagnostic_jobs uri)) "replacement analysis did not finish";
      wait_readable output_read "replacement diagnostics were not published";
      let published = Option.get (Amlc_lsp.Jsonrpc.read_fd output_read) in
      let diagnostics = Yojson.Safe.Util.member "params" published |> Yojson.Safe.Util.member "diagnostics" in
      expect (Yojson.Safe.Util.to_list diagnostics |> List.map (Yojson.Safe.Util.member "message") = [`String "new"])
        "stale worker diagnostics were published";
      let params = `Assoc ["textDocument", `Assoc ["uri", `String uri];
        "position", `Assoc ["line", `Int 0; "character", `Int 0]] in
      expect (Yojson.Safe.Util.member "items" (Amlc_lsp.request_result "textDocument/completion" params)
        = `List [`Assoc ["label", `String "new"]]) "completion used the cancelled worker";
      expect (Amlc_lsp.request_result "textDocument/signatureHelp" params = `String "new")
        "signature help used the cancelled worker";
      expect (Hashtbl.find Amlc_lsp.formatting_cache (uri, "new") = Some [0, 0, 2])
        "replacement formatting layout was not committed";
      expect (List.map (fun (symbol : Amlc_lsp.compiler_symbol) -> symbol.name)
        (Hashtbl.find Amlc_lsp.symbol_cache (uri, "new")) = ["new"])
        "symbol cache retained the cancelled worker";
      expect (List.map (fun (token : Amlc_lsp.compiler_semantic_token) -> token.token_type)
        (Hashtbl.find Amlc_lsp.semantic_token_cache (uri, "new")) = ["new"])
        "semantic token cache retained the cancelled worker";
      let readable, _, _ = Unix.select [output_read] [] [] 0. in
      expect (readable = []) "old worker emitted an additional diagnostic publication") [true; false])

let test_save_invalidates_importers () =
  let uri = "file:///nonexistent/importer.aml" in
  let document : Amlc_lsp.document = { uri; text = "import dependency"; version = Some 1 } in
  Hashtbl.replace Amlc_lsp.documents uri document;
  Hashtbl.replace Amlc_lsp.diagnostic_cache (uri, document.text) [];
  Hashtbl.replace Amlc_lsp.symbol_cache (uri, document.text) [];
  let output = open_out_bin (if Sys.win32 then "NUL" else "/dev/null") in
  Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
    Amlc_lsp.handle_notification output "textDocument/didSave"
      (`Assoc ["textDocument", `Assoc ["uri", `String "file:///nonexistent/dependency.aml"]]));
  expect (Hashtbl.length Amlc_lsp.diagnostic_cache = 0
          && Hashtbl.length Amlc_lsp.symbol_cache = 0)
    "saving a dependency retained stale analysis";
  expect (Hashtbl.mem Amlc_lsp.pending_checks uri)
    "saving a dependency did not reschedule its open importer"

let test_overlay_invalidates_importers () =
  let uri = "file:///nonexistent/importer.aml" in
  let dependency = "file:///nonexistent/dependency.aml" in
  let document : Amlc_lsp.document = { uri; text = "program Main {}"; version = Some 1 } in
  Hashtbl.replace Amlc_lsp.documents uri document;
  let output = open_out_bin (if Sys.win32 then "NUL" else "/dev/null") in
  Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
    List.iter (fun (method_, params) ->
      Hashtbl.replace Amlc_lsp.diagnostic_cache (uri, document.text) [];
      Hashtbl.reset Amlc_lsp.pending_checks;
      Amlc_lsp.handle_notification output method_ (Yojson.Safe.from_string params);
      expect (not (Hashtbl.mem Amlc_lsp.diagnostic_cache (uri, document.text)))
        (method_ ^ " retained stale importer diagnostics");
      expect (Hashtbl.mem Amlc_lsp.pending_checks uri)
        (method_ ^ " did not reschedule the unchanged importer"))
      ["textDocument/didOpen", Printf.sprintf
         {|{"textDocument":{"uri":%S,"text":"program Library {}","version":1}}|} dependency;
       "textDocument/didChange", Printf.sprintf
         {|{"textDocument":{"uri":%S,"version":2},"contentChanges":[{"text":"program Library { fn"}]}|} dependency;
       "textDocument/didClose", Printf.sprintf {|{"textDocument":{"uri":%S}}|} dependency])

let test_dependency_scheduling () =
  let file = Filename.temp_file "amlc-dependency-" ".aml" in
  Fun.protect ~finally:(fun () -> Sys.remove file) (fun () ->
    let dependency = Unix.realpath file in
    let add name dependencies =
      let uri = "file:///nonexistent/" ^ name ^ ".aml" in
      let document : Amlc_lsp.document = { uri; text = "program P {}"; version = Some 1 } in
      Hashtbl.replace Amlc_lsp.documents uri document;
      Hashtbl.replace Amlc_lsp.document_dependencies uri dependencies;
      Hashtbl.replace Amlc_lsp.diagnostic_cache (uri, document.text) [];
      uri, document.text in
    let importer = add "importer" (Some [dependency]) in
    let unrelated = add "unrelated" (Some []) in
    let unknown = add "incomplete" None in
    Amlc_lsp.refresh_open_diagnostics ~changed:(Amlc_lsp.uri_of_path dependency) ();
    List.iter (fun (uri, text) ->
      expect (Hashtbl.mem Amlc_lsp.pending_checks uri) "affected or incomplete graph was not rescheduled";
      expect (not (Hashtbl.mem Amlc_lsp.diagnostic_cache (uri, text))) "dependent cache was retained";
      expect (not (Hashtbl.mem Amlc_lsp.document_dependencies uri)) "in-flight graph was trusted after invalidation")
      [importer; unknown];
    expect (not (Hashtbl.mem Amlc_lsp.pending_checks (fst unrelated))) "unrelated document was rescheduled";
    expect (Hashtbl.mem Amlc_lsp.diagnostic_cache unrelated) "unrelated diagnostic cache was discarded")

let test_utf16_positions () =
  let source = "a😀한\nb" in
  expect (Amlc_lsp.byte_offset source 0 3 = 5) "UTF-16 pair treated as one column";
  expect (Amlc_lsp.byte_offset source 1 0 = 9) "UTF-8 line offset is wrong";
  let position = Amlc_lsp.utf16_position source 8 in
  expect (position.line = 0 && position.character = 4) "byte offset was not converted to UTF-16"

let test_rpc_pipe_backlog () =
  let input, output = Unix.pipe () in
  let channel = Unix.in_channel_of_descr input in
  Fun.protect ~finally:(fun () -> close_in_noerr channel; Unix.close output) (fun () ->
    let body = "{\"method\":\"initialized\"}" in
    let frame = Printf.sprintf "Content-Length: %d\r\n\r\n%s" (String.length body) body in
    let payload = frame ^ frame in
    ignore (Unix.write_substring output payload 0 (String.length payload));
    let first = Amlc_lsp.Jsonrpc.read_fd input in
    let readable, _, _ = Unix.select [input] [] [] 0. in
    expect (readable <> []) "reading one RPC frame hid the queued frame from the event loop";
    expect (Amlc_lsp.Jsonrpc.read_fd input = first) "queued RPC frame was corrupted")

let test_rename_snapshot_validation () =
  expect (Amlc_lsp.rename_workspace_edit "renamed" `Null = `Null)
    "rejected rename must return null without raising";
  expect (Amlc_lsp.rename_workspace_edit "renamed" (`Assoc ["items", `List [`Null]]) = `Null)
    "malformed rename item must reject the whole edit without raising";
  let files = [Filename.temp_file "amlc-rename-" ".aml"; Filename.temp_file "amlc-rename-" ".aml"] in
  Fun.protect ~finally:(fun () -> List.iter Sys.remove files) (fun () ->
    let items = List.mapi (fun index file ->
      let path = Unix.realpath file in
      let uri = Amlc_lsp.uri_of_path path in
      Hashtbl.replace Amlc_lsp.documents uri { uri; text = "helper"; version = Some (index + 3) };
      `Assoc ["path", `String path; "start", `Int 0; "end", `Int 6;
        "sourceHash", `String (Digest.to_hex (Digest.string "helper"))]) files in
    let result = `Assoc ["items", `List items] in
    let edit = Amlc_lsp.rename_workspace_edit "renamed" result in
    let changes = Yojson.Safe.Util.member "documentChanges" edit |> Yojson.Safe.Util.to_list in
    expect (List.length changes = 2) "rename omitted a validated document";
    List.iter (fun change ->
      expect (Yojson.Safe.Util.member "version" (Yojson.Safe.Util.member "textDocument" change) <> `Null)
        "open document rename must include its version") changes;
    let closed_uri = Amlc_lsp.uri_of_path (Unix.realpath (List.nth files 1)) in
    let closed_document = Hashtbl.find Amlc_lsp.documents closed_uri in
    Hashtbl.replace Amlc_lsp.documents closed_uri { closed_document with version = None };
    expect (Amlc_lsp.rename_workspace_edit "renamed" result = `Null)
      "an open document without a version must reject the entire workspace edit";
    Hashtbl.remove Amlc_lsp.documents closed_uri;
    expect (Amlc_lsp.rename_workspace_edit "renamed" result = `Null)
      "a changed disk file must reject the entire workspace edit";
    Hashtbl.replace Amlc_lsp.documents closed_uri closed_document;
    let uri = Amlc_lsp.uri_of_path (Unix.realpath (List.hd files)) in
    Hashtbl.replace Amlc_lsp.documents uri { uri; text = "changed"; version = Some 9 };
    expect (Amlc_lsp.rename_workspace_edit "renamed" result = `Null)
      "one stale document must reject the entire workspace edit")

let test_workspace_rename_requires_document_changes () =
  let file = Filename.temp_file "amlc-workspace-rename-" ".aml" in
  Fun.protect ~finally:(fun () -> Sys.remove file) (fun () ->
    let path = Unix.realpath file in
    let uri = Amlc_lsp.uri_of_path path in
    let source = "interface I {}" in
    let selection_start = { Amlc_lsp.line = 0; character = 10; offset = Some 10 } in
    let selection_end = { Amlc_lsp.line = 0; character = 11; offset = Some 11 } in
    let symbol : Amlc_lsp.compiler_symbol = {
      id = Some (uri ^ "#interface#10"); kind = "interface"; name = "I";
      typ = ""; signature = None; completion_scopes = [];
      selection_start = Some selection_start; selection_end = Some selection_end;
      occurrences = ["declaration", selection_start, selection_end];
    } in
    let document : Amlc_lsp.document = { uri; text = source; version = Some 1 } in
    Hashtbl.replace Amlc_lsp.documents uri document;
    Hashtbl.replace Amlc_lsp.symbol_cache (uri, source) [symbol];
    Amlc_lsp.workspace_roots := [Amlc_lsp.uri_of_path (Filename.dirname path)];
    Amlc_lsp.library_analyzer := Some (fun _ _ -> failwith "unexpected document analysis");
    let queried = ref false in
    Amlc_lsp.library_workspace_analyzer := Some (fun _ _ _ _ _ _ _ ->
      queried := true; `Null);
    let position = `Assoc ["textDocument", `Assoc ["uri", `String uri];
      "position", `Assoc ["line", `Int 0; "character", `Int 10]] in
    expect (Amlc_lsp.request_result "textDocument/prepareRename" position = `Null)
      "prepareRename must reject a client without documentChanges support";
    let rename = match position with
      | `Assoc fields -> `Assoc (("newName", `String "J") :: fields)
      | _ -> assert false in
    expect (Amlc_lsp.request_result "textDocument/rename" rename = `Null)
      "workspace rename must reject a client without documentChanges support";
    expect (not !queried)
      "unsupported workspace rename must not run a synchronous workspace scan")

let test_deferred_editor_requests () =
  let uri = "file:///nonexistent/deferred.aml" in
  let document : Amlc_lsp.document = { uri; text = "inc("; version = Some 1 } in
  let params = `Assoc ["textDocument", `Assoc ["uri", `String uri];
    "position", `Assoc ["line", `Int 0; "character", `Int 4]] in
  Hashtbl.replace Amlc_lsp.documents uri document;
  Amlc_lsp.library_analyzer := Some (fun _ _ -> failwith "transport invoked analyzer synchronously");
  let input, output_fd = Unix.pipe () in
  let output = Unix.out_channel_of_descr output_fd in
  Fun.protect ~finally:(fun () -> close_out_noerr output; Unix.close input) (fun () ->
    let receive () =
      let ready, _, _ = Unix.select [input] [] [] 0. in
      expect (ready <> []) "deferred response was not written";
      match Amlc_lsp.Jsonrpc.read_fd input with Some message -> message | None -> failwith "missing response" in
    let expect_error code =
      let message = receive () in
      expect (Yojson.Safe.Util.member "error" message |> Yojson.Safe.Util.member "code" = `Int code)
        "incorrect deferred-request error" in
    let enqueue id = expect (Amlc_lsp.defer_editor_request (`Int id) "textDocument/signatureHelp" params)
      "uncached request was not deferred" in
    enqueue 1;
    Amlc_lsp.flush_editor_requests output;
    expect (List.length !(Amlc_lsp.editor_requests) = 1) "pending request answered before analysis";
    let _, deadline = Hashtbl.find Amlc_lsp.pending_checks uri in
    expect (deadline <= Unix.gettimeofday ()) "explicit request did not expedite debounce";
    let marker = `Assoc ["signatures", `List []] in
    let position : Amlc_lsp.position = { line = 0; character = 4; offset = Some 4 } in
    Hashtbl.replace Amlc_lsp.signature_cache (Amlc_lsp.document_key document)
      [{ signature_start = position; signature_end = position; signature_help = marker }];
    Hashtbl.replace Amlc_lsp.diagnostic_cache (Amlc_lsp.document_key document) [];
    Amlc_lsp.flush_editor_requests output;
    expect (Yojson.Safe.Util.member "result" (receive ()) = marker) "deferred request lost fresh signature data";
    Hashtbl.reset Amlc_lsp.diagnostic_cache;
    enqueue 2;
    Amlc_lsp.handle_notification output "$/cancelRequest" (`Assoc ["id", `Int 2]);
    expect_error (-32800);
    expect (!(Amlc_lsp.editor_requests) = []) "cancelled request remained queued";
    enqueue 3;
    Hashtbl.replace Amlc_lsp.documents uri { document with version = Some 2; text = "other(" };
    Amlc_lsp.flush_editor_requests output;
    expect_error (-32801);
    Hashtbl.replace Amlc_lsp.documents uri document;
    enqueue 4;
    Hashtbl.reset Amlc_lsp.signature_cache;
    Amlc_lsp.editor_requests := List.map (fun (request : Amlc_lsp.editor_request) ->
      { request with deadline = 0. }) !(Amlc_lsp.editor_requests);
    Amlc_lsp.flush_editor_requests output;
    expect (Yojson.Safe.Util.member "result" (receive ()) = `Null) "expired request did not receive fallback";
    expect (!(Amlc_lsp.editor_requests) = []) "expired request remained queued";
    let formatting = `Assoc ["textDocument", `Assoc ["uri", `String uri];
      "options", `Assoc ["tabSize", `Int 2; "insertSpaces", `Bool true]] in
    expect (Amlc_lsp.defer_editor_request (`Int 40) "textDocument/formatting" formatting)
      "formatting without a position bypassed analysis deferral";
    Amlc_lsp.handle_notification output "$/cancelRequest" (`Assoc ["id", `Int 40]);
    expect_error (-32800);
    expect (Amlc_lsp.defer_editor_request (`Int 41) "textDocument/semanticTokens/full" formatting)
      "semantic tokens without a position bypassed analysis deferral";
    Amlc_lsp.handle_notification output "$/cancelRequest" (`Assoc ["id", `Int 41]);
    expect_error (-32800);
    List.iteri (fun index method_name ->
      let id = `Int (42 + index) in
      let request_params = if List.mem method_name ["textDocument/documentSymbol"; "textDocument/diagnostic"]
        then formatting else params in
      expect (Amlc_lsp.defer_editor_request id method_name request_params)
        (method_name ^ " did not requeue missing analysis");
      Amlc_lsp.handle_notification output "$/cancelRequest" (`Assoc ["id", id]);
      expect_error (-32800)) ["textDocument/hover"; "textDocument/definition";
        "textDocument/declaration"; "textDocument/references";
        "textDocument/documentSymbol"; "textDocument/diagnostic"];
    enqueue 5;
    Hashtbl.remove Amlc_lsp.documents uri;
    Amlc_lsp.flush_editor_requests output;
    expect_error (-32801);
    Hashtbl.replace Amlc_lsp.documents uri document;
    enqueue 6;
    Amlc_lsp.set_dialect_override (Some Amlc_lsp.Appliedml);
    Amlc_lsp.flush_editor_requests output;
    expect_error (-32801);
    Amlc_lsp.set_dialect_override None;
    enqueue 7;
    Amlc_lsp.initialized := true;
    Amlc_lsp.handle_message output (`Assoc ["jsonrpc", `String "2.0";
      "id", `Int 8; "method", `String "shutdown"]);
    expect_error (-32800);
    expect (Yojson.Safe.Util.member "id" (receive ()) = `Int 8) "shutdown did not finish after cancelling requests";
    for id = 1 to Amlc_lsp.max_editor_requests do enqueue id done;
    expect (not (Amlc_lsp.defer_editor_request (`Int 1000) "textDocument/signatureHelp" params))
      "editor request queue exceeded its bound")

let test_analysis_cache_eviction () =
  let open Amlc_lsp in
  let key index = Printf.sprintf "file:///cache/%d.aml" index, "source" in
  let output = open_out_bin (if Sys.win32 then "NUL" else "/dev/null") in
  Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
    let finish index =
      let uri, text = key index in
      let document : document = { uri; text; version = Some 1 } in
      Hashtbl.replace documents uri document;
      let read_fd, write_fd = Unix.pipe () in
      Unix.close write_fd;
      let job : diagnostic_job = {
        pid = 0; document; output = read_fd; temporary_files = None;
        buffer = Buffer.create 256; started_at = 0.; eof = false;
        status = Some (Unix.WEXITED 0);
      } in
      let analysis : document_analysis = { diagnostics = []; symbols = [];
        semantic_tokens = []; members = []; signatures = []; formatting = None; dependencies = Some [] } in
      Buffer.add_string job.buffer (Marshal.to_string (Ok analysis) []);
      finish_diagnostic_job output uri job in
    for index = 0 to max_cached_documents - 1 do finish index done;
    finish 0;
    expect (Hashtbl.length symbol_cache = max_cached_documents)
      "refreshing a full cache must not erase unrelated documents";
    finish max_cached_documents;
    let retained cache = Hashtbl.length cache = max_cached_documents
      && Hashtbl.mem cache (key 0) && Hashtbl.mem cache (key max_cached_documents)
      && not (Hashtbl.mem cache (key 1)) in
    expect (retained diagnostic_cache && retained symbol_cache && retained semantic_token_cache
      && retained member_cache && retained signature_cache && retained formatting_cache)
      "all feature caches must evict only the oldest snapshot together";
    ignore (request_result "textDocument/diagnostic"
      (`Assoc ["textDocument", `Assoc ["uri", `String (fst (key 2))]]));
    finish (max_cached_documents + 1);
    expect (Hashtbl.mem symbol_cache (key 2) && not (Hashtbl.mem symbol_cache (key 3)))
      "an editor request must retain its analysis ahead of older unused snapshots";
    expect (List.length !analysis_recency = max_cached_documents)
      "cache ordering itself must remain bounded")

let reset_state () =
  Amlc_lsp.editor_requests := [];
  Amlc_lsp.library_analyzer := None;
  Amlc_lsp.library_workspace_analyzer := None;
  Hashtbl.reset Amlc_lsp.document_dependencies;
  Hashtbl.reset Amlc_lsp.documents;
  Hashtbl.reset Amlc_lsp.pending_checks;
  Hashtbl.reset Amlc_lsp.project_symbol_cache;
  Amlc_lsp.workspace_roots := [];
  Amlc_lsp.supports_document_changes := false;
  Amlc_lsp.initialized := false;
  Amlc_lsp.shutting_down := false;
  Amlc_lsp.set_dialect_override None

let () =
  List.iter (fun test ->
    reset_state ();
    Fun.protect ~finally:reset_state test) [
    test_initialize_capabilities;
    test_deferred_editor_requests;
    test_rename_snapshot_validation;
    test_workspace_rename_requires_document_changes;
    test_rpc_pipe_backlog;
    test_machine_diagnostics_contract;
    test_json_lines_diagnostics;
    test_document_limits_and_deduplication;
    test_format_safety_boundary;
    test_dialect_routing_and_completion;
    test_versioned_symbol_contract;
    test_workspace_folder_changes;
    test_document_symbols;
    test_compiler_backed_editor_help;
    test_uri_paths;
    test_analysis_delivery;
    test_windows_worker_request;
    test_analysis_cache_eviction;
    test_worker_descriptor_reuse;
    test_shutdown_exit;
    test_save_invalidates_importers;
    test_cancelled_worker_cleanup;
    test_running_analysis_replacement;
    test_overlay_invalidates_importers;
    test_dependency_scheduling;
    test_utf16_positions;
  ]
