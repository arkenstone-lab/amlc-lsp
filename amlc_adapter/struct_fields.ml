open Octra_vm

type symbol = { owner : string; name : string; typ : Oct_lang.typ;
  first : int; last : int; uses : (int * int) list }
type step = Name of string | Index

let byte_of source line column =
  let rec start current offset =
    if current = line then Some offset else
    match String.index_from_opt source offset '\n' with
    | None -> None
    | Some index -> start (current + 1) (index + 1) in
  if line < 1 || column < 1 then None else
  Option.map (fun start -> start + column - 1) (start 1 0)

let path_resolvers (ast : Oct_lang.contract) =
  let state_type name =
    match List.filter (fun (field : Oct_lang.state_field) -> field.sf_name = name) ast.state with
    | [field] -> Some field.sf_typ | _ -> None in
  let struct_field owner name =
    match List.filter (fun (item : Oct_lang.struct_def) -> item.sd_name = owner) ast.structs with
    | [item] ->
        (match List.filter (fun (field, _) -> field = name) item.sd_fields with
         | [_, typ] -> Some typ | _ -> None)
    | _ -> None in
  let rec after_indices = function Index :: rest -> after_indices rest | rest -> rest in
  let rec follow typ = function
    | [] -> Some typ
    | Name name :: rest ->
        (match typ with
         | Oct_lang.TStruct owner ->
             (match struct_field owner name with Some next -> follow next rest | None -> None)
         | _ -> None)
    | Index :: _ -> None in
  let rec walk acc typ = function
    | [] -> Some (List.rev acc, typ)
    | name :: rest ->
        (match typ with
         | Oct_lang.TStruct owner ->
             (match struct_field owner name with
              | Some next -> walk ((owner, name) :: acc) next rest
              | None -> None)
         | _ -> None) in
  let resolve field keys segments =
    match state_type field with
    | None -> []
    | Some typ ->
        let typ = if keys = [] then typ else Oct_gen.map_value_type typ in
        let property =
          match List.rev segments with
          | "length" :: rev_prefix ->
              (match walk [] typ (List.rev rev_prefix) with
               | Some (paths, (Oct_lang.TList _ | Oct_lang.TMap _)) -> Some paths
               | _ -> None)
          | _ -> None in
        match property with
        | Some paths -> paths
        | None ->
            (match walk [] typ segments with Some (paths, _) -> paths | None -> []) in
  let receiver = function
    | Name "self" :: Name field :: Index :: rest ->
        (match state_type field with
         | Some typ -> follow (Oct_gen.map_value_type typ) (after_indices rest)
         | None -> None)
    | Name "self" :: Name field :: rest ->
        (match state_type field with Some typ -> follow typ rest | None -> None)
    | _ -> None in
  resolve, receiver, struct_field

