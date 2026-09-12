open Octra_vm

type symbol = { name : string; typ : Oct_lang.typ; first : int; last : int;
  uses : (int * int) list }

let symbols source (ast : Oct_lang.contract) =
  if ast.state = [] then [] else
  let stream = Oct_lex.make_stream source in
  let declarations = ref [] and uses = Hashtbl.create 16 in
  let fields () =
    Oct_lex.expect stream Oct_lang.TkLBrace;
    let rec scan found =
      match Oct_lex.peek_token stream with
      | Oct_lang.TkRBrace -> Oct_lex.eat stream; List.rev found
      | _ ->
          let name = Oct_parse.expect_ident stream in
          let last = stream.lx.pos in
          Oct_lex.expect stream Oct_lang.TkColon;
          let typ = Oct_parse.parse_type stream in
          if Oct_lex.peek_token stream = Oct_lang.TkComma then Oct_lex.eat stream;
          scan ({ name; typ; first = last - String.length name; last; uses = [] } :: found) in
    let found = scan [] in
    if List.map (fun (s : symbol) -> s.name, s.typ) found =
      List.map (fun (s : Oct_lang.state_field) -> s.sf_name, s.sf_typ) ast.state then
      declarations := found in
  let rec scan depth active =
    match Oct_lex.peek_token stream with
    | Oct_lang.TkEOF -> ()
    | Oct_lang.TkState when depth = 1 && active ->
        Oct_lex.eat stream; fields (); scan depth active
    | Oct_lang.TkSelf ->
        Oct_lex.eat stream;
        if Oct_lex.peek_token stream = Oct_lang.TkDot then begin
          Oct_lex.eat stream;
          if Oct_parse.ident (Oct_lex.peek_token stream) then begin
            let name = Oct_parse.expect_ident stream in
            let last = stream.lx.pos in
            Hashtbl.replace uses name ((last - String.length name, last) ::
              Option.value ~default:[] (Hashtbl.find_opt uses name))
          end
        end;
        scan depth active
    | Oct_lang.TkProgram | Oct_lang.TkContract when depth = 0 ->
        Oct_lex.eat stream; scan depth true
    | Oct_lang.TkLBrace -> Oct_lex.eat stream; scan (depth + 1) active
    | Oct_lang.TkRBrace -> Oct_lex.eat stream; scan (depth - 1) active
    | _ -> Oct_lex.eat stream; scan depth active in
  scan 0 false;
  List.map (fun (symbol : symbol) -> { symbol with uses = List.sort_uniq compare
    (Option.value ~default:[] (Hashtbl.find_opt uses symbol.name)) }) !declarations
