open Octra_vm

type site = { first : int; last : int; items : (string * string * int) list }
type step = Name of string | Index

let sites ?statement_source source (ast : Oct_lang.contract) type_text =
  let statement_source = Option.value ~default:source statement_source in
  let lines = ref [0] in
  String.iteri (fun index ch -> if ch = '\n' then lines := (index + 1) :: !lines) statement_source;
  let lines = Array.of_list (List.rev !lines) in
  let statements = Hashtbl.create 32 in
  let rec statement = function
    | Oct_lang.SLocated (line, column, value) ->
        if line > 0 && line <= Array.length lines && column > 0 then
          Hashtbl.replace statements (lines.(line - 1) + column - 1) ();
        statement value
    | Oct_lang.SIf (_, yes, no) -> List.iter statement (yes @ Option.value ~default:[] no)
    | Oct_lang.SWhile (_, body) | Oct_lang.SFor (_, _, _, body)
    | Oct_lang.SForEach (_, _, body) -> List.iter statement body
    | Oct_lang.SMatch (_, arms) -> List.iter (fun (_, _, body) -> List.iter statement body) arms
    | _ -> () in
  List.iter (fun (fn : Oct_lang.func_def) -> List.iter statement fn.fn_body)
    (Option.to_list ast.ctor @ ast.funcs);
  let unique_named name values =
    match List.filter (fun (key, _) -> key = name) values with
    | [_, value] -> Some value | _ -> None in
  let unique_fields fields = List.filter (fun (name, _) ->
    Option.is_some (unique_named name fields)) fields in
  let state = List.map (fun (f : Oct_lang.state_field) -> f.sf_name, f.sf_typ) ast.state in
  let structs = List.map (fun (s : Oct_lang.struct_def) -> s.sd_name, s.sd_fields) ast.structs in
  let enums = List.map (fun (e : Oct_lang.enum_def) -> e.en_name, e.en_variants) ast.enums in
  let fields = function
    | Oct_lang.TStruct name -> Option.value ~default:[] (unique_named name structs)
    | Oct_lang.TList _ | Oct_lang.TMap _ -> ["length", Oct_lang.TInt]
    | _ -> [] in
  let rec path current = function
    | [] -> unique_fields current
    | Name name :: rest ->
        Option.fold ~none:[] ~some:(fun typ -> path (fields typ) rest) (unique_named name current)
    | Index :: _ -> [] in
  let rec after_indices = function Index :: rest -> after_indices rest | rest -> rest in
  let resolve is_statement chain = match chain with
    | [Name "self"; Name field] when is_statement &&
        (match unique_named field state with Some (Oct_lang.TList _) -> true | _ -> false) ->
        let item = match unique_named field state with
          | Some (Oct_lang.TList item) -> type_text item | _ -> assert false in
        ["push", "push(value: " ^ item ^ ")", 2; "delete", "delete(index: int)", 2;
         "len", "len()", 2; "pop", "pop()", 2]
    | Name "self" :: Name field :: Index :: rest ->
        (* Upstream storage paths resolve the leaf map type for their key list.
           Index expressions are not evaluated or treated as receiver names. *)
        Option.fold ~none:[] ~some:(fun typ ->
          path (fields (Oct_gen.map_value_type typ)) (after_indices rest)
          |> List.map (fun (name, typ) -> name, type_text typ, 5)) (unique_named field state)
    | Name "self" :: rest -> List.map (fun (name, typ) -> name, type_text typ, 5) (path state rest)
    | [Name name] -> Option.fold ~none:[] ~some:(fun variants ->
        List.map (fun variant -> variant, name, 20) (List.sort_uniq String.compare variants))
        (unique_named name enums)
    | _ -> [] in
  let identifier = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false in
  let finish first =
    let rec spaces offset =
      if offset < String.length source && List.mem source.[offset] [' '; '\t'; '\r'; '\n'] then spaces (offset + 1)
      else offset in
    let rec word offset =
      if offset < String.length source && identifier source.[offset] then word (offset + 1) else offset in
    word (spaces first) in
  let stream = Oct_lex.make_stream source in
  let chain = ref [] and after_dot = ref false and found = ref [] and count = ref 0 in
  let chain_start = ref (-1) in
  let indices = ref [] in
  let memo = Hashtbl.create 16 in
  let rec scan () =
    let token = Oct_lex.peek_token stream in
    if token <> Oct_lang.TkEOF && !count < 4096 then begin
      if Oct_parse.ident token then begin
        let name = Oct_parse.expect_ident stream in
        if not !after_dot then chain_start := -1;
        chain := if !after_dot then Name name :: !chain else [Name name];
        after_dot := false
      end else begin
        (match token with
         | Oct_lang.TkSelf ->
             chain := [Name "self"]; chain_start := stream.lx.pos - 4; after_dot := false
         | Oct_lang.TkLBrack ->
             indices := !chain :: !indices; chain := []; after_dot := false
         | Oct_lang.TkRBrack ->
             (match !indices with
              | receiver :: rest -> chain := Index :: receiver; indices := rest
              | [] -> chain := []);
             after_dot := false
         | Oct_lang.TkDot ->
             let first = stream.lx.pos in
             (* Recovery preserves byte offsets, so a masked statement can still
                identify an unfinished self receiver. Expressions do not acquire
                statement-only methods merely because their type is a list. *)
             let is_statement = Hashtbl.mem statements !chain_start in
             let key = !chain, is_statement in
             let items = match Hashtbl.find_opt memo key with
               | Some items -> items
               | None -> let items = resolve is_statement (List.rev !chain) in Hashtbl.add memo key items; items in
             found := { first; last = finish first; items } :: !found;
             incr count;
             after_dot := true
         | _ -> chain := []; after_dot := false);
        Oct_lex.eat stream
      end;
      scan ()
    end in
  (try scan () with Oct_lex.LexError _ -> ());
  List.rev !found