let expected_paths source (ast : Oct_lang.contract) resolve =
  let rec expr_paths = function
    | Oct_lang.EStoragePath (field, keys, segments) ->
        List.concat_map expr_paths keys @ resolve field keys segments
    | Oct_lang.EIndexField (field, keys, leaf) ->
        List.concat_map expr_paths keys @ resolve field keys [leaf]
    | Oct_lang.EIndex (_, values) | Oct_lang.ECall (_, values) | Oct_lang.EArray values
    | Oct_lang.ETuple values -> List.concat_map expr_paths values
    | Oct_lang.EBinop (_, left, right) | Oct_lang.EEqual (_, left, right) ->
        expr_paths left @ expr_paths right
    | Oct_lang.EUnop (_, value) | Oct_lang.EBalance value | Oct_lang.EAction (_, value) ->
        expr_paths value
    | Oct_lang.ETernary (guard, yes, no) ->
        expr_paths guard @ expr_paths yes @ expr_paths no
    | Oct_lang.ELet (_, _, _, value, body) | Oct_lang.ESplit (value, _, _, body) ->
        expr_paths value @ expr_paths body
    | Oct_lang.EOrbit (_, turns, seed, _, body) ->
        List.concat_map expr_paths (Option.to_list turns @ [seed; body])
    | Oct_lang.EUse value ->
        List.concat_map expr_paths (value.ux_caps @ [value.ux_arg; value.ux_body])
    | Oct_lang.EVar _ | Oct_lang.EField _ | Oct_lang.EFieldProp _ | Oct_lang.EEnumVariant _
    | Oct_lang.EInt _ | Oct_lang.EBool _ | Oct_lang.EString _ | Oct_lang.ECaller
    | Oct_lang.EOrigin | Oct_lang.ESelfAddr | Oct_lang.EEpoch | Oct_lang.EEpochTime
    | Oct_lang.EValue | Oct_lang.ETreeHash | Oct_lang.ENodeId | Oct_lang.ETxHash -> [] in
  let rec stmt_paths = function
    | Oct_lang.SLocated (_, _, value) -> stmt_paths value
    | Oct_lang.SLet (_, _, value) | Oct_lang.SLetTuple (_, value)
    | Oct_lang.SAssign (_, value) | Oct_lang.SFieldSet (_, value)
    | Oct_lang.SAssert value | Oct_lang.SExpr value -> expr_paths value
    | Oct_lang.SReturn value -> List.concat_map expr_paths (Option.to_list value)
    | Oct_lang.SRequire (guard, message) -> expr_paths guard @ expr_paths message
    | Oct_lang.SEmit (_, values) | Oct_lang.SRevertError (_, values) ->
        List.concat_map expr_paths values
    | Oct_lang.SFieldCall (field, name, values) ->
        resolve field [] [name] @ List.concat_map expr_paths values
    | Oct_lang.SIndexSet (_, keys, value) | Oct_lang.SIndexUpdate (_, keys, _, value) ->
        List.concat_map expr_paths (keys @ [value])
    | Oct_lang.SStoragePathSet (field, keys, segments, value)
    | Oct_lang.SStoragePathUpdate (field, keys, segments, _, value) ->
        List.concat_map expr_paths keys @ resolve field keys segments @ expr_paths value
    | Oct_lang.SIndexFieldSet (field, keys, leaf, value) ->
        List.concat_map expr_paths keys @ resolve field keys [leaf] @ expr_paths value
    | Oct_lang.SIf (guard, yes, no) ->
        expr_paths guard @ List.concat_map stmt_paths (yes @ Option.value ~default:[] no)
    | Oct_lang.SWhile (guard, body) -> expr_paths guard @ List.concat_map stmt_paths body
    | Oct_lang.SFor (_, first, last, body) ->
        expr_paths first @ expr_paths last @ List.concat_map stmt_paths body
    | Oct_lang.SForEach (_, _, body) -> List.concat_map stmt_paths body
    | Oct_lang.SMatch (value, arms) ->
        expr_paths value @ List.concat_map (fun (_, _, body) -> List.concat_map stmt_paths body) arms in
  let rec first_statement = function
    | [] -> None
    | Oct_lang.SLocated (line, column, _) :: _ -> byte_of source line column
    | _ :: rest -> first_statement rest in
  let chunks = ref [] in
  let add at paths =
    match at with Some at when paths <> [] -> chunks := (at, paths) :: !chunks | _ -> () in
  (try
     List.iter (fun (fn : Oct_lang.func_def) ->
       add (first_statement fn.fn_body) (List.concat_map stmt_paths fn.fn_body))
       (Option.to_list ast.ctor @ ast.funcs);
     List.iter (fun (form : Oct_lang.form_def) ->
       add (byte_of source form.fm_line form.fm_column) (expr_paths form.fm_body)) ast.forms;
     let stream = Oct_lex.make_stream source in
     let rec tops depth active =
       match Oct_lex.peek_token stream with
       | Oct_lang.TkEOF -> ()
       | Oct_lang.TkConst when depth = 1 && active ->
           let at = byte_of source (Oct_lex.current_line stream) (Oct_lex.current_column stream) in
           Oct_lex.eat stream;
           let item = Oct_parse.parse_const stream in
           add at (expr_paths item.c_value);
           tops depth active
       | Oct_lang.TkIdent "invariant" when depth = 1 && active ->
           let at = byte_of source (Oct_lex.current_line stream) (Oct_lex.current_column stream) in
           let item = Oct_parse.parse_invariant stream in
           add at (expr_paths item.inv_expr);
           tops depth active
       | Oct_lang.TkProgram | Oct_lang.TkContract when depth = 0 ->
           Oct_lex.eat stream; tops depth true
       | Oct_lang.TkLBrace -> Oct_lex.eat stream; tops (depth + 1) active
       | Oct_lang.TkRBrace -> Oct_lex.eat stream; tops (max 0 (depth - 1)) active
       | _ -> Oct_lex.eat stream; tops depth active in
     tops 0 false
   with Oct_parse.ParseError _ | Oct_lex.LexError _ -> chunks := []);
  !chunks |> List.sort (fun (left, _) (right, _) -> compare left right)
    |> List.concat_map snd

