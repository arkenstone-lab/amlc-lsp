(* Official launcher only: no private compiler executable or helper fallback. *)
let rec canonical path =
  try Unix.realpath path with Unix.Unix_error (Unix.ENOENT, _, _) ->
    let parent = Filename.dirname path in
    if parent = path then path else
    let parent = canonical parent in
    match Filename.basename path with
    | "." -> parent | ".." -> Filename.dirname parent
    | name -> Filename.concat parent name

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

let import_resolver uri =
  let dependencies = ref [] in
  let count = ref 0 and bytes = ref 0 in
  let resolve relative =
    try
      incr count;
      if !count > 32 || not (Filename.is_relative relative)
        || String.contains relative '\000' then None else
      let main = Amlc_lsp.path_of_uri uri in
      let base = canonical (Filename.dirname main) in
      let path = canonical (Filename.concat base relative) in
      if not (directory_contains base path) then None else begin
        dependencies := path :: !dependencies;
        let opened = Hashtbl.fold (fun _ (doc : Amlc_lsp.document) found ->
          if Option.is_some found then found else
          try if path_equal (canonical (Amlc_lsp.path_of_uri doc.uri)) path then Some doc.text else None
          with Unix.Unix_error _ | Invalid_argument _ -> None) Amlc_lsp.documents None in
        let source = match opened with
          | Some text -> Some text
          | None ->
              (* POSIX uses a nonblocking open so a path swapped for a FIFO
                 cannot hang a worker. Windows does not support that flag;
                 fstat still rejects non-regular handles after opening. *)
              let fd = Unix.openfile path readonly_flags 0 in
              let channel = Unix.in_channel_of_descr fd in
              Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
                let stat = Unix.fstat fd in
                if stat.st_kind <> Unix.S_REG || stat.st_size > 1_000_000 then None
                else Some (really_input_string channel stat.st_size)) in
        match source with
        | Some text when String.length text <= 1_000_000 ->
            bytes := !bytes + String.length text;
            if !bytes > 8_000_000 then None else Some text
        | _ -> None
      end
    with Unix.Unix_error _ | Sys_error _ | End_of_file | Invalid_argument _ -> None in
  resolve, dependencies

let quick_fix_code ~syntax text (item : Amlc_analysis.diagnostic) =
  let code = Amlc_lsp.diagnostic_code item.message in
  let replacement = match code with
    | "AMLC101" -> Some ")"
    | "AMLC102" -> Some "}"
    | "AMLC103" -> Some "]"
    | "AMLC104" -> Some ","
    | "AMLC105" -> Some "in "
    | "AMLC106" -> Some "then "
    | "AMLC107" -> Some "else "
    | "AMLC108" -> Some ": "
    | _ -> None in
  match item.span, replacement with
  | Some span, Some replacement when span.first = span.last ->
      let candidate = String.sub text 0 span.first ^ replacement
        ^ String.sub text span.first (String.length text - span.first) in
      let checked = Amlc_analysis.analyze ~syntax candidate in
      let same_error = List.exists (fun (diagnostic : Amlc_analysis.diagnostic) ->
        diagnostic.message = item.message && diagnostic.span = item.span) checked.diagnostics in
      if same_error then "AMLC000" else code
  | _ -> "AMLC000"

