open Octra_vm
open Oct_lang

type occurrence = {
  name : string;
  target : string;
  role : string;
  first : int;
  last : int;
}

let max_entries = 4096
let max_depth = 24
let max_files = 256
let max_file_bytes = 1_000_000
let max_total_bytes = 8_000_000

let canonical path =
  try Unix.realpath path with Unix.Unix_error (Unix.ENOENT, _, _) ->
    let parent = Unix.realpath (Filename.dirname path) in
    Filename.concat parent (Filename.basename path)

let path_equal left right =
  if Sys.win32 then String.equal (String.lowercase_ascii left) (String.lowercase_ascii right)
  else String.equal left right

let directory_contains directory path =
  let directory_length = String.length directory in
  path_equal directory path
  || (String.length path > directory_length
      && path_equal directory (String.sub path 0 directory_length)
      && (directory.[directory_length - 1] = '/'
          || directory.[directory_length - 1] = '\\'
          || path.[directory_length] = '/' || path.[directory_length] = '\\'))

let readonly_flags =
  if Sys.win32 then [Unix.O_RDONLY] else [Unix.O_RDONLY; Unix.O_NONBLOCK]

let workspace_entry name =
  name <> "" && name.[0] <> '.' && not (List.mem name ["_build"; "node_modules"])

let inside roots path =
  List.exists (fun root ->
    let root = canonical root in
    let root_length = String.length root in
    let relative_start =
      if root.[root_length - 1] = '/' || root.[root_length - 1] = '\\'
      then root_length else root_length + 1 in
    directory_contains root path && not (path_equal root path)
    && Filename.check_suffix path ".aml"
    && String.sub path relative_start (String.length path - relative_start)
       |> String.map (function '\\' -> '/' | byte -> byte)
       |> String.split_on_char '/' |> List.for_all workspace_entry) roots

let workspace_overlays roots overlays =
  overlays |> List.filter_map (fun (path, source) ->
    try
      let path = canonical path in
      if inside roots path then Some (path, source) else None
    with Unix.Unix_error _ -> None)

let read_source overlays path =
  match List.find_opt (fun (candidate, _) -> path_equal candidate path) overlays with
  | Some (_, source) when String.length source <= max_file_bytes -> Some source
  | Some _ -> None
  | None ->
      try
        let descriptor = Unix.openfile path readonly_flags 0 in
        let channel = Unix.in_channel_of_descr descriptor in
        Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
          let stat = Unix.fstat descriptor in
          if stat.st_kind <> Unix.S_REG || stat.st_size > max_file_bytes then None
          else Some (really_input_string channel stat.st_size))
      with Sys_error _ | Unix.Unix_error _ | End_of_file -> None

let workspace_sources roots overlays =
  let complete = ref (roots <> []) in
  let entries = ref 0 and bytes = ref 0 in
  let entry_exhausted = ref false and source_exhausted = ref false in
  let files = ref [] and seen = Hashtbl.create 64 in
  let rec visit depth path =
    if !source_exhausted then () else if depth > max_depth then complete := false else
    try
      match (Unix.lstat path).st_kind with
      | Unix.S_DIR when not !entry_exhausted ->
          let directory = Unix.opendir path in
          let names = Fun.protect ~finally:(fun () -> Unix.closedir directory) (fun () ->
            let rec read found =
              match Unix.readdir directory with
              | _name when !entries >= max_entries ->
                  complete := false; entry_exhausted := true; found
              | name ->
                  incr entries;
                  read (if workspace_entry name then name :: found else found)
              | exception End_of_file -> found in
            read []) in
          names |> List.sort String.compare |> List.iter (fun name ->
            if not !source_exhausted then visit (depth + 1) (Filename.concat path name))
      | Unix.S_DIR -> ()
      | Unix.S_REG when Filename.check_suffix path ".aml" ->
          let path = canonical path in
          if not (Hashtbl.mem seen path) then begin
            if Hashtbl.length seen >= max_files then begin
              complete := false; source_exhausted := true
            end else begin
              Hashtbl.add seen path ();
              match read_source overlays path with
              | Some source when !bytes + String.length source <= max_total_bytes ->
                  bytes := !bytes + String.length source;
                  files := (path, source) :: !files
              | Some _ -> complete := false; source_exhausted := true
              | None -> complete := false
            end
          end
      | Unix.S_LNK -> ()
      | _ -> ()
    with Sys_error _ | Unix.Unix_error _ -> complete := false in
  List.iter (visit 0) roots;
  List.rev !files, !complete

