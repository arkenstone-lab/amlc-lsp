open Octra_vm

type binding = { name : string; typ : Oct_lang.typ; first : int; last : int;
  uses : (int * int) list; scope : (int * int) option }
type local = { name : string; typ : Oct_lang.typ;
  mutable selection : (int * int) option; mutable uses : (int * int) list }
type role = Outer | Form | Declaration of local | Bound of local

let local name typ = { name; typ; selection = None; uses = [] }

(* Keep binder names in token order, but never report them or their bound uses
   as occurrences of an enclosing callable variable. Initializers use the outer
   environment; upstream restores it after each expression-local body. *)
let rec variables bound = function
  | Oct_lang.EVar name -> [name, Option.fold ~none:Outer ~some:(fun local -> Bound local) (List.assoc_opt name bound)]
  | Oct_lang.EBinop (_, left, right) | Oct_lang.EEqual (_, left, right) -> sequence bound [left; right]
  | Oct_lang.EUnop (_, value) | Oct_lang.EBalance value | Oct_lang.EAction (_, value) -> variables bound value
  | Oct_lang.ECall (_, values) | Oct_lang.EArray values | Oct_lang.ETuple values
  | Oct_lang.EIndex (_, values) | Oct_lang.EStoragePath (_, values, _)
  | Oct_lang.EIndexField (_, values, _) -> sequence bound values
  | Oct_lang.ETernary (guard, yes, no) -> sequence bound [guard; yes; no]
  | Oct_lang.ELet (name, _, typ, value, body) ->
      let local = local name typ in
      List.concat [[name, Declaration local]; variables bound value;
        variables ((name, local) :: bound) body]
  | Oct_lang.ESplit (value, (left, _, left_type), (right, _, right_type), body) ->
      let l = local left left_type and r = local right right_type in
      List.concat [variables bound value; [left, Declaration l; right, Declaration r];
        variables ((right, r) :: (left, l) :: bound) body]
  | Oct_lang.EOrbit (_, turns, seed, (name, _, typ), body) ->
      let local = local name typ in
      List.concat [sequence bound (Option.to_list turns @ [seed]); [name, Declaration local];
        variables ((name, local) :: bound) body]
  | Oct_lang.EUse value ->
      let local = local value.ux_bind value.ux_typ in
      List.concat [[value.ux_name, Form]; sequence bound (value.ux_caps @ [value.ux_arg]);
        [value.ux_bind, Declaration local]; variables ((value.ux_bind, local) :: bound) value.ux_body]
  | Oct_lang.EInt _ | Oct_lang.EBool _ | Oct_lang.EString _ | Oct_lang.EField _
  | Oct_lang.EFieldProp _ | Oct_lang.EEnumVariant _ | Oct_lang.ECaller
  | Oct_lang.EOrigin | Oct_lang.ESelfAddr | Oct_lang.EEpoch | Oct_lang.EEpochTime
  | Oct_lang.EValue | Oct_lang.ETreeHash | Oct_lang.ENodeId | Oct_lang.ETxHash -> []
and sequence bound values = List.concat_map (variables bound) values

let tokens source first last ~call expected =
  match expected with
  | [] -> []
  | expected ->
      let names = Hashtbl.create 16 in
      List.iter (fun name -> Hashtbl.replace names name ()) expected;
      let stream = Oct_lex.make_stream (String.sub source first (last - first)) in
      let previous_dot = ref false and found = ref [] in
      let rec scan () =
        let token = Oct_lex.peek_token stream in
        if token <> Oct_lang.TkEOF then begin
          if Oct_parse.ident token then begin
            let name = Oct_parse.expect_ident stream in
            let finish = first + stream.lx.pos in
            let next = Oct_lex.peek_token stream in
            if Hashtbl.mem names name && not !previous_dot
              && next <> Oct_lang.TkDot && (next = Oct_lang.TkLParen) = call then
              found := (name, finish - String.length name, finish) :: !found;
            previous_dot := false
          end else begin
            previous_dot := token = Oct_lang.TkDot;
            Oct_lex.eat stream
          end;
          scan ()
        end in
      scan ();
      let found = List.rev !found in
      (* An exact ordered match is required, not a name search. The AST supplies
         variable roles; the original lexer supplies comment-safe byte ranges. *)
      if List.map (fun (name, _, _) -> name) found = expected then found else []

