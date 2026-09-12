open Oct_lang

exception Source_limit

let canonical_path path =
  try Unix.realpath path with Unix.Unix_error _ ->
    Filename.concat (Unix.realpath (Filename.dirname path)) (Filename.basename path)

(* Read just the import header with the compiler parser. A half-written body
   must not erase dependency edges that are still present in the buffer. *)
let imports source =
  let stream = Oct_lex.make_stream source in
  let rec read found =
    Oct_parse.skip_stmt_end stream;
    match Oct_lex.peek_token stream with
    | TkImport ->
        let line, column = stream.lx.token_line, stream.lx.token_col in
        let import = Oct_parse.parse_import stream in
        read ((import, line, column) :: found)
    | _ -> List.rev found in
  read []

let read_source overlays path =
  match List.assoc_opt path overlays with
  | Some source when String.length source <= 1_000_000 -> source
  | Some _ -> raise Source_limit
  | None ->
      let stat = Unix.stat path in
      if stat.Unix.st_kind <> Unix.S_REG then raise (Sys_error "import is not a regular file");
      if stat.Unix.st_size > 1_000_000 then raise Source_limit;
      In_channel.with_open_bin path (fun channel ->
        (* Bound the read too: another process can grow the file after stat. *)
        let length = in_channel_length channel in
        if length > 1_000_000 then raise Source_limit;
        try really_input_string channel length
        with End_of_file -> raise (Sys_error "import changed while being read"))

