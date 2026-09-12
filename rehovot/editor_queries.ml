(* Cursor queries reuse the compiler parser without changing diagnostic input. *)
open Oct_lang
open Oct_lex

type binding = { name : string; typ : typ option; kind : int }

let binding ?typ ?(kind = 6) name = { name; typ; kind }

let unique bindings =
  let seen = Hashtbl.create 16 in
  List.filter (fun item ->
    if Hashtbl.mem seen item.name then false
    else (Hashtbl.add seen item.name (); true)) bindings

let find_type env name =
  Option.bind (List.find_opt (fun item -> item.name = name) env) (fun item -> item.typ)

let unambiguous name items =
  let counts = Hashtbl.create 16 in
  List.iter (fun item ->
    let key = name item in
    Hashtbl.replace counts key (1 + Option.value ~default:0 (Hashtbl.find_opt counts key))) items;
  List.filter (fun item -> Hashtbl.find counts (name item) = 1) items

(* Infer only shapes evident from parsed expressions. Unknown types remain
   absent rather than being advertised as int or a guessed receiver type. *)
let rec expression_type functions env = function
  | EInt _ -> Some TInt
  | EBool _ -> Some TBool
  | EString _ -> Some TString
  | EVar name -> find_type env name
  | ECall (name, _) ->
      (* A local binding can shadow a function. Only trust unshadowed signatures;
         evaluating bodies would make a cursor query a second type checker. *)
      if List.exists (fun item -> item.name = name) env then None
      else find_type functions name
  | ECaller | EOrigin | ESelfAddr -> Some TAddress
  | EBinop ((Eq | Neq | Lt | Gt | Le | Ge | And | Or), _, _) -> Some TBool
  | EBinop (_, left, right) ->
      let l = expression_type functions env left and r = expression_type functions env right in
      if l = r then l else None
  | EUnop (Not, _) -> Some TBool
  | EUnop (Neg, value) -> expression_type functions env value
  | ETuple values ->
      let types = List.map (expression_type functions env) values in
      if List.for_all Option.is_some types then Some (TTuple (List.map Option.get types)) else None
  | _ -> None

let byte_position source =
  (* Index once per scan: restarting at byte zero for every token makes
     cursor queries quadratic in the number of source lines. *)
  let starts = ref [0] in
  String.iteri (fun i c -> if c = '\n' then starts := (i + 1) :: !starts) source;
  let starts = Array.of_list (List.rev !starts) in
  fun line column -> starts.(line - 1) + column - 1

