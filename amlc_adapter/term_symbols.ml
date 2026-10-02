open Octra_vm

type parameter = { form : string; name : string; typ : string option;
  first : int; last : int; uses : (int * int) list }
type role = Param | Other

let type_text = function
  | C_syn.TInt -> Some "int"
  | C_syn.TBool -> Some "bool"
  | C_syn.TUnit -> Some "unit"
  | _ -> None

let user_name name =
  let text = C_syn.name_text name in
  if text = "" || text.[0] = '$' then None else Some text

let add_local env name =
  match user_name name with Some text -> (text, Other) :: env | None -> env

let rec variables env = function
  | C_syn.Var name ->
      (match user_name name with
       | None -> []
       | Some text ->
           [text, (match List.assoc_opt text env with Some Param -> Param | _ -> Other)])
  | C_syn.Let (bind, value, body) ->
      variables env value @ variables (add_local env bind.C_syn.name) body
  | C_syn.If (guard, yes, no) ->
      variables env guard @ variables env yes @ variables env no
  | C_syn.Pair (left, right) | C_syn.Add (left, right) | C_syn.Sub (left, right)
  | C_syn.Mul (left, right) | C_syn.Div (left, right) | C_syn.Mod (left, right)
  | C_syn.Cmp (_, left, right) | C_syn.Cat (left, right) | C_syn.Vcat (left, right)
  | C_syn.Eq (_, left, right) -> variables env left @ variables env right
  | C_syn.Unpair (value, left, right, body) ->
      variables env value @ variables (add_local (add_local env left.C_syn.name) right.C_syn.name) body
  | C_syn.Case (value, left, yes, right, no) ->
      variables env value @ variables (add_local env left.C_syn.name) yes
      @ variables (add_local env right.C_syn.name) no
  | C_syn.Fst value | C_syn.Snd value | C_syn.Neg value | C_syn.Abs value
  | C_syn.Wide value | C_syn.Length value | C_syn.Fit (_, value) | C_syn.Act (_, value)
  | C_syn.Take (_, value) | C_syn.Drop (_, value) | C_syn.At (_, value)
  | C_syn.Uncons value | C_syn.Close value | C_syn.Inl (value, _) | C_syn.Inr (_, value) ->
      variables env value
  | C_syn.KVec (_, values) | C_syn.KSeq (_, _, values) ->
      List.concat_map (variables env) values
  | C_syn.Vfold (vector, seed, fold) ->
      variables env vector @ variables env seed
      @ variables (add_local (add_local env fold.C_syn.item.C_syn.name) fold.C_syn.state.C_syn.name) fold.C_syn.body
  | C_syn.Step (cap, value) -> variables env cap @ variables env value
  | C_syn.KUnit | C_syn.KBool _ | C_syn.KInt _ | C_syn.KBytes _ -> []

let index source ast =
  match C_lex.scan source with
  | Error _ -> [], []
  | Ok items ->
      let length = Array.length items in
      let forms = C_parse.forms ast |> List.filter_map (fun (fn : C_fun.fn) ->
        match user_name fn.name with
        | None -> None
        | Some name ->
            let parameters = fn.arr.caps @ [fn.arr.arg] |> List.map (fun (bind : C_syn.bind) ->
              C_syn.name_text bind.name, type_text bind.typ) in
            Some (name, parameters, fn.body, C_fun.direct fn)) in
      let direct = Hashtbl.create 8 in
      List.iter (fun (name, _, _, is_direct) -> if is_direct then Hashtbl.replace direct name ()) forms;
      let calls = ref [] in
      for index = 0 to length - 2 do
        match items.(index).tok, items.(index + 1).tok with
        | C_lex.Ident name, C_lex.Lparen when Hashtbl.mem direct name ->
            let span = items.(index).span in
            calls := (name, span.first.off, span.last.off) :: !calls
        | _ -> ()
      done;
      let rec header index depth params =
        if index >= length then None else
        match items.(index).tok with
        | C_lex.Form | C_lex.Term -> None
        | C_lex.Eq when depth = 0 -> Some (List.rev params, index)
        | C_lex.Lbrace | C_lex.Lparen | C_lex.Lbrack -> header (index + 1) (depth + 1) params
        | C_lex.Rbrace | C_lex.Rparen | C_lex.Rbrack ->
            header (index + 1) (depth - 1) params
        | C_lex.Ident name when index + 1 < length && items.(index + 1).tok = C_lex.Colon ->
            let span = items.(index).span in
            header (index + 1) depth ((name, span.first.off, span.last.off) :: params)
        | _ -> header (index + 1) depth params in
      let rec body_idents index found =
        if index >= length then List.rev found else
        match items.(index).tok with
        | C_lex.Form | C_lex.Term -> List.rev found
        | C_lex.Ident name ->
            let next = if index + 1 < length then items.(index + 1).tok else C_lex.Eof in
            let found = if next = C_lex.Colon || next = C_lex.Lparen then found else
              let span = items.(index).span in
              (name, span.first.off, span.last.off) :: found in
            body_idents (index + 1) found
        | _ -> body_idents (index + 1) found in
      let parameters = ref [] in
      let rec forms_at index =
        if index + 1 < length then
          match items.(index).tok, items.(index + 1).tok with
          | C_lex.Form, C_lex.Ident name ->
              (match List.filter (fun (form, _, _, _) -> form = name) forms with
               | [(form, form_parameters, body, _)] ->
                   (match header (index + 2) 0 [] with
                    | Some (found, eq) when List.map (fun (name, _, _) -> name) found
                        = List.map fst form_parameters ->
                        let idents = body_idents (eq + 1) [] in
                        let roles = variables
                          (List.map (fun (name, _) -> name, Param) form_parameters) body in
                        let matched = List.length roles = List.length idents
                          && List.for_all2 (fun (name, _) (text, _, _) -> name = text) roles idents in
                        let names = List.map fst form_parameters in
                        let unique = List.length names = List.length (List.sort_uniq String.compare names) in
                        let uses = if matched && unique then
                          List.map2 (fun (_, role) (name, first, last) -> name, role, first, last) roles idents
                          |> List.filter_map (fun (name, role, first, last) ->
                            if role = Param then Some (name, first, last) else None)
                        else [] in
                        List.iter2 (fun (name, typ) (_, first, last) ->
                          let uses = List.filter_map (fun (use_name, start, finish) ->
                            if use_name = name then Some (start, finish) else None) uses in
                          parameters := { form; name; typ; first; last; uses } :: !parameters)
                          form_parameters found
                    | _ -> ())
               | _ -> ());
              forms_at (index + 1)
          | _ -> forms_at (index + 1) in
      forms_at 0;
      List.rev !parameters, List.rev !calls