let dependencies ~overlays ~path source =
  let visited = Hashtbl.create 32 in
  let complete = ref true and bytes = ref 0 in
  let rec visit depth path source =
    try
      imports source |> List.iter (fun (import, _, _) ->
        try
          let target = canonical_path (Filename.concat (Filename.dirname path) import.imp_path) in
          if not (Hashtbl.mem visited target) then begin
            if Hashtbl.length visited >= 128 || depth >= 32 then complete := false
            else begin
              Hashtbl.add visited target ();
              let source = read_source overlays target in
              bytes := !bytes + String.length source;
              if !bytes > 8_000_000 then complete := false else visit (depth + 1) target source
            end
          end
        with Source_limit | Sys_error _ | Unix.Unix_error _ -> complete := false)
    with Oct_parse.ParseError _ | Oct_lex.LexError _ -> complete := false in
  visit 0 path source;
  `Assoc ["paths", `List (Hashtbl.to_seq_keys visited |> List.of_seq
    |> List.sort String.compare |> List.map (fun path -> `String path));
    "complete", `Bool !complete]

let exported_names ast =
  (ast.funcs |> List.filter (fun fn -> fn.fn_vis = Public) |> List.map (fun fn -> fn.fn_name))
  @ List.map (fun s -> s.sd_name) ast.structs
  @ List.map (fun c -> c.c_name) ast.consts
  @ List.map (fun i -> i.if_name) ast.interfaces
  @ List.map (fun e -> e.en_name) ast.enums
  @ List.map (fun e -> e.ev_name) ast.events
  @ List.map (fun e -> e.err_name) ast.errors
  @ List.map (fun f -> f.fm_name) ast.forms

let validate ?check ~overlays ~path source =
  let cache = Hashtbl.create 32 and bytes = ref 0 in
  let scopes = Hashtbl.create 32 in
  let resolve_scope program kind name =
    (* Import scopes share declaration objects from the per-path parse cache.
       Physical identity distinguishes even identical declarations in different
       files; matching by name or structural equality would mix their scopes. *)
    let form = List.find_opt (fun f -> f.fm_name = name) program.forms in
    let fn = List.find_opt (fun f -> f.fn_name = name) program.funcs in
    let constant = List.find_opt (fun c -> c.c_name = name) program.consts in
    let owner = Hashtbl.to_seq scopes |> Seq.find_map (fun (path, (own, scope)) ->
      let owns = match kind, form, fn, constant with
        | `Constant, _, _, Some selected -> List.exists (fun c -> c == selected) own.consts
        | `Callable, Some selected, _, _ -> List.exists (fun f -> f == selected) own.forms
        | `Callable, None, Some selected, _ -> List.exists (fun f -> f == selected) own.funcs
        | _ -> false in
      let namespace = match kind with `Callable -> ":call:" | `Constant -> ":const:" in
      if owns then Some (path ^ namespace ^ name, scope) else None) in
    Option.value owner ~default:(name, program) in
  let load target =
    match Hashtbl.find_opt cache target with
    | Some result -> result
    | None when Hashtbl.length cache >= 128 -> Error ("REHOVOT205", "import graph exceeds 128 files")
    | None ->
        let result = try
          let source = read_source overlays target in
          bytes := !bytes + String.length source;
          if !bytes > 8_000_000 then Error ("REHOVOT205", "import graph exceeds 8 MB")
          else Ok (source, Oct_parse.syntax source)
        with
        | Source_limit -> Error ("REHOVOT204", "import exceeds the 1 MB analysis limit")
        | Sys_error _ | Unix.Unix_error _ -> Error ("REHOVOT201", "import file not found or unreadable")
        | Oct_parse.ParseError (message, line, column) | Oct_lex.LexError (message, line, column) ->
            Error ("REHOVOT203", Printf.sprintf "cannot parse import at %d:%d: %s" line column message) in
        Hashtbl.add cache target result;
        result in
  let check_scope path source ast = match check with
    | None -> []
    | Some check ->
        let exception Ambiguous of string in
        try
          let imported = ast.imports |> List.filter_map (fun import ->
            let target = canonical_path (Filename.concat (Filename.dirname path) import.imp_path) in
            match load target with Ok (_, ast) -> Some (target, import.imp_names, ast) | Error _ -> None) in
          let gather get name own =
            let owners = Hashtbl.create 16 in
            own @ (imported |> List.concat_map (fun (target, names, ast) ->
              get ast |> List.filter (fun value ->
                let key = name value in
                if not (List.mem key names) || List.exists (fun local -> name local = key) own then false
                else match Hashtbl.find_opt owners key with
                | Some previous when previous = target -> false
                | Some _ -> raise (Ambiguous key)
                | None -> Hashtbl.add owners key target; true))) in
          (* Only declarations enter the importing scope. The checker receives
             the original unit separately, so foreign bodies/state are never
             checked as if they belonged to the importer. *)
          let scope = { ast with
            funcs = gather (fun p -> p.funcs) (fun f -> f.fn_name) ast.funcs;
            structs = gather (fun p -> p.structs) (fun s -> s.sd_name) ast.structs;
            consts = gather (fun p -> p.consts) (fun c -> c.c_name) ast.consts;
            enums = gather (fun p -> p.enums) (fun e -> e.en_name) ast.enums;
            interfaces = gather (fun p -> p.interfaces) (fun i -> i.if_name) ast.interfaces;
            events = gather (fun p -> p.events) (fun e -> e.ev_name) ast.events;
            errors = gather (fun p -> p.errors) (fun e -> e.err_name) ast.errors;
            forms = gather (fun p -> p.forms) (fun f -> f.fm_name) ast.forms;
          } in
          Hashtbl.replace scopes path (ast, scope);
          check resolve_scope source scope ast
        with Ambiguous name -> [1, 1, "REHOVOT207", "ambiguous imported declaration: " ^ name] in
  let rec visit seen active base import =
    let failure code message = Some (code, import.imp_path ^ ": " ^ message) in
    try
      let target = canonical_path (Filename.concat (Filename.dirname base) import.imp_path) in
      if List.mem target active then failure "REHOVOT206" "cyclic import"
      else if List.length active > 32 then failure "REHOVOT205" "import graph exceeds 32 levels"
      else match load target with
      | Error (code, message) -> failure code message
      | Ok (source, ast) ->
          let names = exported_names ast in
          let missing = List.filter (fun name -> not (List.mem name names)) import.imp_names in
          if missing <> [] then failure "REHOVOT202"
            ("declarations are missing or not public: " ^ String.concat ", " missing)
          else if Hashtbl.mem seen target then None
          else begin
            Hashtbl.add seen target ();
            (match children seen (target :: active) target source with
             | Some _ as error -> error
             | None -> check_scope target source ast |> List.find_map (fun (line, column, code, message) ->
                 Some (code, Printf.sprintf "%s at %d:%d: %s" target line column message)))
            |> Option.map (fun (code, message) -> code, import.imp_path ^ " -> " ^ message)
          end
    with Sys_error _ | Unix.Unix_error _ -> failure "REHOVOT201" "import file not found or unreadable"
  and children seen active base source =
    let direct = Hashtbl.create 16 in
    imports source |> List.find_map (fun (import, _, _) ->
      let target = try canonical_path (Filename.concat (Filename.dirname base) import.imp_path)
        with Unix.Unix_error _ -> import.imp_path in
      Hashtbl.replace direct target ();
      if Hashtbl.length direct > 32 then Some ("REHOVOT205", "direct import analysis limit exceeded (32 files)")
      else visit seen active base import) in
  let root = try canonical_path path with Unix.Unix_error _ -> path in
  let direct = Hashtbl.create 16 in
  (* A shared bad dependency is reported once per importing statement, with its
     chain in the message. Foreign coordinates never become root-file ranges. *)
  let errors = imports source |> List.filter_map (fun (import, line, column) ->
    let target = try canonical_path (Filename.concat (Filename.dirname path) import.imp_path)
      with Unix.Unix_error _ -> import.imp_path in
    Hashtbl.replace direct target ();
    let result = if Hashtbl.length direct > 32 then
        Some ("REHOVOT205", "direct import analysis limit exceeded (32 files)")
      else visit (Hashtbl.create 32) [root] path import in
    Option.map (fun (code, message) -> line, column, code, message) result) in
  if errors <> [] then errors else check_scope path source (Oct_parse.syntax source)