let locals ?(functions = []) ?(strict = false) source offset =
  let position = byte_position source in
  let token_start ts = position ts.lx.token_line ts.lx.token_col in
  let rec trim_end i =
    if i > 0 && List.mem source.[i - 1] [' '; '\t'; '\r'; '\n'] then trim_end (i - 1) else i in
  let ts = make_stream source in
  let scopes = ref [[]] in
  let pending = ref [] in
  let in_function = ref false in
  let function_depth = ref 0 in
  let add value = match !scopes with
    | scope :: rest -> scopes := (value :: scope) :: rest
    | [] -> () in
  let env () = List.concat !scopes in
  let add_stmt = function
    | SLet (name, explicit, value) ->
        let typ = match explicit with Some _ -> explicit | None -> expression_type functions (env ()) value in
        add (binding ?typ name)
    | SLetTuple (names, value) ->
        let types = match expression_type functions (env ()) value with
          | Some (TTuple types) when List.length types = List.length names -> List.map Option.some types
          | _ -> List.map (fun _ -> None) names in
        List.iter2 (fun name typ -> add (binding ?typ name)) names types
    | _ -> () in
  let rec scan () =
    let token = peek_token ts in
    if ts.lx.pos > offset || token = TkEOF then () else begin
      begin match token with
      | TkFn | TkConstructor ->
          eat ts;
          if token = TkFn then ignore (Oct_parse.expect_ident ts);
          let parameters = Oct_parse.parse_params ts in
          pending := List.map (fun p -> binding ~typ:p.p_typ ~kind:6 p.p_name) parameters;
          (* The return type may contain delimiters but cannot introduce a scope. *)
          if peek_token ts = TkColon then (eat ts; ignore (Oct_parse.parse_type ts));
          if peek_token ts = TkLBrace && ts.lx.pos <= offset then begin
            in_function := true;
            function_depth := List.length !scopes + 1
          end
      | TkLBrace ->
          scopes := !pending :: !scopes; pending := []; eat ts
      | TkRBrace ->
          if List.length !scopes = !function_depth then in_function := false;
          (match !scopes with _ :: (_ :: _ as rest) -> scopes := rest | _ -> ());
          eat ts
      | TkLet when !in_function ->
          let stmt = Oct_parse.parse_let ts in
          (* parse_let can look ahead into the next token. token_start marks
             the end of the initializer, including a newline or following }. *)
          let next = peek_token ts in
          let end_offset = trim_end (if next = TkEOF then String.length source else token_start ts) in
          if end_offset <= offset then add_stmt stmt
      | TkFor when !in_function ->
          eat ts;
          let name = Oct_parse.expect_ident ts in
          expect ts TkIn;
          let typ = if peek_token ts = TkSelf then begin
            eat ts; expect ts TkDot; ignore (Oct_parse.expect_ident ts); None
          end else begin
            let first = Oct_parse.parse_expr ts in
            expect ts TkDotDot;
            ignore (Oct_parse.parse_expr ts);
            expression_type functions (env ()) first
          end in
          if peek_token ts = TkLBrace then pending := [binding ?typ name]
      | _ -> eat ts
      end;
      scan ()
    end in
  (* Incomplete trailing statements are expected while typing. Successfully
     parsed earlier bindings remain valid; no failed declaration is added. *)
  (try scan () with (Oct_parse.ParseError _ | LexError _) as error -> if strict then raise error);
  if !in_function then unique (env ()) else []

let identifier = function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false

let in_code source offset =
  let lexer = create source in
  let position = byte_position source in
  let rec scan () =
    let token = next_token lexer in
    let start = position lexer.token_line lexer.token_col in
    let line_comment_end = token = TkNewline && offset = lexer.pos
      && start + 1 < String.length source
      && source.[start] = '/' && source.[start + 1] = '/'
      && (offset = 0 || source.[offset - 1] <> '\n') in
    if start <= offset && (offset < lexer.pos || line_comment_end) then
      match token with
      | TkStrLit _ -> false
      | TkNewline when start + 1 < String.length source
          && source.[start] = '/' && List.mem source.[start + 1] ['*'; '/'] -> false
      | _ -> true
    else if token = TkEOF then true else scan () in
  try scan () with LexError _ -> false

let completion_context source offset =
  let rec left i = if i > 0 && identifier source.[i - 1] then left (i - 1) else i in
  let first = left offset in
  let prefix = String.sub source first (offset - first) in
  let receiver = if first > 0 && source.[first - 1] = '.' then
      let lexer = create (String.sub source 0 (first - 1)) in
      let position = byte_position source in
      let rec tokens found = match next_token lexer with
        | TkEOF -> found
        | token -> tokens ((token, position lexer.token_line lexer.token_col) :: found) in
      let rec brackets depth = function
        | (TkRBrack, _) :: rest -> brackets (depth + 1) rest
        | (TkLBrack, _) :: rest when depth = 1 -> path_left rest
        | (TkLBrack, _) :: rest -> brackets (depth - 1) rest
        | _ :: rest -> brackets depth rest
        | [] -> first - 1
      and path_left = function
        | ((TkIdent _ | TkSelf), start) :: (TkDot, _) :: rest ->
            min start (path_left rest)
        | ((TkIdent _ | TkSelf), start) :: _ -> start
        | (TkRBrack, _) :: rest -> brackets 1 rest
        | _ -> first - 1 in
      let start = try path_left (tokens []) with LexError _ -> first - 1 in
      Some (String.sub source start (first - 1 - start), start)
    else None in
  first, prefix, receiver

