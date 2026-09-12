open Octra_vm

type symbol = { name : string; owner : string option; first : int; last : int;
  uses : (int * int) list }
type token = { token : Oct_lang.token; name : string option; first : int; last : int }

let symbols source (ast : Oct_lang.contract) =
  if ast.enums = [] then [] else
  let stream = Oct_lex.make_stream source in
  let rec tokens found =
    let token = Oct_lex.peek_token stream in
    if token = Oct_lang.TkEOF then List.rev found else
    let name = if Oct_parse.ident token then Some (Oct_parse.expect_ident stream)
      else (Oct_lex.eat stream; None) in
    let last = stream.lx.pos in
    let first = last - Option.fold ~none:0 ~some:String.length name in
    tokens ({ token; name; first; last } :: found) in
  let tokens = tokens [] in
  let declarations = ref [] in
  let add owner (token : token) =
    Option.iter (fun name -> declarations :=
      { name; owner; first = token.first; last = token.last; uses = [] } :: !declarations) token.name in
  let rec variants found = function
    | { token = Oct_lang.TkRBrace; _ } :: rest -> Some (List.rev found, rest)
    | ({ name = Some _; _ } as token) :: rest -> variants (token :: found) rest
    | { token = (Oct_lang.TkComma | Oct_lang.TkNewline); _ } :: rest -> variants found rest
    | _ -> None in
  let rec locate depth active = function
    | { token = Oct_lang.TkEnum; _ } :: ({ name = Some name; _ } as token)
      :: { token = Oct_lang.TkLBrace; _ } :: rest when depth = 1 && active ->
        (match variants [] rest with
         | Some (items, rest) ->
             (match List.filter (fun (enum : Oct_lang.enum_def) -> enum.en_name = name) ast.enums with
              | [enum] when List.map (fun (token : token) -> Option.get token.name) items = enum.en_variants ->
                  add None token; List.iter (add (Some name)) items
              | _ -> ());
             locate depth active rest
         | None -> ())
    | { token = (Oct_lang.TkProgram | Oct_lang.TkContract); _ } :: rest when depth = 0 ->
        locate depth true rest
    | { token = Oct_lang.TkLBrace; _ } :: rest -> locate (depth + 1) active rest
    | { token = Oct_lang.TkRBrace; _ } :: rest -> locate (depth - 1) active rest
    | _ :: rest -> locate depth active rest
    | [] -> () in
  locate 0 false tokens;
  let uses = Hashtbl.create 16 in
  let add_use key (token : token) = Hashtbl.replace uses key
    ((token.first, token.last) :: Option.value ~default:[] (Hashtbl.find_opt uses key)) in
  let variants = Hashtbl.create 16 in
  List.iter (fun (symbol : symbol) -> Option.iter (fun owner ->
    Hashtbl.replace variants (owner, symbol.name) ()) symbol.owner) !declarations;
  let rec scan previous_dot = function
    | ({ name = Some owner; _ } as receiver) :: { token = Oct_lang.TkDot; _ }
      :: ({ name = Some name; _ } as member) :: rest
      when not previous_dot && Hashtbl.mem variants (owner, name) ->
        add_use (None, owner) receiver;
        add_use (Some owner, name) member;
        scan false rest
    | token :: rest -> scan (token.token = Oct_lang.TkDot) rest
    | [] -> () in
  scan false tokens;
  List.rev_map (fun (symbol : symbol) -> { symbol with uses =
    List.sort_uniq compare (Option.value ~default:[] (Hashtbl.find_opt uses (symbol.owner, symbol.name))) }) !declarations
