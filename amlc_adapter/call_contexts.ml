open Octra_vm

type kind = Direct | Captures | Argument
type site = { first : int; last : int; name : string; name_start : int; parameter : int; kind : kind }
type frame = { close : Oct_lang.token; call : (string * int * kind) option; mutable parameter : int }

let sites source =
  let lines = ref [0] in
  String.iteri (fun index value -> if value = '\n' then lines := (index + 1) :: !lines) source;
  let lines = Array.of_list (List.rev !lines) in
  let stream = Oct_lex.make_stream source in
  let frames = ref [] and found = ref [] and count = ref 0 and first = ref 0 in
  let previous = ref None and dot = ref false and declaration = ref false in
  (* Only an explicit use capture list carries its target to the following
     argument parentheses; ordinary indexing must not manufacture a call. *)
  let use_target = ref false and captured = ref None in
  let rec active = function
    | [] -> None
    | { call = Some (name, name_start, kind); parameter; _ } :: _ -> Some (name, name_start, parameter, kind)
    | _ :: rest -> active rest in
  let emit last =
    match active !frames with
    | Some (name, name_start, parameter, kind) when !first <= last && !count < 4096 ->
        found := { first = !first; last; name; name_start; parameter; kind } :: !found;
        incr count
    | _ -> () in
  let rec scan () =
    let token = Oct_lex.peek_token stream in
    let start = lines.(Oct_lex.current_line stream - 1) + Oct_lex.current_column stream - 1 in
    if token = Oct_lang.TkEOF then emit (String.length source)
    else if !count < 4096 then begin
      let resumed = !captured in
      captured := None;
      if Oct_parse.ident token then begin
        let name = Oct_parse.expect_ident stream in
        previous := if !dot || !declaration then None else Some (name, start, !use_target);
        use_target := name = "use" && not !dot && not !declaration;
        dot := false;
        declaration := false
      end else begin
        let finish = stream.lx.pos in
        (match token with
         | Oct_lang.TkLParen | Oct_lang.TkLBrack | Oct_lang.TkLBrace ->
             emit start;
             let close = match token with
               | Oct_lang.TkLParen -> Oct_lang.TkRParen
               | Oct_lang.TkLBrack -> Oct_lang.TkRBrack
               | _ -> Oct_lang.TkRBrace in
             let call = match token, !previous, resumed with
               | Oct_lang.TkLBrack, Some (name, start, true), _ -> Some (name, start, Captures)
               | Oct_lang.TkLParen, _, Some (name, start) -> Some (name, start, Argument)
               | Oct_lang.TkLParen, Some (name, start, false), _ -> Some (name, start, Direct)
               | _ -> None in
             frames := { close; call;
               parameter = 0 } :: !frames;
             first := finish
         | Oct_lang.TkRParen | Oct_lang.TkRBrack | Oct_lang.TkRBrace ->
             emit start;
             frames := (match !frames with frame :: rest when frame.close = token ->
               (match frame.call with Some (name, start, Captures) -> captured := Some (name, start) | _ -> ());
               rest | _ -> []);
             first := finish
         | Oct_lang.TkComma ->
             emit start;
             (match !frames with { call = Some _; _ } as frame :: _ ->
                frame.parameter <- frame.parameter + 1 | _ -> ());
             first := finish
         | _ -> ());
        declaration := token = Oct_lang.TkFn || token = Oct_lang.TkPublic;
        use_target := false;
        dot := token = Oct_lang.TkDot;
        previous := None;
        Oct_lex.eat stream
      end;
      scan ()
    end in
  (* Unterminated strings/comments must not manufacture calls or argument
     separators. Earlier complete contexts remain usable, not the error tail. *)
  (try scan () with Oct_lex.LexError _ -> ());
  List.rev !found