let parsed_at_cursor ?placeholder source offset =
  let first, _, receiver = completion_context source offset in
  let start = match receiver with Some (_, start) -> start | None -> first in
  let rec right i = if i < String.length source && identifier source.[i] then right (i + 1) else i in
  let finish = right offset in
  let repair placeholder = String.sub source 0 start ^ placeholder ^ String.sub source finish (String.length source - finish) in
  let parse source = try Some (Oct_parse.syntax source) with Oct_parse.ParseError _ | LexError _ -> None in
  match (if Option.is_some placeholder then None else parse source) with
  | Some program -> Some program
  | None ->
      (* The placeholder belongs only to the editor query. Diagnostics still
         parse the original source. Missing trailing braces are recoverable. *)
      (match placeholder with Some value -> [value]
       | None -> ["0"; "__aml_editor_placeholder"; "__aml_editor_placeholder()"])
      |> List.find_map (fun placeholder ->
        let repaired = repair placeholder in
        let lexer = create repaired in
        let rec braces depth = match next_token lexer with
          | TkEOF -> depth
          | TkLBrace -> braces (depth + 1)
          | TkRBrace -> braces (depth - 1)
          | _ -> braces depth in
        try
          let depth = braces 0 in
          if depth >= 0 && depth <= 64 then parse (repaired ^ String.make depth '}') else None
        with LexError _ -> None)

let form_locals source offset =
  let lexer = create source in
  let rec names found = match next_token lexer with
    | TkEOF -> found | TkIdent name -> names (name :: found) | _ -> names found in
  let used = try names [] with LexError _ -> [] in
  let rec fresh index =
    let name = "__aml_editor_cursor_" ^ string_of_int index in
    if List.mem name used then fresh (index + 1) else name in
  let marker = fresh 0 in
  (* Insert a unique expression marker, then walk the compiler AST to that
     point. This preserves expression scopes without parsing form syntax twice. *)
  let rec find env = function
    | EVar name | ECall (name, _) when name = marker -> Some env
    | ELet (name, _, typ, value, body) ->
        first [find env value; find (binding ~typ name :: env) body]
    | ESplit (value, (left, _, lt), (right, _, rt), body) ->
        first [find env value; find (binding ~typ:lt left :: binding ~typ:rt right :: env) body]
    | EOrbit (_, turns, seed, (name, _, typ), body) ->
        first [Option.bind turns (find env); find env seed; find (binding ~typ name :: env) body]
    | EUse use ->
        if use.ux_name = marker then Some env else
        first (List.map (find env) (use.ux_caps @ [use.ux_arg])
          @ [find (binding ~typ:use.ux_typ use.ux_bind :: env) use.ux_body])
    | EBinop (_, left, right) | EEqual (_, left, right) -> first [find env left; find env right]
    | EUnop (_, value) | EBalance value | EAction (_, value) -> find env value
    | ETernary (condition, yes, no) -> first (List.map (find env) [condition; yes; no])
    | ECall (_, values) | EArray values | ETuple values | EIndex (_, values)
    | EStoragePath (_, values, _) | EIndexField (_, values, _) -> first (List.map (find env) values)
    | _ -> None
  and first values = List.find_map Fun.id values in
  match parsed_at_cursor ~placeholder:marker source offset with
  | None -> []
  | Some program ->
      program.forms |> List.find_map (fun form ->
        find (List.map (fun p -> binding ~typ:p.fp_typ p.fp_name) form.fm_params) form.fm_body)
      |> Option.value ~default:[] |> unique

let canonical_path path =
  try Unix.realpath path with Unix.Unix_error _ ->
    Filename.concat (Unix.realpath (Filename.dirname path)) (Filename.basename path)