let field_declarations source (ast : Oct_lang.contract) =
  let declarations = ref [] in
  let stream = Oct_lex.make_stream source in
  let rec declare depth active =
    match Oct_lex.peek_token stream with
    | Oct_lang.TkEOF -> ()
    | Oct_lang.TkStruct when depth = 1 && active ->
        Oct_lex.eat stream;
        let owner = Oct_parse.expect_ident stream in
        Oct_lex.expect stream Oct_lang.TkLBrace;
        let rec fields acc =
          match Oct_lex.peek_token stream with
          | Oct_lang.TkRBrace -> Oct_lex.eat stream; List.rev acc
          | Oct_lang.TkEOF -> []
          | _ ->
              let name = Oct_parse.expect_ident stream in
              let last = stream.lx.pos in
              Oct_lex.expect stream Oct_lang.TkColon;
              let typ = Oct_parse.parse_type stream in
              if Oct_lex.peek_token stream = Oct_lang.TkComma then Oct_lex.eat stream;
              fields ({ owner; name; typ; first = last - String.length name; last; uses = [] } :: acc) in
        let fields = fields [] in
        (match List.filter (fun (item : Oct_lang.struct_def) -> item.sd_name = owner) ast.structs with
         | [item] when List.map (fun (symbol : symbol) -> symbol.name, symbol.typ) fields = item.sd_fields ->
             declarations := fields :: !declarations
         | _ -> ());
        declare depth active
    | Oct_lang.TkProgram | Oct_lang.TkContract when depth = 0 ->
        Oct_lex.eat stream; declare depth true
    | Oct_lang.TkLBrace -> Oct_lex.eat stream; declare (depth + 1) active
    | Oct_lang.TkRBrace -> Oct_lex.eat stream; declare (max 0 (depth - 1)) active
    | _ -> Oct_lex.eat stream; declare depth active in
  declare 0 false;
  List.concat (List.rev !declarations)

let field_uses source receiver struct_field =
  let found = ref [] in
  let stream = Oct_lex.make_stream source in
  let chain = ref [] and after_dot = ref false and indices = ref [] in
  let rec scan () =
    match Oct_lex.peek_token stream with
    | Oct_lang.TkEOF -> ()
    | token when Oct_parse.ident token ->
        let name = Oct_parse.expect_ident stream in
        let last = stream.lx.pos in
        if !after_dot then begin
          (match receiver (List.rev !chain) with
           | Some (Oct_lang.TStruct owner) when Option.is_some (struct_field owner name) ->
               found := (owner, name, last - String.length name, last) :: !found
           | _ -> ());
          chain := Name name :: !chain
        end else chain := [Name name];
        after_dot := false;
        scan ()
    | _ ->
        (match Oct_lex.peek_token stream with
         | Oct_lang.TkSelf -> chain := [Name "self"]; after_dot := false
         | Oct_lang.TkLBrack ->
             indices := !chain :: !indices; chain := []; after_dot := false
         | Oct_lang.TkRBrack ->
             (match !indices with
              | saved :: rest -> chain := Index :: saved; indices := rest
              | [] -> chain := []);
             after_dot := false
         | Oct_lang.TkDot -> after_dot := true
         | _ -> chain := []; after_dot := false);
        Oct_lex.eat stream;
        scan () in
  scan ();
  List.rev !found

let symbols source (ast : Oct_lang.contract) =
  if ast.structs = [] then [] else
  let resolve, receiver, struct_field = path_resolvers ast in
  let expected = expected_paths source ast resolve in
  let declarations, found =
    try
      let declarations = field_declarations source ast in
      let found = field_uses source receiver struct_field in
      declarations, found
    with Oct_parse.ParseError _ | Oct_lex.LexError _ -> [], [] in
  let uses = if List.map (fun (owner, name, _, _) -> owner, name) found = expected then found else [] in
  let table = Hashtbl.create 16 in
  List.iter (fun (owner, name, first, last) -> Hashtbl.replace table (owner, name)
    ((first, last) :: Option.value ~default:[] (Hashtbl.find_opt table (owner, name)))) uses;
  declarations |> List.map (fun (symbol : symbol) ->
    { symbol with uses = List.sort_uniq compare
        (Option.value ~default:[] (Hashtbl.find_opt table (symbol.owner, symbol.name))) })
