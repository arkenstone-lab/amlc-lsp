open Octra_vm

type syntax = Auto | Term | Callable
type span = { first : int; last : int }
type diagnostic = { message : string; span : span option }
type declaration = {
  name : string;
  kind : string;
  parameters : string list;
  parameter_types : string list;
  return_type : string option;
  selection : span option;
  visibility : span list;
  uses : span list;
}
type status = Checked | Needs_imports of string list | Input_too_large
type member_site = { member_start : int; member_end : int; items : (string * string * int) list }
type signature_site = { signature_start : int; signature_end : int; signature_name : string;
  signature_parameters : (string * string) list; signature_return : string; parameter : int }
type analysis = {
  status : status;
  diagnostics : diagnostic list;
  declarations : declaration list;
  members : member_site list;
  signatures : signature_site list;
  formatting : (int * int * int) list option;
}

let result ?(status = Checked) ?(diagnostics = []) ?(members = []) ?(signatures = []) ?formatting declarations =
  { status; diagnostics; declarations; members; signatures; formatting }

let declaration ?(parameters = []) ?(parameter_types = []) ?return_type kind name =
  { name; kind; parameters; parameter_types; return_type; selection = None;
    visibility = []; uses = [] }

let error ?span message = { message; span }

let source_span source first last =
  if first < 0 || last < first || last > String.length source then None
  else Some { first; last }

(* Oct_* errors provide a point, not a token range. Preserve that distinction;
   callers can convert the byte offset to UTF-16 without guessing an end. *)
let point source line column =
  let rec start current offset =
    if current = line then Some offset
    else match String.index_from_opt source offset '\n' with
      | None -> None
      | Some index -> start (current + 1) (index + 1)
  in
  if line < 1 || column < 1 then None else
  Option.bind (start 1 0) (fun start ->
    let finish = Option.value ~default:(String.length source)
        (String.index_from_opt source start '\n') in
    let offset = start + column - 1 in
    if offset > finish then None else source_span source offset offset)

let term_error source (value : C_parse.error) =
  error ?span:(source_span source value.span.first.off value.span.last.off)
    (C_parse.text value)

type token = Start of string | Name of string | Open | Close | Public | Other

(* Match lexer tokens to parsed declarations, never comments, strings or uses.
   These ranges identify declarations only; they do not resolve references. *)
let locate declarations tokens =
  let rec scan depth active acc = function
    | (Start "constructor", span) :: rest when depth = 1 && active ->
        scan depth active (("constructor", "constructor", span) :: acc) rest
    | (Start kind, _) :: (Name name, span) :: rest
      when (depth = 0 && List.mem kind ["program"; "contract"])
        || (depth = 1 && active && List.mem kind ["function"; "form"; "struct"]) ->
        scan depth true ((kind, name, span) :: acc) rest
    | (Public, _) :: (Name "main", span) :: rest when depth = 1 && active ->
        scan depth active (("form", "main", span) :: acc) rest
    | (Open, _) :: rest -> scan (depth + 1) active acc rest
    | (Close, _) :: rest -> scan (depth - 1) active acc rest
    | _ :: rest -> scan depth active acc rest
    | [] -> acc in
  let locations = scan 0 false [] tokens in
  List.map (fun declaration ->
    let matches = List.filter (fun (kind, name, _) ->
      kind = declaration.kind && name = declaration.name) locations in
    let selection = match matches with [(_, _, span)] -> span | _ -> None in
    { declaration with selection }) declarations

let term_locations source declarations =
  match C_lex.scan source with
  | Error _ -> declarations
  | Ok items ->
      locate declarations (Array.to_list items |> List.map (fun (item : C_lex.item) ->
        let token = match item.tok with
          | C_lex.Program -> Start "program" | C_lex.Form -> Start "form"
          | C_lex.Ident name -> Name name
          | C_lex.Lbrace -> Open | C_lex.Rbrace -> Close | _ -> Other in
        token, source_span source item.span.first.off item.span.last.off))

let callable_locations source declarations =
  let stream = Oct_lex.make_stream source in
  let rec scan acc =
    let token = Oct_lex.peek_token stream in
    if token = Oct_lang.TkEOF then List.rev acc else
    let mapped = match token with
      | Oct_lang.TkProgram -> Start "program" | Oct_lang.TkContract -> Start "contract"
      | Oct_lang.TkFn -> Start "function" | Oct_lang.TkIdent "form" -> Start "form"
      | Oct_lang.TkStruct -> Start "struct"
      | Oct_lang.TkConstructor -> Start "constructor"
      | Oct_lang.TkIdent name -> Name name | Oct_lang.TkPublic -> Public
      | Oct_lang.TkLBrace -> Open | Oct_lang.TkRBrace -> Close | _ -> Other in
    let span = match mapped with
      | Name name | Start ("constructor" as name) ->
          let last = stream.lx.pos in
          Option.bind (source_span source (last - String.length name) last)
            (fun span -> if String.sub source span.first (last - span.first) = name
              then Some span else None)
      | _ -> None in
    Oct_lex.eat stream;
    scan ((mapped, span) :: acc) in
  locate declarations (scan [])

