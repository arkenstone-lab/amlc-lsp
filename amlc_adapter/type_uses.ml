open Octra_vm

let copy (stream : Oct_lex.token_stream) =
  { stream with lx = { stream.lx with pos = stream.lx.pos } }

let rec names = function
  | Oct_lang.TStruct name | Oct_lang.TEnum name -> [name]
  | Oct_lang.TMap (key, value) -> names key @ names value
  | Oct_lang.TList value | Oct_lang.TOption value -> names value
  | Oct_lang.TTuple values -> List.concat_map names values
  | _ -> []

let parse (stream : Oct_lex.token_stream) =
  let original = copy stream in
  let typ = Oct_parse.parse_type stream in
  ignore (Oct_lex.peek_token stream);
  let finish = Oct_lex.current_line stream, Oct_lex.current_column stream in
  let rec scan found =
    let token = Oct_lex.peek_token original in
    let position = Oct_lex.current_line original, Oct_lex.current_column original in
    if token = Oct_lang.TkEOF || position >= finish then List.rev found else
    if Oct_parse.ident token then begin
      let name = Oct_parse.expect_ident original in
      let last = original.lx.pos in
      scan ((name, last - String.length name, last) :: found)
    end else (Oct_lex.eat original; scan found) in
  let found = scan [] in
  (* The parser's next-token boundary excludes refinements and following code.
     Match all named leaves, rather than searching for a known type's spelling. *)
  typ, if List.map (fun (name, _, _) -> name) found = names typ then found else []

let rec equal_types = function
  | Oct_lang.EEqual (typ, left, right) -> typ :: equal_types left @ equal_types right
  | Oct_lang.EBinop (_, left, right) -> equal_types left @ equal_types right
  | Oct_lang.EUnop (_, value) | Oct_lang.EBalance value | Oct_lang.EAction (_, value) ->
      equal_types value
  | Oct_lang.ECall (_, values) | Oct_lang.EArray values | Oct_lang.ETuple values
  | Oct_lang.EIndex (_, values) -> List.concat_map equal_types values
  | Oct_lang.EStoragePath (_, values, _) | Oct_lang.EIndexField (_, values, _) ->
      List.concat_map equal_types values
  | Oct_lang.ETernary (guard, yes, no) ->
      equal_types guard @ equal_types yes @ equal_types no
  | Oct_lang.ELet (_, _, _, value, body) | Oct_lang.ESplit (value, _, _, body) ->
      equal_types value @ equal_types body
  | Oct_lang.EOrbit (_, turns, seed, _, body) ->
      List.concat_map equal_types (Option.to_list turns @ [seed; body])
  | Oct_lang.EUse value ->
      List.concat_map equal_types (value.ux_caps @ [value.ux_arg; value.ux_body])
  | Oct_lang.EVar _ | Oct_lang.EField _ | Oct_lang.EFieldProp _ | Oct_lang.EEnumVariant _
  | Oct_lang.EInt _ | Oct_lang.EBool _ | Oct_lang.EString _ | Oct_lang.ECaller
  | Oct_lang.EOrigin | Oct_lang.ESelfAddr | Oct_lang.EEpoch | Oct_lang.EEpochTime
  | Oct_lang.EValue | Oct_lang.ETreeHash | Oct_lang.ENodeId | Oct_lang.ETxHash -> []

let expressions source first last expr =
  let expected = equal_types expr in
  if expected = [] || first < 0 || last < first || last > String.length source then [] else
  let stream = Oct_lex.make_stream (String.sub source first (last - first)) in
  let found = ref [] and ok = ref true in
  let rec scan () =
    if !ok then match Oct_lex.peek_token stream with
    | Oct_lang.TkEOF -> ()
    | token when Oct_parse.ident token ->
        let name = Oct_parse.expect_ident stream in
        if name = "equal" && Oct_lex.peek_token stream = Oct_lang.TkLBrack then begin
          Oct_lex.eat stream;
          match (try Some (parse stream) with Oct_parse.ParseError _ | Oct_lex.LexError _ -> None) with
          | Some (typ, uses) when Oct_lex.peek_token stream = Oct_lang.TkRBrack ->
              Oct_lex.eat stream;
              found := (typ, uses) :: !found;
              scan ()
          | _ -> ok := false
        end else scan ()
    | _ -> Oct_lex.eat stream; scan () in
  (try scan () with Oct_parse.ParseError _ | Oct_lex.LexError _ -> ok := false);
  let found = List.rev !found in
  if (not !ok) || List.length found <> List.length expected
     || List.exists2 (fun (typ, _) expected -> typ <> expected) found expected then []
  else List.concat_map (fun (_, uses) ->
    List.map (fun (name, start, finish) -> name, first + start, first + finish) uses) found

let declarations source (ast : Oct_lang.contract) =
  let stream = Oct_lex.make_stream source in
  let found = ref [] in
  let collect original finish indexed =
    let rec scan () =
      let token = Oct_lex.peek_token original in
      if token <> Oct_lang.TkEOF && original.lx.pos <= finish then begin
        if token = Oct_lang.TkColon then begin
          Oct_lex.eat original;
          if indexed && Oct_lex.peek_token original = Oct_lang.TkIdent "indexed" then Oct_lex.eat original;
          let _, uses = parse original in
          found := List.rev_append uses !found
        end else Oct_lex.eat original;
        scan ()
      end in
    scan () in
  let visit parser matches indexed =
    let original = copy stream in
    let value = parser stream in
    (* Colons are type positions only inside a complete declaration that matches
       the official AST. Form effect labels and unrelated expressions stay out. *)
    if matches value then collect original stream.lx.pos indexed in
  let rec scan depth active =
    match Oct_lex.peek_token stream with
    | Oct_lang.TkEOF -> ()
    | Oct_lang.TkInterface when depth = 0 ->
        visit Oct_parse.parse_interface (fun value -> List.mem value ast.interfaces) false;
        scan depth active
    | Oct_lang.TkState when depth = 1 && active ->
        Oct_lex.eat stream;
        visit Oct_parse.parse_state ((=) ast.state) false;
        scan depth active
    | Oct_lang.TkStruct when depth = 1 && active ->
        Oct_lex.eat stream;
        visit Oct_parse.parse_struct_def (fun value -> List.mem value ast.structs) false;
        scan depth active
    | Oct_lang.TkEvent when depth = 1 && active ->
        Oct_lex.eat stream;
        visit Oct_parse.parse_event (fun value -> List.mem value ast.events) true;
        scan depth active
    | Oct_lang.TkConst when depth = 1 && active ->
        Oct_lex.eat stream;
        visit Oct_parse.parse_const (fun value -> List.mem value ast.consts) false;
        scan depth active
    | Oct_lang.TkProgram | Oct_lang.TkContract when depth = 0 ->
        Oct_lex.eat stream; scan depth true
    | Oct_lang.TkLBrace -> Oct_lex.eat stream; scan (depth + 1) active
    | Oct_lang.TkRBrace -> Oct_lex.eat stream; scan (depth - 1) active
    | _ -> Oct_lex.eat stream; scan depth active in
  scan 0 false;
  List.sort_uniq compare !found
