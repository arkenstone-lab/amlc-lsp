open Yojson.Safe
open Oct_lang

let position line column = `Assoc ["line", `Int line; "column", `Int column]

let starts_with prefix value =
  let length = String.length prefix in
  String.length value >= length && String.sub value 0 length = prefix

let diagnostic_code message =
  if starts_with "expected :" message then "REHOVOT101"
  else if starts_with "expected }" message then "REHOVOT102"
  else if starts_with "expected )" message then "REHOVOT103"
  else if starts_with "expected ]" message then "REHOVOT104"
  else if starts_with "expected ," message then "REHOVOT105"
  else "REHOVOT100"

let diagnostic ?(column = 1) ?end_column ?(severity = "error") ?code line message =
  let end_column = Option.value ~default:(column + 1) end_column in
  `Assoc [
    "message", `String message;
    "severity", `String severity;
    "code", `String (Option.value ~default:(diagnostic_code message) code);
    "start", position line column;
    "end", position line end_column;
  ]

let rec type_name = function
  | Oct_lang.TInt -> "int" | TBool -> "bool" | TString -> "string"
  | TAddress -> "address" | TBytes -> "bytes" | TBytes32 -> "bytes32"
  | TU64 -> "u64" | TU128 -> "u128" | TU256 -> "u256"
  | TCipher -> "cipher" | TPubKey -> "pubkey"
  | TMap (key, value) -> "map[" ^ type_name key ^ "]" ^ type_name value
  | TList value -> "list[" ^ type_name value ^ "]"
  | TStruct name | TEnum name -> name
  | TOption value -> "Option[" ^ type_name value ^ "]"
  | TTuple values -> "(" ^ String.concat ", " (List.map type_name values) ^ ")"
  | TVoid -> "void"

let parameters values =
  values
  |> List.map (fun parameter -> parameter.Oct_lang.p_name ^ ": " ^ type_name parameter.p_typ)
  |> String.concat ", "

let function_signature fn =
  fn.Oct_lang.fn_name ^ "(" ^ parameters fn.fn_params ^ "): " ^ type_name fn.fn_ret

let multiplicity = function
  | Oct_lang.Once -> "once"
  | Many -> "many"

let form_parameters values =
  values
  |> List.map (fun parameter ->
      multiplicity parameter.Oct_lang.fp_mult ^ " " ^ parameter.fp_name
      ^ ": " ^ type_name parameter.fp_typ)
  |> String.concat ", "

let form_signature form =
  form.Oct_lang.fm_name ^ "(" ^ form_parameters form.fm_params ^ ") ->["
  ^ multiplicity form.fm_mult ^ "] " ^ type_name form.fm_ret

let event_signature event =
  event.Oct_lang.ev_name ^ "(" ^
  (event.ev_fields
   |> List.map (fun (name, typ, _indexed) -> name ^ ": " ^ type_name typ)
  |> String.concat ", ") ^ ")"

type source_span = { start_offset : int; start_line : int; start_column : int;
                     end_offset : int; end_line : int; end_column : int }

type located_token = { token : token; span : source_span }

let source_tokens source =
  let lexer = Oct_lex.create source in
  let rec collect tokens =
    let start_offset, start_line, start_column = lexer.pos, lexer.line, lexer.col in
    let token = Oct_lex.next_token lexer in
    let span = {
      start_offset; start_line; start_column;
      end_offset = lexer.pos; end_line = lexer.line; end_column = lexer.col;
    } in
    match token with
    | TkEOF -> List.rev tokens
    | _ -> collect ({ token; span } :: tokens)
  in
  collect []

let range span = `Assoc [
  "start", `Assoc ["line", `Int span.start_line; "column", `Int span.start_column; "offset", `Int span.start_offset];
  "end", `Assoc ["line", `Int span.end_line; "column", `Int span.end_column; "offset", `Int span.end_offset];
]

let declaration_span tokens kind name =
  let declaration = function
    | "contract", TkContract | "program", TkProgram | "interface", TkInterface
    | "struct", TkStruct | "enum", TkEnum | "event", TkEvent | "constant", TkConst
    | "function", TkFn | "method", TkFn -> true
    | _ -> false
  in
  let rec find = function
    | { token = TkIdent "form"; _ } :: ({ token = TkIdent found; span } :: _)
      when String.equal kind "form" && String.equal found name -> Some span
    | { token = TkPublic; _ } :: ({ token = TkIdent "main"; span } :: _)
      when String.equal kind "form" && String.equal name "main" -> Some span
    | { token; _ } :: ({ token = TkIdent found; span } :: _) when declaration (kind, token)
        && String.equal found name -> Some span
    | _ :: rest -> find rest
    | [] -> None
  in
  find tokens