let imported_declarations source (ast : Oct_lang.contract) =
  let imported = ast.imports |> List.concat_map
    (fun (item : Oct_lang.import_decl) -> item.imp_names) in
  if imported = [] then [] else
  let stream = Oct_lex.make_stream source in
  let uses = Hashtbl.create 8 in
  let rec scan mode found =
    match Oct_lex.peek_token stream with
    | Oct_lang.TkEOF -> List.rev found
    | Oct_lang.TkImport -> Oct_lex.eat stream; scan `Import found
    | Oct_lang.TkImplements -> Oct_lex.eat stream; scan `Implements found
    | Oct_lang.TkIdent "from" when mode = `Import -> Oct_lex.eat stream; scan `Normal found
    | Oct_lang.TkLBrace when mode = `Implements -> Oct_lex.eat stream; scan `Normal found
    | Oct_lang.TkIdent name when mode = `Import && List.mem name imported ->
        let last = stream.lx.pos in
        let selection = source_span source (last - String.length name) last in
        Oct_lex.eat stream;
        scan mode ({ (declaration "import" name) with selection } :: found)
    | Oct_lang.TkIdent name when mode = `Implements && List.mem name imported ->
        let last = stream.lx.pos in
        Option.iter (fun span -> Hashtbl.replace uses name
          (span :: Option.value ~default:[] (Hashtbl.find_opt uses name)))
          (source_span source (last - String.length name) last);
        Oct_lex.eat stream; scan mode found
    | _ -> Oct_lex.eat stream; scan mode found in
  scan `Normal [] |> List.map (fun item ->
    { item with uses = List.rev (Option.value ~default:[] (Hashtbl.find_opt uses item.name)) })

let interface_declarations source (ast : Oct_lang.contract) =
  let names = List.map (fun (item : Oct_lang.interface_def) -> item.if_name) ast.interfaces in
  let stream = Oct_lex.make_stream source in
  let declarations = Hashtbl.create 8 and uses = Hashtbl.create 8 in
  let rec scan mode =
    match Oct_lex.peek_token stream with
    | Oct_lang.TkEOF -> ()
    | Oct_lang.TkInterface -> Oct_lex.eat stream; scan `Declaration
    | Oct_lang.TkImplements -> Oct_lex.eat stream; scan `Implements
    | Oct_lang.TkLBrace when mode = `Implements -> Oct_lex.eat stream; scan `Normal
    | Oct_lang.TkIdent name when mode = `Declaration && List.mem name names ->
        let last = stream.lx.pos in
        Option.iter (fun span -> Hashtbl.replace declarations name span)
          (source_span source (last - String.length name) last);
        Oct_lex.eat stream; scan `Normal
    | Oct_lang.TkIdent name when mode = `Implements && List.mem name names ->
        let last = stream.lx.pos in
        Option.iter (fun span -> Hashtbl.replace uses name
          (span :: Option.value ~default:[] (Hashtbl.find_opt uses name)))
          (source_span source (last - String.length name) last);
        Oct_lex.eat stream; scan mode
    | _ -> Oct_lex.eat stream; scan mode in
  scan `Normal;
  names |> List.filter_map (fun name -> Option.map (fun selection ->
    { (declaration "interface" name) with selection = Some selection;
      uses = List.rev (Option.value ~default:[] (Hashtbl.find_opt uses name)) })
    (Hashtbl.find_opt declarations name))

(* Call sites require both AST/token agreement and upstream dispatch evidence.
   A same-named builtin or local variable is not a user-function reference. *)
let function_dispatch (ast : Oct_lang.contract) =
  let dispatch = Hashtbl.create 16 in
  (* Form linking can promote a declared pure function ahead of builtin dispatch
     throughout the program. Use the official linked call set, not its name alone. *)
  let linked = lazy (if ast.forms = [] then ast, [] else
    match Oct_form.link ast with
    | Ok (program, direct, _) -> program, direct
    | Error _ -> ast, []) in
  let targets name =
    match Hashtbl.find_opt dispatch name with
    | Some result -> result
    | None ->
    (* Navigation uses this only after original-source checking; signature help
       uses it as provisional declaration metadata. Probe name dispatch
       with typed parameter placeholders, not the caller's expressions: their
       local types need not be reconstructed to distinguish a builtin from a
       user call. No source, diagnostics or argument types are fabricated. *)
    let program, direct = Lazy.force linked in
    let env = Oct_gen.make_env ast.declaration ast.structs ast.enums ast.consts
        ast.state ast.events ast.errors program.funcs
        (List.map (fun (form : Oct_lang.form_def) -> form.fm_name) ast.forms) direct in
    List.iteri (fun label (fn : Oct_lang.func_def) ->
      Hashtbl.add env.func_labels fn.fn_name label) program.funcs;
    let result = match List.find_opt (fun (fn : Oct_lang.func_def) -> fn.fn_name = name) ast.funcs with
      | None -> false
      | Some target ->
          env.locals <- List.mapi (fun index (p : Oct_lang.param) ->
            p.p_name, index, p.p_typ) target.fn_params;
          let args = List.map (fun (p : Oct_lang.param) -> Oct_lang.EVar p.p_name) target.fn_params in
          try
            ignore (Oct_gen.gen_expr env (Oct_lang.ECall (name, args)));
            match env.code, Hashtbl.find_opt env.func_labels name with
            | Contract_vm.CALL_INT (_, label) :: _, Some target -> label = target
            | _ -> false
          with Oct_gen.GenError _ | Failure _ | Invalid_argument _ | Not_found -> false in
    Hashtbl.add dispatch name result;
    result in
  targets

let function_calls source (ast : Oct_lang.contract) declarations =
  let calls = ref [] in
  let targets = function_dispatch ast in
  let rec expressions = function
    | Oct_lang.SLocated (_, _, value) -> expressions value
    | Oct_lang.SLet (_, _, value) | Oct_lang.SLetTuple (_, value)
    | Oct_lang.SAssign (_, value) | Oct_lang.SFieldSet (_, value)
    | Oct_lang.SAssert value | Oct_lang.SExpr value -> [value]
    | Oct_lang.SReturn value -> Option.to_list value
    | Oct_lang.SRequire (guard, message) -> [guard; message]
    | Oct_lang.SEmit (_, values) | Oct_lang.SRevertError (_, values)
    | Oct_lang.SFieldCall (_, _, values) -> values
    | Oct_lang.SIndexSet (_, keys, value) | Oct_lang.SIndexUpdate (_, keys, _, value)
    | Oct_lang.SStoragePathSet (_, keys, _, value)
    | Oct_lang.SStoragePathUpdate (_, keys, _, _, value)
    | Oct_lang.SIndexFieldSet (_, keys, _, value) -> keys @ [value]
    | Oct_lang.SIf (guard, yes, no) -> guard :: List.concat_map expressions
        (yes @ Option.value ~default:[] no)
    | Oct_lang.SWhile (guard, body) -> guard :: List.concat_map expressions body
    | Oct_lang.SFor (_, first, last, body) -> first :: last :: List.concat_map expressions body
    | Oct_lang.SForEach (_, _, body) -> List.concat_map expressions body
    | Oct_lang.SMatch (value, arms) -> value :: List.concat_map (fun (_, _, body) ->
        List.concat_map expressions body) arms in
  let statement = function
    | Oct_lang.SLocated (line, column, value) ->
        Option.iter (fun start ->
          let stream = Oct_lex.make_stream source in
          stream.lx.pos <- start.first;
          stream.lx.line <- line;
          stream.lx.col <- column;
          ignore (Oct_parse.parse_stmt stream);
          ignore (Oct_lex.peek_token stream);
          Option.iter (fun last ->
            List.iter (fun (name, first, last, _) ->
              if targets name then
                Option.iter (fun span -> calls := (name, span) :: !calls)
                  (source_span source first last))
              (Expression_uses.call_spans source start.first last.first
                (Oct_lang.ETuple (expressions value))))
            (point source (Oct_lex.current_line stream) (Oct_lex.current_column stream)))
          (point source line column)
    | _ -> () in
  List.iter (fun (fn : Oct_lang.func_def) -> List.iter statement fn.fn_body) (ast.funcs @ Option.to_list ast.ctor);
  List.map (fun declaration ->
    let uses = if declaration.kind <> "function" then declaration.uses
      else if Option.is_none declaration.selection then []
      else List.filter_map (fun (name, span) ->
        if name = declaration.name then Some span else None) !calls in
    { declaration with uses = List.sort_uniq compare uses }) declarations

let term source =
  match C_parse.parse source with
  | Error value -> result ~diagnostics:[term_error source value] []
  | Ok ast ->
      let declarations =
        declaration "program" (C_syn.name_text (C_parse.name ast)) ::
        List.map (fun (fn : C_fun.fn) ->
          declaration "form" (C_syn.name_text fn.name)
            ~parameters:(List.map (fun (bind : C_syn.bind) -> C_syn.name_text bind.name)
              (fn.arr.caps @ [fn.arr.arg]))) (C_parse.forms ast)
        |> term_locations source in
      match C_parse.check ast with
      | Ok _ -> result ?formatting:(Format_layout.term_lines source) declarations
      | Error value -> result ~diagnostics:[term_error source value] declarations

let rec type_text = function
  | Oct_lang.TMap (key, value) -> "map[" ^ type_text key ^ "]" ^ type_text value
  | Oct_lang.TList typ -> "list[" ^ type_text typ ^ "]"
  | Oct_lang.TOption typ -> "option[" ^ type_text typ ^ "]"
  | Oct_lang.TTuple types -> "(" ^ String.concat ", " (List.map type_text types) ^ ")"
  | typ -> Oct_lang.typ_to_string typ

(* For loops restore locals in both upstream stages. While bodies can be
   indexed in order, but their declarations must block ambiguous outer bindings:
   codegen retains them and emits the condition after the body. If/match emit
   their controlling expression first, but also retain branch-local bindings. *)
let without_scope source first last visibility =
  List.concat_map (fun span ->
    if last <= span.first || first >= span.last then [span] else
    List.filter_map Fun.id [
      (if span.first < first then source_span source span.first first else None);
      (if last < span.last then source_span source last span.last else None)]) visibility

let local_variables ?(record_callable_use = fun _ _ -> ()) ?(record_type_use = fun _ _ -> ())
    source (ast : Oct_lang.contract) declarations =
  let bindings = ref [] in
  let form_names = Hashtbl.create 16 in
  List.iter (fun (form : Oct_lang.form_def) -> Hashtbl.replace form_names form.fm_name ()) ast.forms;
  let pure_names = Hashtbl.create 16 in
  List.iter (fun (fn : Oct_lang.func_def) ->
    if fn.fn_pure && not fn.fn_payable then Hashtbl.replace pure_names fn.fn_name ()) ast.funcs;
  let stream_at offset =
    let stream = Oct_lex.make_stream source in
    for index = 0 to offset - 1 do
      if source.[index] = '\n' then begin
        stream.lx.line <- stream.lx.line + 1;
        stream.lx.col <- 1
      end else stream.lx.col <- stream.lx.col + 1
    done;
    stream.lx.pos <- offset;
    stream in
  let read_type stream =
    let typ, uses = Type_uses.parse stream in
    List.iter (fun (name, first, last) ->
      Option.iter (record_type_use name) (source_span source first last)) uses;
    typ in
  let record_use env name first last =
    match List.assoc_opt name env, source_span source first last with
    | Some (Some binding), Some span ->
        binding := { !binding with uses = span :: !binding.uses }
    | _ -> () in
  let record_expression ?(in_form = false) env first last value =
    let outer, locals, forms = Expression_uses.index source first last value in
    forms |> List.iter (fun (name, first, last) ->
      Option.iter (record_callable_use name) (source_span source first last));
    (* Checked programs have unique callable names. Upstream rejects a direct
       call to a non-direct form before builtin dispatch, even for builtin names.
       Inside form bodies its term checker also resolves declared pure functions. *)
    if ast.forms <> [] then (Expression_uses.call_spans source first last value |> List.iter (fun (name, first, last, _) ->
      if Hashtbl.mem form_names name || (in_form && Hashtbl.mem pure_names name) then
        Option.iter (record_callable_use name) (source_span source first last)));
    List.iter (fun (name, first, last) -> record_use env name first last) outer;
    List.iter (fun (local : Expression_uses.binding) ->
      let header = stream_at local.last in
      Oct_lex.expect header Oct_lang.TkColon;
      ignore (read_type header);
      Option.iter (fun (first, last) -> List.iter (fun binding ->
        if !binding.name = local.name then binding := { !binding with
          visibility = without_scope source first last !binding.visibility }) !bindings) local.scope;
      Option.iter (fun selection -> bindings := ref {
        (declaration "local" local.name) with selection = Some selection;
        return_type = Some (type_text local.typ);
        visibility = Option.to_list (Option.bind local.scope (fun (first, last) -> source_span source first last));
        uses = List.filter_map (fun (first, last) -> source_span source first last) (List.rev local.uses)
      } :: !bindings) (source_span source local.first local.last)) locals in
  let expression env stream =
    ignore (Oct_lex.peek_token stream);
    let first = point source (Oct_lex.current_line stream) (Oct_lex.current_column stream) in
    let value = Oct_parse.parse_expr stream in
    ignore (Oct_lex.peek_token stream);
    let last = point source (Oct_lex.current_line stream) (Oct_lex.current_column stream) in
    match first, last with
    | Some first, Some last -> record_expression env first.first last.first value
    | _ -> () in
  let record_initializer env line column =
    Option.iter (fun start ->
      let stream = stream_at start.first in
      Oct_lex.expect stream Oct_lang.TkLet;
      if Oct_lex.peek_token stream = Oct_lang.TkLParen then begin
        Oct_lex.eat stream;
        ignore (Oct_parse.expect_ident stream);
        while Oct_lex.peek_token stream = Oct_lang.TkComma do
          Oct_lex.eat stream; ignore (Oct_parse.expect_ident stream)
        done;
        Oct_lex.expect stream Oct_lang.TkRParen
      end else begin
        ignore (Oct_parse.expect_ident stream);
        if Oct_lex.peek_token stream = Oct_lang.TkColon then begin
          Oct_lex.eat stream; ignore (read_type stream)
        end
      end;
      Oct_lex.expect stream Oct_lang.TkEq;
      expression env stream) (point source line column) in
  let function_layout name =
    Option.bind (List.find_opt (fun d -> List.mem d.kind ["function"; "constructor"] && d.name = name) declarations)
      (fun d -> Option.map (fun selection ->
        let stream = stream_at selection.last in
        ignore (Oct_parse.parse_params stream);
        let parameters_end = stream.lx.pos in
        (* Only identifier-colon pairs inside the parsed parameter list can
           identify declarations. Refinement uses and type names do not qualify. *)
        let names = ref [] in
        let header = stream_at selection.last in
        while header.lx.pos < parameters_end do
          let token = Oct_lex.peek_token header in
          if Oct_parse.ident token then begin
            let name = Oct_parse.expect_ident header in
            let last = header.lx.pos in
            if Oct_lex.peek_token header = Oct_lang.TkColon then begin
              Option.iter (fun span -> names := (name, span) :: !names)
                (source_span source (last - String.length name) last);
              Oct_lex.eat header;
              ignore (read_type header)
            end
          end else Oct_lex.eat header
        done;
        if Oct_lex.peek_token stream = Oct_lang.TkColon then begin
          Oct_lex.eat stream;
          ignore (read_type stream)
        end;
        ignore (Oct_lex.peek_token stream);
        let first = stream.lx.pos in
        ignore (Oct_parse.parse_block stream);
        first, stream.lx.pos - 1, !names) d.selection) in
  let statement_end line column =
    Option.bind (point source line column) (fun start ->
      let stream = stream_at start.first in
      ignore (Oct_parse.parse_stmt stream);
      (* Expression parsing peeks at the following token. Its start, not the
         lexer's advanced cursor, is the safe visibility boundary. *)
      ignore (Oct_lex.peek_token stream);
      Option.map (fun span -> span.first)
        (point source (Oct_lex.current_line stream) (Oct_lex.current_column stream))) in
  let hide_binding env name first last =
    match List.assoc_opt name env with
    | Some (Some binding) ->
        let visibility = match first, last with
          | Some first, Some last -> without_scope source first last !binding.visibility
          | _ -> [] in
        binding := { !binding with visibility }
    | _ -> () in
  let name_after line column keyword name =
    Option.bind (point source line column) (fun start ->
      let stream = Oct_lex.make_stream source in
      stream.lx.pos <- start.first;
      stream.lx.line <- line;
      stream.lx.col <- column;
      if Oct_lex.peek_token stream <> keyword then None else begin
        Oct_lex.eat stream;
        if not (Oct_parse.ident (Oct_lex.peek_token stream)) then None else
        let actual = Oct_parse.expect_ident stream in
        if actual <> name then None else
        let last = stream.lx.pos in
        source_span source (last - String.length name) last
      end) in
  let block_names names env = List.fold_left (fun env name -> (name, None) :: env) env names in
  let loop_layout env line column field =
    Option.map (fun start ->
      let stream = stream_at start.first in
      Oct_lex.expect stream Oct_lang.TkFor;
      ignore (Oct_parse.expect_ident stream);
      Oct_lex.expect stream Oct_lang.TkIn;
      (match field with
       | Some _ ->
           Oct_lex.expect stream Oct_lang.TkSelf;
           Oct_lex.expect stream Oct_lang.TkDot;
           ignore (Oct_parse.expect_ident stream)
       | None ->
           expression env stream;
           Oct_lex.expect stream Oct_lang.TkDotDot;
           expression env stream);
      ignore (Oct_lex.peek_token stream);
      let first = stream.lx.pos in
      ignore (Oct_parse.parse_block stream);
      first, stream.lx.pos - 1) (point source line column) in
  let rec retained_names = function
    | Oct_lang.SLocated (_, _, value) -> retained_names value
    | Oct_lang.SLet (name, _, _) -> [name]
    | Oct_lang.SLetTuple (names, _) -> names
    | Oct_lang.SWhile (_, body) -> List.concat_map retained_names body
    | Oct_lang.SIf (_, yes, no) -> List.concat_map retained_names
        (yes @ Option.value ~default:[] no)
    | Oct_lang.SMatch (_, arms) -> List.concat_map (fun (_, _, body) ->
        List.concat_map retained_names body) arms
    (* For bodies restore the incoming environment, including nested whiles. *)
    | _ -> [] in
  let rec statement finish env = function
    | Oct_lang.SLocated (line, column, Oct_lang.SLet (name, typ, _)) ->
        record_initializer env line column;
        let start = statement_end line column in
        hide_binding env name start finish;
        let binding = Option.map (fun selection ->
          let value = ref { (declaration "local" name) with selection = Some selection;
            visibility = Option.to_list (Option.bind start (fun first ->
              Option.bind finish (fun last -> source_span source first last)));
            return_type = Option.map type_text typ } in
          bindings := value :: !bindings;
          value) (name_after line column Oct_lang.TkLet name) in
        (name, binding) :: env
    | Oct_lang.SLocated (line, column, Oct_lang.SReturn (Some _)) ->
        Option.iter (fun start ->
          let stream = stream_at start.first in
          Oct_lex.expect stream Oct_lang.TkReturn;
          expression env stream) (point source line column);
        env
    | Oct_lang.SLocated (line, column, Oct_lang.SAssign _) ->
        Option.iter (fun start ->
          let stream = stream_at start.first in
          let name = Oct_parse.expect_ident stream in
          let last = stream.lx.pos in
          record_use env name (last - String.length name) last;
          (match Oct_parse.compound_op stream with
           | Some _ -> () | None -> Oct_lex.expect stream Oct_lang.TkEq);
          expression env stream) (point source line column);
        env
    | Oct_lang.SLocated (line, column, Oct_lang.SLetTuple (names, _)) ->
        record_initializer env line column;
        let start = statement_end line column in
        List.iter (fun name -> hide_binding env name start finish) names;
        let selections = Option.bind (point source line column) (fun first ->
          let stream = stream_at first.first in
          Oct_lex.expect stream Oct_lang.TkLet;
          Oct_lex.expect stream Oct_lang.TkLParen;
          let found = List.mapi (fun index name ->
            if index > 0 then Oct_lex.expect stream Oct_lang.TkComma;
            let actual = Oct_parse.expect_ident stream in
            let last = stream.lx.pos in
            name, (if actual = name then source_span source (last - String.length name) last else None)) names in
          Oct_lex.expect stream Oct_lang.TkRParen;
          Some found) in
        List.fold_left (fun env name ->
          let binding = Option.bind selections (fun selections ->
            Option.join (List.assoc_opt name selections)) |> Option.map (fun selection ->
              let value = ref { (declaration "local" name) with selection = Some selection;
                visibility = Option.to_list (Option.bind start (fun first ->
                  Option.bind finish (fun last -> source_span source first last))) } in
              bindings := value :: !bindings;
              value) in
          (name, binding) :: env) env names
    | Oct_lang.SLocated (line, column, Oct_lang.SFor (name, _, _, body)) ->
        loop line column env name None (Some Oct_lang.TInt) body
    | Oct_lang.SLocated (line, column, Oct_lang.SForEach (name, field, body)) ->
        let typ = Option.bind (List.find_opt (fun (f : Oct_lang.state_field) -> f.sf_name = field) ast.state)
          (fun f -> match f.sf_typ with Oct_lang.TList typ -> Some typ | _ -> None) in
        loop line column env name (Some field) typ body
    | Oct_lang.SLocated (line, column, Oct_lang.SWhile (_, body)) ->
        let names = List.sort_uniq String.compare (List.concat_map retained_names body) in
        let start = Option.map (fun span -> span.first) (point source line column) in
        List.iter (fun name -> hide_binding env name start finish) names;
        let blocked = block_names names env in
        Option.iter (fun start ->
          let stream = stream_at start in
          Oct_lex.expect stream Oct_lang.TkWhile;
          expression blocked stream;
          ignore (Oct_parse.parse_block stream);
          ignore (List.fold_left (statement (Some (stream.lx.pos - 1))) blocked body)) start;
        blocked
    | Oct_lang.SLocated (line, column, (Oct_lang.SIf _ as value)) ->
        let names = List.sort_uniq String.compare (retained_names value) in
        let blocked = block_names names env in
        Option.iter (fun start ->
          let stream = stream_at start.first in
          Oct_lex.expect stream Oct_lang.TkIf;
          expression env stream;
          ignore (Oct_lex.peek_token stream);
          (* The condition is emitted before either branch. From the body
             onward, neither sibling declarations nor their leaked codegen
             bindings may be mistaken for an outer declaration. *)
          List.iter (fun name -> hide_binding env name (Some stream.lx.pos) finish) names;
          let body = Oct_parse.parse_block stream in
          ignore (List.fold_left (statement (Some (stream.lx.pos - 1))) blocked body);
          Oct_parse.skip_stmt_end stream;
          if Oct_lex.peek_token stream = Oct_lang.TkElse then begin
            Oct_lex.eat stream;
            if Oct_lex.peek_token stream = Oct_lang.TkIf then
              (* parse_stmt supplies the location omitted by parse_if's
                 nested else-if AST node. *)
              ignore (statement finish blocked (Oct_parse.parse_stmt stream))
            else begin
              let body = Oct_parse.parse_block stream in
              ignore (List.fold_left (statement (Some (stream.lx.pos - 1))) blocked body)
            end
          end) (point source line column);
        blocked
    | Oct_lang.SLocated (line, column, (Oct_lang.SMatch _ as value)) ->
        let names = List.sort_uniq String.compare (retained_names value) in
        let blocked = block_names names env in
        Option.iter (fun start ->
          let stream = stream_at start.first in
          Oct_lex.expect stream Oct_lang.TkMatch;
          expression env stream;
          Oct_lex.expect stream Oct_lang.TkLBrace;
          List.iter (fun name -> hide_binding env name (Some stream.lx.pos) finish) names;
          let rec arms () =
            Oct_parse.skip_stmt_end stream;
            if Oct_lex.peek_token stream <> Oct_lang.TkRBrace then begin
              ignore (Oct_parse.expect_ident stream);
              Oct_lex.expect stream Oct_lang.TkDot;
              ignore (Oct_parse.expect_ident stream);
              Oct_lex.expect stream Oct_lang.TkFatArrow;
              let body, last =
                if Oct_lex.peek_token stream = Oct_lang.TkLBrace then
                  let body = Oct_parse.parse_block stream in body, Some (stream.lx.pos - 1)
                else
                  let body = Oct_parse.parse_stmt stream in
                  ignore (Oct_lex.peek_token stream);
                  [body], Option.map (fun span -> span.first)
                    (point source (Oct_lex.current_line stream) (Oct_lex.current_column stream)) in
              ignore (List.fold_left (statement last) blocked body);
              arms ()
            end in
          arms ()) (point source line column);
        blocked
    | Oct_lang.SLocated (line, column, value) ->
        let values = match value with
          | Oct_lang.SAssert value | Oct_lang.SExpr value
          | Oct_lang.SFieldSet (_, value) -> [value]
          | Oct_lang.SRequire (guard, message) -> [guard; message]
          | Oct_lang.SEmit (_, values) | Oct_lang.SFieldCall (_, _, values)
          | Oct_lang.SRevertError (_, values) -> values
          | Oct_lang.SIndexSet (_, keys, value) | Oct_lang.SIndexUpdate (_, keys, _, value)
          | Oct_lang.SStoragePathSet (_, keys, _, value)
          | Oct_lang.SStoragePathUpdate (_, keys, _, _, value)
          | Oct_lang.SIndexFieldSet (_, keys, _, value) -> keys @ [value]
          | _ -> [] in
        (match values, point source line column, statement_end line column with
         | _ :: _, Some first, Some last ->
             record_expression env first.first last (Oct_lang.ETuple values)
         | _ -> ());
        statement finish env value
    | Oct_lang.SLet (name, _, _) ->
        hide_binding env name None finish; block_names [name] env
    | Oct_lang.SLetTuple (names, _) ->
        List.iter (fun name -> hide_binding env name None finish) names;
        block_names names env
    | _ -> env
  and loop line column env name field typ body =
    Option.iter (fun (first, last) ->
      hide_binding env name (Some first) (Some last);
      let binding = Option.map (fun selection ->
        let value = ref { (declaration "iterator" name) with selection = Some selection;
          visibility = Option.to_list (source_span source first last);
          return_type = Option.map type_text typ } in
        bindings := value :: !bindings;
        value) (name_after line column Oct_lang.TkFor name) in
      ignore (List.fold_left (statement (Some last)) ((name, binding) :: env) body))
      (loop_layout env line column field);
    env in
  List.iter (fun (fn : Oct_lang.func_def) ->
      let layout = function_layout fn.fn_name in
      let env = List.map (fun (p : Oct_lang.param) ->
        let binding = Option.bind layout (fun (first, last, names) ->
          match List.filter (fun (name, _) -> name = p.p_name) names with
          | [_, selection] ->
              let value = ref { (declaration "parameter" p.p_name) with
                selection = Some selection; visibility = Option.to_list (source_span source first last);
                return_type = Some (type_text p.p_typ) } in
              bindings := value :: !bindings;
              Some value
          | _ -> None) in
        p.p_name, binding) fn.fn_params in
      let finish = Option.map (fun (_, last, _) -> last) layout in
      ignore (List.fold_left (statement finish) env fn.fn_body)) (ast.funcs @ Option.to_list ast.ctor);
  List.iter (fun (form : Oct_lang.form_def) ->
    Option.iter (fun start ->
      let stream = stream_at start.first in
      ignore (Oct_lex.peek_token stream);
      Oct_lex.eat stream;
      let parameters = ref [] in
      let parameter () =
        ignore (Oct_parse.parse_mult stream);
        let name = Oct_parse.expect_ident stream in
        let last = stream.lx.pos in
        Oct_lex.expect stream Oct_lang.TkColon;
        let typ = read_type stream in
        parameters := (name, typ, source_span source (last - String.length name) last) :: !parameters in
      let group close =
        if Oct_lex.peek_token stream <> close then begin
          parameter ();
          while Oct_lex.peek_token stream = Oct_lang.TkComma do
            Oct_lex.eat stream; parameter ()
          done
        end;
        Oct_lex.expect stream close in
      if not form.fm_public then begin
        ignore (Oct_parse.expect_ident stream);
        Oct_lex.expect stream Oct_lang.TkLBrack;
        group Oct_lang.TkRBrack
      end;
      Oct_lex.expect stream Oct_lang.TkLParen;
      group Oct_lang.TkRParen;
      Oct_lex.expect stream Oct_lang.TkMinus;
      Oct_lex.expect stream Oct_lang.TkGt;
      Oct_lex.expect stream Oct_lang.TkLBrack;
      ignore (Oct_parse.parse_mult stream);
      Oct_lex.expect stream Oct_lang.TkRBrack;
      ignore (read_type stream);
      ignore (Oct_parse.expect_ident stream); (* marks, already verified by parse *)
      ignore (Oct_parse.parse_form_marks stream);
      ignore (Oct_parse.parse_form_limit stream);
      Oct_lex.expect stream Oct_lang.TkEq;
      let first = stream.lx.pos in
      ignore (Oct_parse.parse_expr stream);
      ignore (Oct_lex.peek_token stream);
      Option.iter (fun finish ->
        let parameters = List.rev !parameters in
        (* Match the whole header before assigning any source positions. *)
        if List.map (fun (name, typ, _) -> name, typ) parameters =
          List.map (fun (p : Oct_lang.form_param) -> p.fp_name, p.fp_typ) form.fm_params then begin
          let env = List.map (fun (name, typ, selection) ->
            let binding = Option.map (fun selection ->
              let value = ref { (declaration "parameter" name) with selection = Some selection;
                return_type = Some (type_text typ);
                visibility = Option.to_list (source_span source first finish.first) } in
              bindings := value :: !bindings;
              value) selection in
            name, binding) parameters in
          record_expression ~in_form:true env first finish.first form.fm_body
        end) (point source (Oct_lex.current_line stream) (Oct_lex.current_column stream)))
      (point source form.fm_line form.fm_column)) ast.forms;
  List.rev_map (fun binding -> { !binding with uses = List.rev !binding.uses }) !bindings

let callable_declarations source (ast : Oct_lang.contract) =
    (if ast.name = "" then [] else
      [declaration (Oct_lang.declaration_to_string ast.declaration) ast.name]) @
    List.map (fun (kind, (fn : Oct_lang.func_def)) ->
      declaration kind fn.fn_name
        ~parameters:(List.map (fun (p : Oct_lang.param) -> p.p_name) fn.fn_params)
        ~parameter_types:(List.map (fun (p : Oct_lang.param) -> type_text p.p_typ) fn.fn_params)
        ~return_type:(type_text fn.fn_ret))
      (List.map (fun fn -> "function", fn) ast.funcs @ List.map (fun fn -> "constructor", fn) (Option.to_list ast.ctor)) @
    List.map (fun (fn : Oct_lang.form_def) ->
      declaration "form" fn.fm_name
        ~parameters:(List.map (fun (p : Oct_lang.form_param) -> p.fp_name) fn.fm_params)
        ~parameter_types:(List.map (fun (p : Oct_lang.form_param) -> type_text p.fp_typ) fn.fm_params)
        ~return_type:(type_text fn.fm_ret)) ast.forms @
    List.map (fun (s : Oct_lang.struct_def) -> declaration "struct" s.sd_name) ast.structs
    |> callable_locations source
    |> fun declarations -> declarations @ interface_declarations source ast
    |> fun declarations -> declarations @ (Enum_symbols.symbols source ast |> List.map (fun (symbol : Enum_symbols.symbol) ->
      { (declaration ?return_type:symbol.owner (if symbol.owner = None then "enum" else "enumMember") symbol.name) with
        selection = source_span source symbol.first symbol.last;
        uses = List.filter_map (fun (first, last) -> source_span source first last) symbol.uses }))
    |> fun declarations -> declarations @ (State_symbols.symbols source ast |> List.map (fun (symbol : State_symbols.symbol) ->
      { (declaration ~return_type:(type_text symbol.typ) "field" symbol.name) with
        selection = source_span source symbol.first symbol.last;
        uses = List.filter_map (fun (first, last) -> source_span source first last) symbol.uses }))

(* Completion candidates are not proof of binding resolution. Without a checked
   original document, never expose their declaration/use ranges to navigation. *)
let completion_only declarations =
  List.map (fun d -> { d with selection = None; uses = [] }) declarations

let member_sites ?statement_source source ast =
  Members.sites ?statement_source source ast type_text |> List.map (fun (site : Members.site) ->
    { member_start = site.first; member_end = site.last; items = site.items })

let signature_sites source (ast : Oct_lang.contract) =
  let targets = function_dispatch ast in
  let metadata = Hashtbl.create 16 in
  let signature name kind = match Hashtbl.find_opt metadata (name, kind) with
    | Some value -> value
    | None ->
        let forms = List.filter (fun (form : Oct_lang.form_def) -> form.fm_name = name) ast.forms in
        let functions = List.filter (fun (fn : Oct_lang.func_def) -> fn.fn_name = name) ast.funcs in
        let value = match forms, functions with
          | [form], [] when kind <> Call_contexts.Direct ||
              (match Oct_form.build ast [] [] name with Ok (target, _) -> target.direct | Error _ -> false) ->
              Some (List.map (fun (p : Oct_lang.form_param) -> p.fp_name, type_text p.fp_typ) form.fm_params,
                type_text form.fm_ret)
          | [], [fn] when kind = Call_contexts.Direct && targets name -> Some (
              List.map (fun (p : Oct_lang.param) -> p.p_name, type_text p.p_typ) fn.fn_params,
              type_text fn.fn_ret)
          | _ -> None in
        Hashtbl.add metadata (name, kind) value;
        value in
  Call_contexts.sites source |> List.filter_map (fun (site : Call_contexts.site) ->
    Option.bind (signature site.name site.kind) (fun (signature_parameters, signature_return) ->
      let count = List.length signature_parameters in
      if (site.kind = Call_contexts.Captures && count <= 1)
        || (site.kind = Call_contexts.Argument && count = 0) then None else
      let parameter = if site.kind = Call_contexts.Argument then count - 1 else site.parameter in
      Some
      { signature_start = site.first; signature_end = site.last; signature_name = site.name;
        signature_parameters; signature_return; parameter }))

let recover_completions ?before source =
  let rec try_candidates = function
    | [] -> [], [], []
    | (candidate : Recovery.candidate) :: rest ->
        match (try
          let recovered = candidate.text in
          let ast = Oct_parse.parse recovered in
          let declarations = callable_declarations recovered ast in
          Some (declarations @ local_variables recovered ast declarations,
            member_sites ~statement_source:recovered source ast, signature_sites source ast)
        with Oct_parse.ParseError _ | Oct_lex.LexError _ -> None) with
        | None -> try_candidates rest
        | Some (declarations, members, signatures) -> (completion_only declarations |> List.map (fun d ->
            { d with visibility = List.filter_map (fun span ->
                let first = if candidate.eof_anchor && span.first = String.length source + 1
                  then String.length source else span.first in
                source_span source first (min (String.length source) span.last)) d.visibility })), members, signatures in
  try_candidates (Recovery.candidates ?before source)

let callable ?resolve source =
  let ast = Oct_parse.parse source in
  let declarations = callable_declarations source ast in
  let members = member_sites source ast in
  let signatures = signature_sites source ast in
  if ast.imports <> [] && Option.is_none resolve then
    result ~members ~signatures ~status:(Needs_imports
      (List.map (fun (item : Oct_lang.import_decl) -> item.imp_path) ast.imports))
      (List.map (fun d -> { d with uses = [] }) declarations)
  else
    (* Use upstream's complete compile entry point, including scope resolution
       and its own exception handling. Do not substitute Lite Node checks. *)
    let compiled = match resolve with
      | Some resolve when ast.imports <> [] ->
          let rec unused name =
            if List.exists (fun (item : Oct_lang.import_decl) -> item.imp_path = name) ast.imports
            then unused (name ^ "_") else name in
          let main = unused "[current document]" in
          Aml_source.compile_multi
            (fun path -> if path = main then Some source else resolve path) main
      | _ -> Aml_source.compile source in
    match compiled with
    | Ok _ ->
        let calls = Hashtbl.create 16 in
        let types = Hashtbl.create 16 in
        let record_callable_use name span = Hashtbl.replace calls name
          (span :: Option.value ~default:[] (Hashtbl.find_opt calls name)) in
        let record_type_use name span = Hashtbl.replace types name
          (span :: Option.value ~default:[] (Hashtbl.find_opt types name)) in
        if ast.enums <> [] || ast.structs <> [] then Type_uses.declarations source ast |> List.iter (fun (name, first, last) ->
          Option.iter (record_type_use name) (source_span source first last));
        let locals = local_variables ~record_callable_use ~record_type_use source ast declarations in
        let declarations = function_calls source ast declarations |> List.map (fun d ->
          let table = if List.mem d.kind ["enum"; "struct"] then types else calls in
          if not (List.mem d.kind ["form"; "function"; "enum"; "struct"]) || Option.is_none d.selection then d else
          { d with uses = List.sort_uniq compare (d.uses @ Option.value ~default:[] (Hashtbl.find_opt table d.name)) }) in
        let imports = imported_declarations source ast |> List.map (fun d ->
          { d with uses = List.sort_uniq compare
              (d.uses @ Option.value ~default:[] (Hashtbl.find_opt calls d.name)) }) in
        result ~members ~signatures ~formatting:(Format_layout.lines source) (declarations @ imports @ locals)
    | Error message -> result ~members ~signatures ~diagnostics:[error message]
        (List.map (fun d -> { d with uses = [] }) declarations @ completion_only (local_variables source ast declarations))

let analyze ?(syntax = Auto) ?resolve source =
  if String.length source > 1_000_000 then
    result ~status:Input_too_large []
  else
    let callable_source = match syntax with
      | Auto -> Aml_source.owns source
      | Term -> false
      | Callable -> true in
    try
      if callable_source then callable ?resolve source else term source
    with
    | Oct_lex.LexError (message, line, column)
    | Oct_parse.ParseError (message, line, column) ->
        let span = point source line column in
        let declarations, members, signatures = if callable_source then
            recover_completions ?before:(Option.map (fun span -> span.first) span) source else [], [], [] in
        result ~members ~signatures ~diagnostics:[error ?span message] declarations

let workspace_references ~overlays ~roots ~path source offset =
  Workspace_index.references ~overlays ~roots ~path source offset

let workspace_rename ~overlays ~roots ?replacement ~path source offset =
  Workspace_index.rename ~overlays ~roots ?replacement ~path source offset