let byte_position source =
  let starts = ref [0] in
  String.iteri (fun index byte -> if byte = '\n' then starts := (index + 1) :: !starts) source;
  let starts = Array.of_list (List.rev !starts) in
  fun line column -> starts.(line - 1) + column - 1

let imported_targets path (ast : contract) =
  let targets = Hashtbl.create 8 in
  List.iter (fun (item : import_decl) ->
    let target = canonical (Filename.concat (Filename.dirname path) item.imp_path) in
    List.iter (fun name ->
      match Hashtbl.find_opt targets name with
      | None -> Hashtbl.add targets name (Some target)
      | Some (Some previous) when previous = target -> ()
      | Some _ -> Hashtbl.replace targets name None) item.imp_names) ast.imports;
  targets

let occurrences path source (ast : contract) =
  let position = byte_position source in
  let imported = imported_targets path ast in
  let local = Hashtbl.create 8 in
  List.iter (fun (item : interface_def) -> Hashtbl.replace local item.if_name ()) ast.interfaces;
  let target name =
    if Hashtbl.mem local name then Some path
    else Option.join (Hashtbl.find_opt imported name) in
  let stream = Oct_lex.make_stream source in
  let rec scan mode found =
    let token = Oct_lex.peek_token stream in
    if token = TkEOF then List.rev found else
    let first = position stream.lx.token_line stream.lx.token_col in
    let last = stream.lx.pos in
    let mode, item = match token, mode with
      | TkInterface, _ -> `Interface, None
      | TkImport, _ -> `Import, None
      | TkImplements, _ -> `Implements, None
      | TkIdent "from", `Import -> `Normal, None
      | TkLBrace, (`Interface | `Implements) -> `Normal, None
      | TkStrLit _, `Import -> `Normal, None
      | TkIdent name, `Interface when Hashtbl.mem local name ->
          `Normal, Some { name; target = path; role = "declaration"; first; last }
      | TkIdent name, `Import ->
          `Import, Option.map (fun target ->
            { name; target; role = "reference"; first; last }) (target name)
      | TkIdent name, `Implements ->
          `Implements, Option.map (fun target ->
            { name; target; role = "reference"; first; last }) (target name)
      | _ -> mode, None in
    Oct_lex.eat stream;
    scan mode (Option.fold ~none:found ~some:(fun item -> item :: found) item) in
  scan `Normal []

let valid_document roots overlays path source =
  let resolve relative =
    try
      let target = canonical (Filename.concat (Filename.dirname path) relative) in
      if inside roots target then read_source overlays target else None
    with Unix.Unix_error _ -> None in
  match Aml_source.compile_multi
      (fun requested -> if requested = path then Some source else resolve requested) path with
  | Ok _ -> true
  | Error _ -> false

let documents roots overlays path source =
  if not (inside roots path) then [], false else
  let overlays = workspace_overlays roots overlays in
  let workspace, complete = workspace_sources roots overlays in
  let all = (path, source) :: overlays @ workspace in
  let seen = Hashtbl.create 64 in
  let unique = List.filter_map (fun (path, source) ->
    try
      let path = canonical path in
      if Hashtbl.mem seen path then None
      else (Hashtbl.add seen path (); Some (path, source))
    with Unix.Unix_error _ -> None) all in
  unique, complete

let indexed_documents roots overlays path source =
  let documents, complete = documents roots overlays path source in
  let complete = ref complete in
  let indexed = documents |> List.filter_map (fun (path, source) ->
    try
      let ast = Oct_parse.syntax source in
      if valid_document roots overlays path source then Some (path, source, ast, occurrences path source ast)
      else (complete := false; None)
    with Oct_parse.ParseError _ | Oct_lex.LexError _ | Sys_error _ | Unix.Unix_error _ ->
      complete := false; None) in
  indexed, !complete

let item path source occurrence =
  `Assoc [
    "path", `String path;
    "start", `Int occurrence.first;
    "end", `Int occurrence.last;
    "role", `String occurrence.role;
    "sourceHash", `String (Digest.to_hex (Digest.string source));
  ]

let references ~overlays ~roots ~path source offset =
  try
    let path = canonical path in
    let indexed, complete = indexed_documents roots overlays path source in
    let selected = indexed |> List.find_map (fun (file, _, _, occurrences) ->
      if file <> path then None else
      List.find_opt (fun occurrence -> occurrence.first <= offset && offset <= occurrence.last)
        occurrences) in
    let items = match selected with
      | None -> []
      | Some selected -> indexed |> List.concat_map (fun (file, text, _, occurrences) ->
          occurrences |> List.filter (fun occurrence ->
            occurrence.name = selected.name && occurrence.target = selected.target)
          |> List.map (item file text)) in
    `Assoc ["items", `List items; "complete", `Bool complete]
  with Sys_error _ | Unix.Unix_error _ | Invalid_argument _ ->
    `Assoc ["items", `List []; "complete", `Bool false]

let identifier replacement =
  try
    let stream = Oct_lex.make_stream replacement in
    Oct_lex.peek_token stream = TkIdent replacement
    && (Oct_lex.eat stream; Oct_lex.peek_token stream = TkEOF)
  with Oct_lex.LexError _ -> false

let rewrite source edits replacement =
  List.sort (fun first second -> compare second.first first.first) edits
  |> List.fold_left (fun source occurrence ->
    String.sub source 0 occurrence.first ^ replacement
    ^ String.sub source occurrence.last (String.length source - occurrence.last)) source

let safe_tokens source original replacement edits =
  let positions = Hashtbl.create (List.length edits) in
  List.iter (fun occurrence -> Hashtbl.replace positions occurrence.first ()) edits;
  let position = byte_position source in
  let stream = Oct_lex.make_stream source in
  let rec scan () =
    match Oct_lex.peek_token stream with
    | TkEOF -> true
    | TkIdent name ->
        let first = position stream.lx.token_line stream.lx.token_col in
        Oct_lex.eat stream;
        if name = original && not (Hashtbl.mem positions first) then false
        else if replacement <> original && name = replacement then false
        else scan ()
    | _ -> Oct_lex.eat stream; scan () in
  scan ()

let rename ~overlays ~roots ?replacement ~path source offset =
  try
    let overlays = workspace_overlays roots overlays in
    let source_path = canonical path in
    let result = references ~overlays ~roots ~path source offset in
    let open Yojson.Safe.Util in
    let items = result |> member "items" |> to_list in
    let declarations = List.filter (fun item -> member "role" item = `String "declaration") items in
    if member "complete" result <> `Bool true || List.length declarations <> 1 then `Null else
    let current = List.find (fun item ->
      member "path" item = `String source_path
      && to_int (member "start" item) <= offset && offset <= to_int (member "end" item)) items in
    let original = String.sub source (to_int (member "start" current))
      (to_int (member "end" current) - to_int (member "start" current)) in
    let replacement = Option.value ~default:original replacement in
    if not (identifier replacement) then `Null else
    let grouped = Hashtbl.create 8 in
    List.iter (fun item ->
      let file = to_string (member "path" item) in
      Hashtbl.replace grouped file (item :: Option.value ~default:[] (Hashtbl.find_opt grouped file))) items;
    let rewritten = Hashtbl.to_seq grouped |> List.of_seq |> List.map (fun (file, items) ->
      let text = if file = source_path then source else
        Option.get (read_source overlays file) in
      let expected_hash = `String (Digest.to_hex (Digest.string text)) in
      if not (inside roots file) || List.exists (fun item -> member "sourceHash" item <> expected_hash) items
      then raise Exit;
      let edits = List.map (fun item -> {
        name = original; target = ""; role = "";
        first = to_int (member "start" item); last = to_int (member "end" item) }) items in
      if not (safe_tokens text original replacement edits) then raise Exit;
      file, rewrite text edits replacement) in
    let overlays = rewritten @ overlays in
    if List.exists (fun (file, text) ->
      (not (valid_document roots overlays file text))
      || (replacement <> original && occurrences file text (Oct_parse.syntax text)
          |> List.exists (fun occurrence -> occurrence.name = original))) rewritten
    then `Null else `Assoc ["name", `String original; "items", `List items]
  with Exit | Not_found | Invalid_argument _ | Yojson.Safe.Util.Type_error _
     | Oct_parse.ParseError _ | Oct_lex.LexError _ | Sys_error _ | Unix.Unix_error _ -> `Null