let imported_programs overlays path program =
  let seen = Hashtbl.create 16 in
  let visit base program =
    program.imports |> List.concat_map (fun imported ->
      try
        let target = canonical_path (Filename.concat base imported.imp_path) in
        let overlay = List.assoc_opt target overlays in
        if (Hashtbl.length seen >= 32 && not (Hashtbl.mem seen target))
            || (match overlay with Some text -> String.length text
                | None -> (Unix.stat target).Unix.st_size) > 1_000_000 then [] else begin
          let source, ast = match Hashtbl.find_opt seen target with
            | Some value -> value
            | None ->
                let source = match overlay with Some text -> text
                  | None -> In_channel.with_open_bin target In_channel.input_all in
                let ast = Oct_parse.syntax source in
                Hashtbl.add seen target (source, ast);
                source, ast in
          [target, source, imported.imp_names, ast]
        end
      with Sys_error _ | Unix.Unix_error _ | Oct_parse.ParseError _ | LexError _ -> []) in
  (* Repeated clauses for one canonical file denote the same declarations,
     not competing definitions from different modules. *)
  visit (Filename.dirname path) program |> List.fold_left (fun imports (target, source, names, ast) ->
    match List.find_opt (fun (path, _, _, _) -> path = target) imports with
    | None -> imports @ [target, source, names, ast]
    | Some (_, _, previous, _) ->
        List.map (fun ((path, _, _, _) as item) ->
          if path = target then target, source, List.sort_uniq String.compare (previous @ names), ast
          else item) imports) []

let exports names program =
  let wanted name = names = [] || List.mem name names in
  (program.funcs |> List.filter (fun fn -> fn.fn_vis = Public && wanted fn.fn_name)
    |> List.map (fun fn -> binding ~typ:fn.fn_ret ~kind:3 fn.fn_name))
  @ (program.structs |> List.filter (fun s -> wanted s.sd_name)
    |> List.map (fun s -> binding ~typ:(TStruct s.sd_name) ~kind:22 s.sd_name))
  @ (program.consts |> List.filter (fun c -> wanted c.c_name)
    |> List.map (fun c -> binding ~typ:c.c_typ ~kind:21 c.c_name))
  @ (program.interfaces |> List.filter (fun i -> wanted i.if_name)
    |> List.map (fun i -> binding ~kind:8 i.if_name))