let analyze uri text =
  let syntax = match !(Amlc_lsp.dialect_override) with
    | None -> Amlc_analysis.Auto
    | Some Amlc_lsp.Legacy_amlc -> Amlc_analysis.Term
    | Some Amlc_lsp.Appliedml -> Amlc_analysis.Callable in
  let resolve, imported = import_resolver uri in
  let analysis = Amlc_analysis.analyze ~syntax ~resolve text in
  let diagnostics = List.map (fun (item : Amlc_analysis.diagnostic) ->
    let first, last, message = match item.span with
      | Some span -> span.first, span.last, item.message
      | None -> 0, 0, "[AMLC did not supply a source location] " ^ item.message in
    { Amlc_lsp.message; code = quick_fix_code ~syntax text item; severity = 1;
      start_position = Amlc_lsp.utf16_position text first;
      end_position = Amlc_lsp.utf16_position text last }) analysis.diagnostics in
  let diagnostics, dependencies = match analysis.status with
    | Amlc_analysis.Checked -> diagnostics,
        (* A failed check may not have visited every import. *)
        (if diagnostics = [] then Some (List.sort_uniq String.compare !imported) else None)
    | Amlc_analysis.Needs_imports _ ->
        let warning = Amlc_lsp.compiler_fallback ~code:"AMLC904"
          "Import analysis could not resolve every source; this document has not been fully checked." in
        { warning with severity = 2 } :: diagnostics, None
    | Amlc_analysis.Input_too_large -> [Amlc_lsp.too_large_diagnostic text], None in
  let symbols = List.map (fun (item : Amlc_analysis.declaration) ->
    { Amlc_lsp.id = Option.map (fun span ->
        Printf.sprintf "%s#%s#%d" uri item.kind span.Amlc_analysis.first) item.selection;
      kind = item.kind; name = item.name;
      typ = Option.value ~default:"" item.return_type;
      signature = Some (
        if List.mem item.kind ["function"; "form"; "constructor"] then
          let parameters = if List.length item.parameters = List.length item.parameter_types then
              List.map2 (fun name typ -> name ^ ": " ^ typ) item.parameters item.parameter_types
            else item.parameters in
          item.name ^ "(" ^ String.concat ", " parameters ^ ")"
            ^ Option.fold ~none:"" ~some:(fun typ -> " -> " ^ typ) item.return_type
        else if item.kind = "enumMember" then
          Option.fold ~none:item.name ~some:(fun owner -> owner ^ "." ^ item.name) item.return_type
        else (match item.kind with "local" -> "let " | "parameter" | "iterator" -> "" | kind -> kind ^ " ") ^ item.name
          ^ Option.fold ~none:"" ~some:(fun typ -> ": " ^ typ) item.return_type);
      selection_start = Option.map (fun span -> Amlc_lsp.utf16_position text span.Amlc_analysis.first) item.selection;
      selection_end = Option.map (fun span -> Amlc_lsp.utf16_position text span.Amlc_analysis.last) item.selection;
      completion_scopes = List.map (fun span ->
        Amlc_lsp.utf16_position text span.Amlc_analysis.first,
        Amlc_lsp.utf16_position text span.Amlc_analysis.last) item.visibility;
      occurrences =
        (Option.to_list item.selection |> List.map (fun span -> "declaration", span))
        @ List.map (fun span -> "read", span) item.uses
        |> List.map (fun (role, span) -> role,
          Amlc_lsp.utf16_position text span.Amlc_analysis.first,
          Amlc_lsp.utf16_position text span.Amlc_analysis.last) }) analysis.declarations in
  (* Only compiler-verified occurrences receive semantic colors. Grammar-based
     highlighting remains responsible for unindexed syntax and lexical tokens. *)
  let semantic_tokens = symbols |> List.concat_map (fun (symbol : Amlc_lsp.compiler_symbol) ->
    let kind = match symbol.kind with
      | "function" | "form" -> Some "function"
      | "parameter" -> Some "parameter"
      | "local" | "iterator" -> Some "variable"
      | "field" -> Some "property"
      | "program" | "contract" | "struct" | "enum" | "interface" -> Some "type"
      | _ -> None in
    Option.fold ~none:[] ~some:(fun token_type ->
      symbol.occurrences |> List.filter_map (fun (_, (token_start : Amlc_lsp.position), (token_end : Amlc_lsp.position)) ->
        if token_start.line <> token_end.line || token_start.character >= token_end.character
        then None else Some { Amlc_lsp.token_type; token_start; token_end })) kind)
    |> List.sort_uniq (fun (a : Amlc_lsp.compiler_semantic_token) b ->
      compare (a.token_start.line, a.token_start.character, a.token_end.character, a.token_type)
        (b.token_start.line, b.token_start.character, b.token_end.character, b.token_type)) in
  let memo = Hashtbl.create 16 in
  let members = List.map (fun (site : Amlc_analysis.member_site) ->
    let member_items = match Hashtbl.find_opt memo site.items with
      | Some items -> items
      | None ->
          let items = List.map (fun (name, typ, kind) ->
            Amlc_lsp.completion_item ~kind ~detail:typ name) site.items in
          Hashtbl.add memo site.items items;
          items in
    { Amlc_lsp.member_start = Amlc_lsp.utf16_position text site.member_start;
      member_end = Amlc_lsp.utf16_position text site.member_end; member_items }) analysis.members in
  let signature_memo = Hashtbl.create 16 in
  let signatures = List.map (fun (site : Amlc_analysis.signature_site) ->
    let signature, parameter_count = match Hashtbl.find_opt signature_memo site.signature_name with
      | Some value -> value
      | None ->
        let parameters = List.map (fun (name, typ) -> name ^ ": " ^ typ) site.signature_parameters in
        let value = `List [`Assoc [
        "label", `String (site.signature_name ^ "(" ^ String.concat ", " parameters ^ ") -> " ^ site.signature_return);
        "parameters", `List (List.map (fun label -> `Assoc ["label", `String label]) parameters)]], List.length parameters in
        Hashtbl.add signature_memo site.signature_name value;
        value in
    let signature_help = `Assoc [
      "signatures", signature;
      "activeSignature", `Int 0;
      "activeParameter", `Int (min site.parameter (max 0 (parameter_count - 1)))] in
    { Amlc_lsp.signature_start = Amlc_lsp.utf16_position text site.signature_start;
      signature_end = Amlc_lsp.utf16_position text site.signature_end; signature_help }) analysis.signatures in
  { Amlc_lsp.diagnostics; symbols; semantic_tokens; members; signatures;
    formatting = analysis.formatting; dependencies }

let workspace_analyze method_name roots overlays path source offset replacement =
  match method_name with
  | "references" -> Amlc_analysis.workspace_references ~overlays ~roots ~path source offset
  | "rename" -> Amlc_analysis.workspace_rename ~overlays ~roots ?replacement ~path source offset
  | _ -> `Null

let () = Amlc_lsp.run ~analyze ~workspace_analyze ()
