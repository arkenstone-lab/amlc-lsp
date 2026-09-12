open Octra_vm

type candidate = { text : string; eof_anchor : bool }

(* Recovery supplies parser input, never compiler input. Keep original byte
   offsets by masking within a block, and bound both work and nesting. *)
let candidates ?before source =
  let before = Option.value ~default:(String.length source) before in
  let stream = Oct_lex.make_stream source in
  let stack = ref [] in
  let ends = Hashtbl.create 16 in
  let cuts = ref [] in
  let last_token = ref Oct_lang.TkEOF in
  let remember word offset =
    if offset <= before then begin
      cuts := (offset, !stack, word = "fn" || word = "public") :: !cuts;
      if List.length !cuts > 7 then cuts := List.filteri (fun index _ -> index < 7) !cuts
    end in
  let push closing =
    if List.length !stack >= 128 then raise Exit;
    stack := (stream.lx.pos - 1, closing) :: !stack in
  let pop closing = match !stack with
    | (opening, expected) :: rest when closing = expected ->
        Hashtbl.add ends opening (stream.lx.pos - 1);
        stack := rest
    | _ -> raise Exit in
  let rec scan () =
    let token = Oct_lex.peek_token stream in
    let keyword = match token with
      | Oct_lang.TkLet -> Some "let" | Oct_lang.TkReturn -> Some "return"
      | Oct_lang.TkFn -> Some "fn" | Oct_lang.TkPublic -> Some "public"
      | Oct_lang.TkFor -> Some "for" | Oct_lang.TkWhile -> Some "while"
      | Oct_lang.TkIf -> Some "if" | Oct_lang.TkMatch -> Some "match"
      | Oct_lang.TkSelf -> Some "self"
      | _ -> None in
    Option.iter (fun word -> remember word (stream.lx.pos - String.length word)) keyword;
    match token with
    | Oct_lang.TkEOF -> ()
    | _ ->
        last_token := token;
        (match token with
         | Oct_lang.TkLBrace -> push "}" | Oct_lang.TkLParen -> push ")"
         | Oct_lang.TkLBrack -> push "]" | Oct_lang.TkRBrace -> pop "}"
         | Oct_lang.TkRParen -> pop ")" | Oct_lang.TkRBrack -> pop "]"
         | _ -> ());
        Oct_lex.eat stream;
        scan () in
  try
    scan ();
    let close scopes = "\n" ^ String.concat "" (List.map snd scopes) in
    let tail = match !last_token with Oct_lang.TkIn | Oct_lang.TkFatArrow -> "\n0" | _ -> "\nreturn" in
    let complete_tail = { text = source ^ tail ^ close !stack; eof_anchor = true } in
    let masked = List.filter_map (fun (offset, scopes, top_level) ->
      match List.find_opt (fun (_, closing) -> closing = "}") scopes with
      | None -> None
      | Some (opening, _) ->
          let closing = Hashtbl.find_opt ends opening in
          let last = Option.value ~default:(String.length source) closing in
          let replacement = if top_level then "" else "return" in
          if last - offset < String.length replacement then None else
          (* Preserve the real block end and later functions. Moving that end
             to EOF would leak recovered locals into unrelated scopes. *)
          Some { text = String.sub source 0 offset ^ replacement
            ^ String.make (last - offset - String.length replacement) ' '
            ^ String.sub source last (String.length source - last)
            ^ close (if Option.is_some closing then !stack else scopes); eof_anchor = false }) !cuts in
    complete_tail :: masked
  with Oct_lex.LexError _ | Exit -> []