let complete ?(overlays = []) ~type_name ~path source offset =
  if offset < 0 || offset > String.length source then invalid_arg "completion offset";
  if not (in_code source offset) then [] else
  let _, prefix, receiver = completion_context source offset in
  let program = parsed_at_cursor source offset in
  let imports = match program with None -> [] | Some p -> imported_programs overlays path p in
  let imported = imports |> List.concat_map (fun (_, _, names, p) -> exports names p) in
  let functions = match program with None -> [] | Some p ->
    List.map (fun fn -> binding ~typ:fn.fn_ret ~kind:3 fn.fn_name) p.funcs in
  let declarations = (match program with None -> [] | Some p ->
    functions @ (exports [] p |> List.filter (fun b -> b.kind <> 3))) @ imported
    |> unambiguous (fun item -> item.name) in
  let functions_in_scope = List.filter (fun item -> item.kind = 3) declarations in
  let form_bindings = match program with
    | Some p when p.forms <> [] -> form_locals source offset | _ -> [] in
  let local = locals ~functions:functions_in_scope source offset @ form_bindings in
  let candidates = match receiver, program with
    | None, None -> local
    | None, Some _ -> local @ declarations
    | Some (name, _), Some p ->
        let structs = p.structs @ (imports |> List.concat_map (fun (_, _, names, p) ->
          List.filter (fun s -> List.mem s.sd_name names) p.structs))
          |> unambiguous (fun s -> s.sd_name) in
        let fields = function
          | Some (TStruct typ) ->
              (match List.find_opt (fun s -> s.sd_name = typ) structs with
               | Some s -> List.map (fun (name, typ) -> binding ~typ ~kind:5 name) s.sd_fields
               | None -> [])
          | _ -> [] in
        let state = List.map (fun f -> binding ~typ:f.sf_typ ~kind:5 f.sf_name) p.state in
        let indexed typ keys = List.fold_left (fun typ _ -> match typ with
          | Some (TMap (_, value) | TList value) -> Some value | _ -> None) typ keys in
        (* Local dotted paths are editor-only recovery: the pinned compiler
           still diagnoses unsupported property syntax in the original buffer. *)
        let local_path stream =
          let rec walk typ = match peek_token stream with
            | TkEOF -> fields typ
            | TkDot ->
                eat stream;
                let field = Oct_parse.expect_ident stream in
                walk (find_type (fields typ) field)
            | _ -> [] in
          let root = Oct_parse.expect_ident stream in
          walk (find_type local root) in
        (* Let the compiler parse index expressions (including nested calls and
           string keys); only declared container/struct types are traversed. *)
        if name = "self" then state else
        (try
          let stream = make_stream name in
          if (match peek_token stream with TkIdent root ->
              List.exists (fun item -> item.name = root) local | _ -> false)
          then local_path stream else
          let receiver = Oct_parse.parse_expr stream in
          if peek_token stream <> TkEOF then [] else
          match receiver with
          | EVar name -> fields (find_type local name)
          | EField name -> fields (find_type state name)
          | EIndex (name, keys) -> fields (indexed (find_type state name) keys)
          | EStoragePath (name, keys, path) ->
              List.fold_left (fun members field -> fields (find_type members field))
                (fields (indexed (find_type state name) keys)) path
          | _ -> []
        with Oct_parse.ParseError _ | LexError _ -> [])
    | Some _, None -> [] in
  unique candidates |> List.filter (fun item ->
    String.length item.name >= String.length prefix
    && String.sub item.name 0 (String.length prefix) = prefix)
  |> List.map (fun item ->
    `Assoc (["label", `String item.name; "kind", `Int item.kind;
             "sortText", `String ("0_" ^ item.name)]
      @ match item.typ with None -> [] | Some typ -> ["detail", `String (type_name typ)]))

let definition ?(overlays = []) ~path source offset =
  if offset < 0 || offset > String.length source || not (in_code source offset) then `Null else
  let first, _, receiver = completion_context source offset in
  let rec right i = if i < String.length source && identifier source.[i] then right (i + 1) else i in
  let name = String.sub source first (right offset - first) in
  if receiver <> None || List.exists (fun item -> item.name = name) (locals source offset) then `Null else
  match parsed_at_cursor source offset with
  | None -> `Null
  | Some program when List.exists (fun fn -> fn.fn_name = name) program.funcs
      || List.exists (fun item -> item.name = name) (exports [] program) -> `Null
  | Some program ->
      let targets = imported_programs overlays path program |> List.filter (fun (_, _, names, ast) ->
        List.exists (fun item -> item.name = name) (exports names ast)) in
      (* An ambiguous import must not navigate to whichever file was read first. *)
      (match targets with
       | [target, text, _, _] ->
        let lexer = create text in
        let declaration = function
          | TkFn | TkStruct | TkConst | TkInterface -> true | _ -> false in
        let rec find previous =
          let token = next_token lexer in
          match token with
          | TkIdent found when declaration previous && found = name ->
              let start = byte_position text lexer.token_line lexer.token_col in
              Some (`Assoc ["path", `String target; "start", `Int start; "end", `Int lexer.pos;
                "sourceHash", `String (Digest.to_hex (Digest.string text))])
          | TkEOF -> None
          | TkNewline -> find previous
          | _ -> find token in
        find TkEOF
       | _ -> None)
      |> Option.value ~default:`Null

let workspace_entry name =
  name <> "" && name.[0] <> '.' && not (List.mem name ["_build"; "node_modules"])

let workspace_sources roots overlays =
  let complete = ref (roots <> []) and entries = ref 0 and bytes = ref 0 in
  let files = ref [] and seen = Hashtbl.create 32 in
  let rec visit depth path =
    incr entries;
    if !entries > 4096 || depth > 24 then complete := false else
    try
      let stat = Unix.lstat path in
      match stat.Unix.st_kind with
      | Unix.S_DIR ->
          Sys.readdir path |> Array.to_list |> List.sort String.compare
          |> List.iter (fun name ->
            if workspace_entry name
            then visit (depth + 1) (Filename.concat path name))
      | Unix.S_REG when Filename.check_suffix path ".aml" ->
          let path = canonical_path path in
          if not (Hashtbl.mem seen path) then begin
            Hashtbl.add seen path ();
            let size = match List.assoc_opt path overlays with
              | Some text -> String.length text | None -> stat.Unix.st_size in
            if Hashtbl.length seen > 256 || size > 1_000_000 || !bytes + size > 8_000_000
            then complete := false else begin
              bytes := !bytes + size;
              let text = match List.assoc_opt path overlays with
                | Some text -> text | None -> In_channel.with_open_bin path In_channel.input_all in
              files := (path, text) :: !files
            end
          end
      | Unix.S_LNK -> complete := false
      | _ -> ()
    with Sys_error _ | Unix.Unix_error _ -> complete := false in
  List.iter (fun root -> visit 0 root) roots;
  List.rev !files, !complete

let references ?(overlays = []) ?(roots = []) ~path source offset =
  let workspace, scanned = workspace_sources roots overlays in
  let complete = ref scanned in
  let parse text =
    let program = Oct_parse.syntax text in
    (* Expression-scoped forms and interface methods need distinct symbol
       identities. Do not report name-only matches in these documents. *)
    if program.forms <> [] || program.interfaces <> [] then
      (complete := false; None) else Some program in
  let target path program name =
    let own = List.filter (fun fn -> fn.fn_name = name) program.funcs in
    let imported = imported_programs overlays path program
      |> List.filter (fun (_, _, names, ast) ->
        List.exists (fun b -> b.name = name && b.kind = 3) (exports names ast)) in
    match own, imported with
    | [_], [] when not (List.exists (fun import -> List.mem name import.imp_names) program.imports) -> Some path
    | [], [(target, _, _, _)] -> Some target
    | [], [] when not (List.exists (fun import -> List.mem name import.imp_names) program.imports) -> None
    | _ -> complete := false; None in
  let occurrences text name =
    let lexer = create text and position = byte_position text in
    let rec tokens acc =
      let token = next_token lexer in
      if token = TkEOF then List.rev acc else
      tokens ((token, position lexer.token_line lexer.token_col, lexer.pos) :: acc) in
    let tokens = tokens [] in
    if List.exists (function
      | TkIdent ("use" | "split" | "orbit" | "once" | "many"), _, _ -> true
      | _ -> false) tokens then (complete := false; []) else
    let rec scan previous importing = function
      | [] -> []
      | (token, first, last) :: rest ->
          let importing = if token = TkImport then true
            else if token = TkIdent "from" then false else importing in
          let role = match token, rest with
            | TkIdent found, _ when found = name && previous = TkFn -> Some "declaration"
            | TkIdent found, _ when found = name && importing -> Some "reference"
            | TkIdent found, (TkLParen, _, _) :: _ when found = name && previous <> TkDot
                && not (List.exists (fun b -> b.name = name) (locals ~strict:true text first)) -> Some "reference"
            | _ -> None in
          let remaining = scan (if token = TkNewline then previous else token) importing rest in
          match role with None -> remaining | Some role -> (role, first, last) :: remaining in
    scan TkEOF false tokens in
  let items = try
    if offset < 0 || offset > String.length source || not (in_code source offset) then `List [] else
    let first, _, receiver = completion_context source offset in
    let rec right i = if i < String.length source && identifier source.[i] then right (i + 1) else i in
    let name = String.sub source first (right offset - first) in
    let path = canonical_path path in
    match receiver, parse source with
    | None, Some program when List.exists (fun (_, first, last) -> first <= offset && offset <= last)
        (occurrences source name) ->
        (match target path program name with
         | None -> `List []
         | Some declaration_path ->
             let declaration_text = match List.assoc_opt declaration_path overlays with
               | Some text -> text
               | None when declaration_path = path -> source
               | None -> In_channel.with_open_bin declaration_path In_channel.input_all in
             let documents = (path, source) :: (declaration_path, declaration_text) :: overlays @ workspace in
             let seen = Hashtbl.create 16 in
             `List (documents |> List.concat_map (fun (file, text) ->
               if Hashtbl.mem seen file then []
               else if String.length text > 1_000_000 then (complete := false; []) else begin
                 Hashtbl.add seen file ();
                 try match parse text with
                 | Some ast when target file ast name = Some declaration_path ->
                     occurrences text name |> List.map (fun (role, first, last) ->
                       `Assoc ["path", `String file; "start", `Int first; "end", `Int last;
                         "role", `String role; "sourceHash", `String (Digest.to_hex (Digest.string text))])
                 | _ -> []
                 with Oct_parse.ParseError _ | LexError _ -> complete := false; []
               end)))
    | _ -> `List []
  with Oct_parse.ParseError _ | LexError _ | Sys_error _ | Unix.Unix_error _ ->
    complete := false; `List [] in
  `Assoc ["items", items; "complete", `Bool !complete]