let body_scope source first limit =
  let text = String.sub source first (limit - first) in
  let stream = Oct_lex.make_stream text in
  let token_start () =
    ignore (Oct_lex.peek_token stream);
    let target = Oct_lex.current_line stream in
    let line = ref 1 and start = ref 0 in
    for index = 0 to stream.lx.pos - 1 do
      if !line < target && text.[index] = '\n' then (incr line; start := index + 1)
    done;
    first + !start + Oct_lex.current_column stream - 1 in
  try
    ignore (Oct_parse.expect_ident stream);
    Oct_lex.expect stream Oct_lang.TkColon;
    ignore (Oct_parse.parse_type stream);
    (match Oct_lex.peek_token stream with
     | Oct_lang.TkEq ->
         Oct_lex.eat stream; ignore (Oct_parse.parse_expr stream);
         Oct_lex.expect stream Oct_lang.TkIn
     | Oct_lang.TkComma ->
         Oct_lex.eat stream; ignore (Oct_parse.parse_term_bind stream);
         Oct_lex.expect stream Oct_lang.TkIn
     | Oct_lang.TkIn | Oct_lang.TkFatArrow -> Oct_lex.eat stream
     | _ -> raise Exit);
    let start = first + stream.lx.pos in
    ignore (Oct_parse.parse_expr stream);
    Some (start, token_start ())
  with Oct_parse.ParseError _ | Oct_lex.LexError _ | Exit -> None

let matched_roles source first last expression =
  let roles = variables [] expression in
  let spans = tokens source first last ~call:false (List.map fst roles) in
  if List.length spans <> List.length roles then [] else List.combine roles spans

let index source first last expression =
  let limit = last in
  let matched = matched_roles source first last expression in
  let outer = matched |> List.filter_map (fun ((_, role), (name, first, last)) ->
    match role with
    | Outer -> Some (name, first, last)
    | Form -> None
    | Declaration local -> local.selection <- Some (first, last); None
    | Bound local -> local.uses <- (first, last) :: local.uses; None) in
  let bindings = List.filter_map (function
    | (_, Declaration local), _ -> Option.map (fun (first, last) ->
        { name = local.name; typ = local.typ; first; last; uses = List.rev local.uses;
          scope = body_scope source first limit }) local.selection
    | _ -> None) matched in
  let forms = List.filter_map (function (_, Form), span -> Some span | _ -> None) matched in
  outer, bindings, forms

let call_spans source first last expression =
  let rec calls = function
    | Oct_lang.ECall (name, values) as expression -> (name, expression) :: List.concat_map calls values
    | Oct_lang.EBinop (_, left, right) | Oct_lang.EEqual (_, left, right) -> calls left @ calls right
    | Oct_lang.EUnop (_, value) | Oct_lang.EBalance value | Oct_lang.EAction (_, value) -> calls value
    | Oct_lang.ELet (_, _, _, value, body) | Oct_lang.ESplit (value, _, _, body) -> calls value @ calls body
    | Oct_lang.EOrbit (_, turns, seed, _, body) -> List.concat_map calls (Option.to_list turns @ [seed; body])
    | Oct_lang.EUse value -> List.concat_map calls (value.ux_caps @ [value.ux_arg; value.ux_body])
    | Oct_lang.EArray values | Oct_lang.ETuple values | Oct_lang.EIndex (_, values)
    | Oct_lang.EStoragePath (_, values, _) | Oct_lang.EIndexField (_, values, _) -> List.concat_map calls values
    | Oct_lang.ETernary (guard, yes, no) -> calls guard @ calls yes @ calls no
    | _ -> [] in
  let calls = calls expression in
  let spans = tokens source first last ~call:true (List.map fst calls) in
  if List.length spans <> List.length calls then [] else
  List.map2 (fun (name, first, last) (_, expression) -> name, first, last, expression) spans calls