let symbol_occurrences tokens kind name =
  if not (List.mem kind ["function"; "method"; "form"]) then [] else
  let rec collect found = function
    | { token = TkIdent "form"; _ } :: ({ token = TkIdent declared; span } :: rest)
      when String.equal kind "form" && String.equal declared name ->
        collect (("declaration", span) :: found) rest
    | { token = TkPublic; _ } :: ({ token = TkIdent "main"; span } :: rest)
      when String.equal kind "form" && String.equal name "main" ->
        collect (("declaration", span) :: found) rest
    | { token = TkFn; _ } :: ({ token = TkIdent declared; span } :: rest)
      when String.equal declared name -> collect (("declaration", span) :: found) rest
    | ({ token = TkIdent called; span } :: { token = TkLParen; _ } :: rest)
      when String.equal called name -> collect (("reference", span) :: found) rest
    | _ :: rest -> collect found rest
    | [] -> List.rev found
  in
  collect [] tokens

let lexical_token_type = function
  | TkTyInt | TkTyBool | TkTyString | TkTyAddress | TkTyBytes | TkTyBytes32
  | TkTyU64 | TkTyU128 | TkTyU256 | TkTyUint | TkTyCipher | TkTyPubKey | TkMap | TkTyList
  | TkOption -> Some "type"
  | TkIntLit _ -> Some "number"
  | TkStrLit _ -> Some "string"
  | TkPlus | TkMinus | TkStar | TkSlash | TkPercent | TkEq | TkEqEq | TkBangEq
  | TkLt | TkGt | TkLtEq | TkGtEq | TkAmpAmp | TkPipePipe | TkBang | TkFatArrow
  | TkPlusEq | TkMinusEq | TkStarEq | TkSlashEq | TkDotDot -> Some "operator"
  | TkLBrace | TkRBrace | TkLParen | TkRParen | TkLBrack | TkRBrack | TkColon
  | TkComma | TkDot | TkNewline | TkEOF -> None
  | TkIdent ("sint" | "seq" | "vec" | "cap") -> Some "type"
  | TkIdent ("form" | "main" | "once" | "many" | "marks" | "under"
    | "steps" | "depth" | "work" | "use" | "split" | "orbit" | "equal"
    | "then" | "from" | "with" | "write" | "read" | "fail") -> Some "keyword"
  | TkIdent _ -> Some "variable"
  | _ -> Some "keyword"

let semantic_tokens tokens function_names =
  let rec collect found = function
    | { token = TkIdent "form"; span = keyword_span } ::
      ({ token = TkIdent name; span } :: rest)
      when List.mem name function_names ->
        collect (("function", span) :: ("keyword", keyword_span) :: found) rest
    | { token = TkIdent name; span } :: { token = TkLParen; _ } :: rest
      when List.mem name function_names -> collect (("function", span) :: found) rest
    | { token = TkFn; _ } :: ({ token = TkIdent name; span } :: rest)
      when List.mem name function_names -> collect (("function", span) :: found) rest
    | { token; span } :: rest ->
        let found = match lexical_token_type token with Some role -> (role, span) :: found | None -> found in
        collect found rest
    | [] -> List.rev found
  in
  collect [] tokens