let rename ?(overlays = []) ?(roots = []) ?replacement ~path source offset =
  let member = Yojson.Safe.Util.member and to_list = Yojson.Safe.Util.to_list
  and to_int = Yojson.Safe.Util.to_int and to_string = Yojson.Safe.Util.to_string in
  try
    let result = references ~overlays ~roots ~path source offset in
    let items = result |> member "items" |> to_list in
    if member "complete" result <> `Bool true || items = [] then `Null else
    let path = canonical_path path in
    let current = List.find (fun item ->
      member "path" item = `String path && to_int (member "start" item) <= offset
      && offset <= to_int (member "end" item)) items in
    let first = to_int (member "start" current) and last = to_int (member "end" current) in
    let name = String.sub source first (last - first) in
    let replacement = Option.value ~default:name replacement in
    let lexer = create replacement in
    if next_token lexer <> TkIdent replacement || next_token lexer <> TkEOF then `Null else
    let roots = List.map canonical_path roots in
    let inside file = List.exists (fun root ->
      let prefix = if Filename.check_suffix root "/" then root else root ^ "/" in
      String.length file > String.length prefix
      && String.sub file 0 (String.length prefix) = prefix
      && Filename.check_suffix file ".aml"
      && (String.sub file (String.length prefix) (String.length file - String.length prefix)
          |> String.split_on_char '/' |> List.for_all workspace_entry)) roots in
    let files = items |> List.map (fun item -> to_string (member "path" item))
      |> List.sort_uniq String.compare in
    let valid file =
      if not (inside file) then false else
      let text = if file = path then source else match List.assoc_opt file overlays with
        | Some text -> text | None -> In_channel.with_open_bin file In_channel.input_all in
      let ranges = List.filter (fun item -> member "path" item = `String file) items in
      let hash = `String (Digest.to_hex (Digest.string text)) in
      let positions = Hashtbl.create (List.length ranges) in
      List.iter (fun item -> Hashtbl.replace positions (to_int (member "start" item)) ()) ranges;
      let lexer = create text and position = byte_position text in
      (* Reject rather than guess when a name is also used outside the resolved
         occurrences. This includes shadowed locals and unsupported value uses.
         Any existing new-name identifier is a conservative capture/conflict gate. *)
      let rec tokens () = match next_token lexer with
        | TkEOF -> true
        | TkIdent found when found = name ->
            Hashtbl.mem positions (position lexer.token_line lexer.token_col) && tokens ()
        | TkIdent found when found = replacement -> false
        | _ -> tokens () in
      List.for_all (fun item -> member "sourceHash" item = hash) ranges && tokens ()
      && (let rewritten = List.sort (fun a b -> compare (to_int (member "start" b)) (to_int (member "start" a))) ranges
            |> List.fold_left (fun text item ->
              let first = to_int (member "start" item) and last = to_int (member "end" item) in
              String.sub text 0 first ^ replacement ^ String.sub text last (String.length text - last)) text in
          ignore (Oct_parse.syntax rewritten); true) in
    if List.for_all valid files then `Assoc ["name", `String name; "items", `List items] else `Null
  with Not_found | Invalid_argument _ | Yojson.Safe.Util.Type_error _
     | Oct_parse.ParseError _ | LexError _ | Sys_error _ | Unix.Unix_error _ -> `Null
