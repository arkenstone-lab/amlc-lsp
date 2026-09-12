open Octra_vm

let prefix_width text =
  let rec prefix index =
    if index < String.length text && (text.[index] = ' ' || text.[index] = '\t')
    then prefix (index + 1) else index in
  prefix 0

let layout lines levels protected =
  Array.to_list (Array.mapi (fun line text ->
    if protected.(line) || String.trim text = "" then None else
    Option.map (fun depth -> line, prefix_width text, depth) levels.(line)) lines)
  |> List.filter_map Fun.id

(* Only leading whitespace outside multiline lexemes can be edited. Keeping
   every other byte (including line endings) preserves the official token stream. *)
let lines source =
  let lines = Array.of_list (String.split_on_char '\n' source) in
  let levels = Array.make (Array.length lines) None in
  let protected = Array.make (Array.length lines) false in
  let lexer = Oct_lex.create source in
  let depth = ref 0 in
  let rec scan () =
    let token = Oct_lex.next_token lexer in
    let line = lexer.token_line - 1 in
    if token <> Oct_lang.TkEOF then begin
      if levels.(line) = None then
        levels.(line) <- Some (max 0 (!depth - if token = Oct_lang.TkRBrace then 1 else 0));
      (* A raw newline token can also represent a skipped comment. A plain
         newline advances exactly once, starting at the end of its line. *)
      let multiline = lexer.line > lexer.token_line &&
        (token <> Oct_lang.TkNewline || lexer.token_col <= String.length lines.(line)) in
      if multiline then
        for index = line to min (Array.length lines - 1) (lexer.line - 1) do protected.(index) <- true done;
      (match token with
       | Oct_lang.TkLBrace -> incr depth
       | Oct_lang.TkRBrace -> depth := max 0 (!depth - 1)
       | _ -> ());
      scan ()
    end in
  scan ();
  layout lines levels protected

let term_lines source =
  match C_lex.scan source with
  | Error _ -> None
  | Ok tokens ->
      let lines = Array.of_list (String.split_on_char '\n' source) in
      let offset = ref 0 in
      let starts = Array.map (fun line ->
        let first = !offset + prefix_width line in
        offset := !offset + String.length line + 1;
        first) lines in
      let levels = Array.make (Array.length lines) None in
      let protected = Array.make (Array.length lines) false in
      let depth = ref 0 in
      Array.iter (fun (item : C_lex.item) ->
        if item.tok <> C_lex.Eof then begin
          let line = item.span.first.line - 1 in
          (* Gaps in the term token stream include comments. Only a token at
             the first non-whitespace byte proves that this prefix is code,
             not an interior line of a skipped multiline comment. *)
          if levels.(line) = None && item.span.first.off = starts.(line) then
            levels.(line) <- Some (max 0 (!depth - if item.tok = C_lex.Rbrace then 1 else 0));
          if item.span.last.line > item.span.first.line then
            for index = line to min (Array.length lines - 1) (item.span.last.line - 1) do
              protected.(index) <- true
            done;
          (match item.tok with C_lex.Lbrace -> incr depth
           | C_lex.Rbrace -> depth := max 0 (!depth - 1) | _ -> ())
        end) tokens;
      Some (layout lines levels protected)