let symbols source contract =
  let tokens = source_tokens source in
  let declaration_kind = match contract.Oct_lang.declaration with
    | Oct_lang.ContractDecl -> "contract"
    | Oct_lang.ProgramDecl -> "program"
    | Oct_lang.InterfaceDecl -> "interface"
  in
  let item ?parent ?signature kind name typ =
    let id =
      String.concat ":" ("rehovot" :: contract.name :: kind ::
        Option.to_list parent @ [name])
    in
    `Assoc (["id", `String id; "kind", `String kind; "name", `String name; "type", `String typ]
      @ (match signature with None -> [] | Some value -> ["signature", `String value])
      @ (match declaration_span tokens kind name with None -> [] | Some span -> ["selectionRange", range span])
      @ (match symbol_occurrences tokens kind name with
          | [] -> []
          | occurrences -> ["occurrences", `List (List.map (fun (role, span) ->
              `Assoc ["role", `String role; "range", range span]) occurrences)]))
  in
  let structs = List.map (fun struct_ -> item "struct" struct_.Oct_lang.sd_name "struct") contract.structs in
  let enums = List.map (fun enum -> item "enum" enum.Oct_lang.en_name "enum") contract.enums in
  let constants = List.map (fun constant -> item "constant" constant.Oct_lang.c_name (type_name constant.c_typ)) contract.consts in
  let interfaces = contract.interfaces |> List.concat_map (fun interface ->
    item "interface" interface.Oct_lang.if_name "interface" ::
    List.map (fun method_ -> item ~parent:interface.if_name ~signature:(method_.im_name ^ "(" ^ parameters method_.im_params ^ "): " ^ type_name method_.im_ret)
      "method" method_.im_name (type_name method_.im_ret)) interface.if_methods) in
  let fields = List.map (fun field -> item "field" field.Oct_lang.sf_name (type_name field.sf_typ)) contract.state in
  let events = List.map (fun event -> item ~signature:(event_signature event) "event" event.ev_name "event") contract.events in
  let functions = List.map (fun fn -> item ~signature:(function_signature fn) "function" fn.fn_name (type_name fn.fn_ret)) contract.funcs in
  let constructor = match contract.ctor with None -> [] | Some fn -> [item ~signature:(function_signature fn) "constructor" fn.fn_name (type_name fn.fn_ret)] in
  let forms = List.map (fun form ->
    item ~signature:(form_signature form) "form" form.fm_name (type_name form.fm_ret)) contract.forms in
  let function_names =
    (contract.funcs |> List.map (fun fn -> fn.fn_name))
    @ (contract.forms |> List.map (fun form -> form.fm_name))
  in
  `Assoc [
    "version", `Int 2;
    "symbols", `List (item declaration_kind contract.name declaration_kind :: structs @ enums @ constants @ interfaces @ fields @ events @ constructor @ forms @ functions);
    "semanticTokens", `List (semantic_tokens tokens function_names |> List.map (fun (token_type, span) ->
      `Assoc ["type", `String token_type; "range", range span]));
  ]

let verifier_diagnostics source contract =
  let tokens = source_tokens source in
  let finding_span finding =
    let name = match finding.Aml_verify.function_name with
      | Some name -> Some name
      | None ->
          (match finding.state_field with
           | Some name -> Some name
           | None ->
               (match finding.parameter with
                | Some name -> Some name
                | None -> Some contract.name))
    in
    match name with
    | None -> None
    | Some name ->
        let rec find = function
          | { token = TkIdent found; span } :: _ when String.equal found name ->
              Some span
          | _ :: rest -> find rest
          | [] -> None
        in
        find tokens
  in
  let report = Aml_verify.verify_ast contract in
  report.findings |> List.map (fun finding ->
    let severity = match finding.Aml_verify.severity with Aml_verify.Error -> "error" | Aml_verify.Warning -> "warning" in
    match finding_span finding with
    | Some span ->
        diagnostic ~column:span.start_column ~end_column:span.end_column
          ~severity ~code:("REHOVOTV-" ^ finding.code) span.start_line finding.message
    | None ->
        diagnostic ~severity ~code:("REHOVOTV-" ^ finding.code) 1 finding.message)

let type_diagnostics resolve_scope source scope own =
  let previous = !Oct_form_check.resolve_scope in
  Fun.protect ~finally:(fun () -> Oct_form_check.resolve_scope := previous) (fun () ->
  Oct_form_check.resolve_scope := resolve_scope;
  let tokens = source_tokens source in
  let check kind name run =
    try run (); None with Oct_check.Invalid message ->
      let line, column = match declaration_span tokens kind name with
        | Some span -> span.start_line, span.start_column
        | None -> 1, 1 in
      Some (line, column, "REHOVOT301", message) in
  let require = function Ok _ -> () | Error message -> raise (Oct_check.Invalid message) in
  (* AML validates form bodies/resources; the source checker consumes their
     declared call signatures when checking ordinary function bodies. *)
  let function_scope = { scope with funcs = scope.funcs @ List.map Oct_form_check.lower scope.forms } in
  List.filter_map (fun fn -> check "function" fn.fn_name (fun () ->
    if scope.forms <> [] then require (Oct_form_check.check_func scope fn);
    Oct_check.check_func function_scope fn)) own.funcs
  @ List.filter_map (fun form -> check "form" form.fm_name (fun () ->
      require (Oct_form_check.build scope [] [] form.fm_name))) own.forms
  @ List.filter_map (fun item -> check "constant" item.c_name (fun () -> Oct_check.check_const function_scope item)) own.consts
  @ (Option.to_list own.ctor |> List.filter_map (fun fn ->
      check "constructor" "constructor" (fun () -> Oct_check.check_ctor function_scope fn))))

let import_diagnostics overlays path source =
  Source_graph.validate ~check:type_diagnostics ~overlays ~path source
  |> List.map (fun (line, column, code, message) -> diagnostic ~column ~code line message)

let check ?(overlays = []) path json =
  let source = In_channel.with_open_bin path In_channel.input_all in
  try
    let contract = Oct_parse.parse source in
    (* Validate dependencies separately: their source positions and contract
       state belong to those files, not to the importing document. *)
    let import_diagnostics = import_diagnostics overlays path source in
    let diagnostics = import_diagnostics @ verifier_diagnostics source contract in
    if json then List.iter (fun item -> print_endline (to_string item)) diagnostics
    else if diagnostics = [] then print_endline "ok"
    else List.iter (fun item -> prerr_endline (Yojson.Safe.Util.member "message" item |> Yojson.Safe.Util.to_string)) diagnostics;
    if List.exists (fun item -> Yojson.Safe.Util.member "severity" item = `String "error") diagnostics then 1 else 0
  with
  | Oct_lex.LexError (message, line, column) ->
      if json then print_endline (to_string (diagnostic ~column line message)) else prerr_endline message;
      1
  | Oct_parse.ParseError (message, line, column) ->
      if json then print_endline (to_string (diagnostic ~column line message)) else prerr_endline message;
      1

let symbols_command path =
  let source = In_channel.with_open_bin path In_channel.input_all in
  try
    print_endline (to_string (symbols source (Oct_parse.parse source)));
    0
  with
  | Oct_lex.LexError (message, line, column) ->
      print_endline (to_string (diagnostic ~column line message)); 1
  | Oct_parse.ParseError (message, line, column) ->
      print_endline (to_string (diagnostic ~column line message)); 1

let read_overlays file =
  Yojson.Safe.from_file file |> Yojson.Safe.Util.to_assoc
  |> List.map (fun (path, text) -> path, Yojson.Safe.Util.to_string text)

let analysis_metadata overlays path =
  let source = In_channel.with_open_bin path In_channel.input_all in
  let fields = try match symbols source (Oct_parse.parse source) with
    | `Assoc fields -> fields | _ -> []
    with Oct_parse.ParseError _ | Oct_lex.LexError _ -> [] in
  print_endline (to_string (`Assoc (("dependencies", Source_graph.dependencies ~overlays ~path source) :: fields)))

let () =
  match Array.to_list Sys.argv with
  | [_; "check"; path; "--analysis-metadata=json"] -> analysis_metadata [] path
  | [_; "check"; path; "--analysis-metadata=json"; "--overlays=json"; file] ->
      analysis_metadata (read_overlays file) path
  | _ :: "check" :: path :: (("--definition=json" | "--completion=json" | "--references=json" | "--rename=json") as query) :: offset :: options ->
      let logical_path, options = match options with
        | "--source-path" :: source_path :: rest -> source_path, rest
        | _ -> path, options in
      let roots, options = match options with
        | "--workspace-roots=json" :: json :: rest ->
            (Yojson.Safe.from_string json |> Yojson.Safe.Util.to_list
              |> List.map Yojson.Safe.Util.to_string), rest
        | _ -> [], options in
      let replacement, options = match options with
        | "--new-name" :: name :: rest -> Some name, rest
        | _ -> None, options in
      let overlays = match options with
        | [] -> []
        | ["--overlays=json"; file] ->
            read_overlays file
        | _ -> invalid_arg "editor query options" in
      let source = In_channel.with_open_bin path In_channel.input_all in
      if query = "--rename=json" then
        print_endline (to_string (Editor_queries.rename ~overlays ~roots ?replacement ~path:logical_path source (int_of_string offset)))
      else if query = "--references=json" then
        print_endline (to_string (Editor_queries.references ~overlays ~roots ~path:logical_path source (int_of_string offset)))
      else if query = "--definition=json" then
        print_endline (to_string (Editor_queries.definition ~overlays ~path:logical_path source (int_of_string offset)))
      else
      let items = Editor_queries.complete ~overlays ~type_name ~path source (int_of_string offset) in
      print_endline (to_string (`Assoc ["items", `List items;
        "suppressFallback", `Bool (not (Editor_queries.in_code source (int_of_string offset)))]))
  | [_; "check"; path; "--diagnostics=json"; "--overlays=json"; file] ->
      exit (check ~overlays:(read_overlays file) path true)
  | [_; "check"; path; "--diagnostics=json"] -> exit (check path true)
  | [_; "check"; path; "--symbols=json"] -> exit (symbols_command path)
  | [_; "check"; path] -> exit (check path false)
  | _ -> prerr_endline "usage: rehovot-check check FILE [--diagnostics=json|--symbols=json]"; exit 64
