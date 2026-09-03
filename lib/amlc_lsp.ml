open Yojson.Safe

module Jsonrpc = struct
  let log message = prerr_endline ("amlc-lsp: " ^ message)

  let content_length header =
    match String.split_on_char ':' header with
    | name :: value :: _ when String.lowercase_ascii (String.trim name) = "content-length" ->
        (try Some (int_of_string (String.trim value)) with Failure _ -> None)
    | _ -> None

  let read_headers input =
    let rec loop length =
      match input_line input with
      | exception End_of_file -> None
      | "\r" | "" -> Some length
      | header ->
          let next = match content_length header with Some value -> Some value | None -> length in
          loop next
    in
    loop None

  let read input =
    match read_headers input with
    | None -> None
    | Some None -> failwith "message is missing Content-Length"
    | Some (Some length) when length < 0 -> failwith "message has a negative Content-Length"
    | Some (Some length) -> Some (from_string (really_input_string input length))

  let write output message =
    let body = to_string message in
    Printf.fprintf output "Content-Length: %d\r\n\r\n%s%!" (String.length body) body
end

type position = { line : int; character : int; offset : int option }
type compiler_diagnostic = {
  message : string;
  code : string;
  severity : int;
  start_position : position;
  end_position : position;
}

type document = { text : string; version : int option }
type diagnostic_job = {
  pid : int;
  output : Unix.file_descr;
  buffer : Buffer.t;
  started_at : float;
  mutable eof : bool;
  mutable status : Unix.process_status option;
}
type compiler_symbol = {
  id : string option;
  kind : string;
  name : string;
  typ : string;
  signature : string option;
  selection_start : position option;
  selection_end : position option;
  occurrences : (string * position * position) list;
}
type compiler_semantic_token = {
  token_type : string;
  token_start : position;
  token_end : position;
}
type document_analysis = {
  diagnostics : compiler_diagnostic list;
  symbols : compiler_symbol list;
  semantic_tokens : compiler_semantic_token list;
}
type project_import = { path : string; alias : string }
type contract_import = { path : string; names : string list }
type project_source = {
  path : string;
  dependencies : string list;
  roots : string list;
  imports : project_import list;
  exports : string list;
  symbols : compiler_symbol list;
}
type project_index = { stamp : float; sources : project_source list }

let documents : (string, document) Hashtbl.t = Hashtbl.create 16
let pending_checks : (string, document * float) Hashtbl.t = Hashtbl.create 16
let diagnostic_jobs : (string, diagnostic_job) Hashtbl.t = Hashtbl.create 16
let diagnostic_cache : (string, compiler_diagnostic list) Hashtbl.t = Hashtbl.create 32
let symbol_cache : (string, compiler_symbol list) Hashtbl.t = Hashtbl.create 32
let semantic_token_cache : (string, compiler_semantic_token list) Hashtbl.t = Hashtbl.create 32
let project_symbol_cache : (string, project_index) Hashtbl.t = Hashtbl.create 8
let workspace_roots : string list ref = ref []
let debounce_seconds = 0.2
let max_document_bytes = 1_000_000
let compiler_timeout_seconds = 5.
let analysis_timeout_seconds = (2. *. compiler_timeout_seconds) +. 0.5
let max_compiler_output_bytes = 4_000_000

exception Compiler_timeout of string
exception Compiler_output_limit of string

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()
let max_cached_documents = 64
let initialized = ref false
let shutting_down = ref false

let string_member name json = match Util.member name json with `String value -> Some value | _ -> None
let int_member name json = match Util.member name json with `Int value -> Some value | _ -> None
let object_member name json = match Util.member name json with `Assoc _ as value -> Some value | _ -> None
let string_list_member name json = match Util.member name json with
  | `List values -> Some (List.filter_map (function `String value -> Some value | _ -> None) values)
  | _ -> None

let utf8_width byte =
  if byte land 0x80 = 0 then 1
  else if byte land 0xE0 = 0xC0 then 2
  else if byte land 0xF0 = 0xE0 then 3
  else if byte land 0xF8 = 0xF0 then 4
  else 1

let utf16_width _text _index width = if width = 4 then 2 else 1

let starts_with prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length && String.sub value 0 prefix_length = prefix

let contains text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec walk index =
    index + fragment_length <= text_length
    && (String.sub text index fragment_length = fragment || walk (index + 1))
  in
  fragment_length = 0 || walk 0

let diagnostic_code message =
  if contains message "expected = ) actual =" then "AMLC101"
  else if contains message "expected = } actual =" then "AMLC102"
  else if contains message "expected = ] actual =" then "AMLC103"
  else if contains message "expected = , actual =" then "AMLC104"
  else if contains message "expected = in actual =" then "AMLC105"
  else if contains message "expected = then actual =" then "AMLC106"
  else if contains message "expected = else actual =" then "AMLC107"
  else if contains message "expected = : actual =" then "AMLC108"
  else if starts_with "line" message || starts_with "unexpected" message || starts_with "expected" message then "AMLC100"
  else "AMLC000"

let is_identifier = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '@' -> true
  | _ -> false

let line_start text line =
  let rec walk index current =
    if current >= line || index >= String.length text then index
    else if text.[index] = '\n' then walk (index + 1) (current + 1)
    else walk (index + 1) current
  in
  walk 0 0

let byte_offset text line character =
  let start = line_start text line in
  let rec walk index units =
    if index >= String.length text || text.[index] = '\n' || units >= character then index
    else
      let width = utf8_width (Char.code text.[index]) in
      walk (index + width) (units + utf16_width text index width)
  in
  walk start 0

let word_at text line character =
  let offset = byte_offset text line character in
  let rec left index =
    if index > 0 && is_identifier text.[index - 1] then left (index - 1) else index
  in
  let rec right index =
    if index < String.length text && is_identifier text.[index] then right (index + 1) else index
  in
  let start = left offset in
  let finish = right offset in
  if finish > start then Some (String.sub text start (finish - start), start, finish) else None

type symbol = { name : string; kind : int; start_offset : int; end_offset : int }

let symbols text =
  let lines = String.split_on_char '\n' text in
  let find_name line prefix =
    let length = String.length line in
    let prefix_length = String.length prefix in
    let rec walk index =
      if index + prefix_length > length then None
      else if String.sub line index prefix_length = prefix then
        let start = index + prefix_length in
        let rec finish index =
          if index < length && is_identifier line.[index] then finish (index + 1) else index
        in
        let stop = finish start in
        if stop > start then Some (start, stop) else None
      else walk (index + 1)
    in
    walk 0
  in
  let state_field line =
    let length = String.length line in
    let rec skip index = if index < length && (line.[index] = ' ' || line.[index] = '\t') then skip (index + 1) else index in
    let first = match String.index_opt line '{' with Some index -> skip (index + 1) | None -> skip 0 in
    let rec finish index = if index < length && is_identifier line.[index] then finish (index + 1) else index in
    let last = finish first in
    if last > first && last < length && line.[last] = ':' then Some (first, last) else None
  in
  let rec walk offset in_state out = function
    | [] -> List.rev out
    | line :: rest ->
        let make kind (start, finish) =
          { name = String.sub line start (finish - start); kind; start_offset = offset + start; end_offset = offset + finish }
        in
        let items =
          match find_name line "program " with
          | Some position -> [make 2 position]
          | None ->
              match find_name line "Program " with
              | Some position -> [make 2 position]
              | None -> match find_name line "contract " with
                  | Some position -> [make 5 position]
                  | None -> match find_name line "Contract " with
                      | Some position -> [make 5 position]
                      | None -> match find_name line "form " with
                          | Some position -> [make 12 position]
                          | None -> match find_name line "struct " with
                              | Some position -> [make 23 position]
                              | None -> match find_name line "enum " with
                                  | Some position -> [make 10 position]
                                  | None -> match find_name line "interface " with
                                      | Some position -> [make 11 position]
                                      | None -> match find_name line "event " with
                                          | Some position -> [make 24 position]
                                          | None -> match find_name line "fn " with
                                              | Some position -> [make 12 position]
                                              | None when contains line "constructor" ->
                                                  let first = Option.value ~default:0 (String.index_opt line 'c') in
                                                  [{ name = "constructor"; kind = 9; start_offset = offset + first; end_offset = offset + first + 11 }]
                                              | None when in_state || (contains line "state" && contains line "{") ->
                                                  Option.to_list (Option.map (make 8) (state_field line))
                                              | None -> []
        in
        let opens_state = contains line "state" && contains line "{" in
        let next_state = if (in_state || opens_state) && contains line "}" then false else in_state || opens_state in
        walk (offset + String.length line + 1) next_state (List.rev_append items out) rest
  in
  walk 0 false [] lines

let identifier_occurrences text name =
  let name_length = String.length name in
  let text_length = String.length text in
  let rec walk index out =
    if index + name_length > text_length then List.rev out
    else if String.sub text index name_length = name
        && (index = 0 || not (is_identifier text.[index - 1]))
        && (index + name_length = text_length || not (is_identifier text.[index + name_length]))
    then walk (index + name_length) ((index, index + name_length) :: out)
    else walk (index + 1) out
  in
  if name = "" then [] else walk 0 []

let symbol_named text name =
  List.find_opt (fun symbol -> String.equal symbol.name name) (symbols text)

let valid_identifier name =
  String.length name > 0
  && is_identifier name.[0]
  && String.for_all is_identifier name

let executable_in_path name =
  match Sys.getenv_opt "PATH" with
  | None -> name
  | Some path ->
      let rec find = function
        | [] -> name
        | directory :: rest ->
            let candidate = Filename.concat directory name in
            begin
              try
                Unix.access candidate [Unix.X_OK];
                candidate
              with Unix.Unix_error _ -> find rest
            end
      in
      find (String.split_on_char ':' path)

let compiler_command () =
  match Sys.getenv_opt "AMLC" with
  | Some command when command <> "" -> command
  | _ -> executable_in_path "amlc"

let rehovot_command () =
  match Sys.getenv_opt "REHOVOT_CHECK" with
  | Some command when command <> "" -> command
  | _ -> executable_in_path "rehovot-check"

type dialect = Legacy_amlc | Appliedml

let dialect_override : dialect option ref = ref None

let dialect_of_string = function
  | "legacy" | "legacy-amlc" -> Some Legacy_amlc
  | "appliedml" | "applied" -> Some Appliedml
  | "auto" -> None
  | _ -> None

let set_dialect_override value =
  dialect_override := value;
  Hashtbl.reset diagnostic_cache;
  Hashtbl.reset symbol_cache;
  Hashtbl.reset semantic_token_cache

(* Keep byte offsets intact while hiding comments and strings from the small
   declaration-level heuristics below.  This is deliberately not a second
   parser: the compiler remains authoritative, while editor routing and style
   hints must not mistake prose for source. *)
let source_code_mask text =
  let length = String.length text in
  let masked = Bytes.make length ' ' in
  let preserve_newline index =
    if text.[index] = '\n' then Bytes.set masked index '\n'
  in
  let rec normal index =
    if index >= length then ()
    else if text.[index] = '/' && index + 1 < length && text.[index + 1] = '/'
    then line_comment (index + 2)
    else if text.[index] = '/' && index + 1 < length && text.[index + 1] = '*'
    then block_comment (index + 2)
    else if text.[index] = '"' then string_literal (index + 1)
    else begin
      Bytes.set masked index text.[index];
      normal (index + 1)
    end
  and line_comment index =
    if index >= length then ()
    else if text.[index] = '\n' then begin
      preserve_newline index;
      normal (index + 1)
    end else line_comment (index + 1)
  and block_comment index =
    if index >= length then ()
    else if text.[index] = '*' && index + 1 < length && text.[index + 1] = '/'
    then normal (index + 2)
    else begin
      preserve_newline index;
      block_comment (index + 1)
    end
  and string_literal index =
    if index >= length then ()
    else if text.[index] = '\\' then escaped_character (index + 1)
    else if text.[index] = '"' then normal (index + 1)
    else begin
      preserve_newline index;
      string_literal (index + 1)
    end
  and escaped_character index =
    if index >= length then ()
    else begin
      preserve_newline index;
      string_literal (index + 1)
    end
  in
  normal 0;
  Bytes.unsafe_to_string masked

let has_line_start text prefixes =
  String.split_on_char '\n' text
  |> List.exists (fun line ->
      let line = String.trim line in
      List.exists (fun prefix -> starts_with prefix line) prefixes)

(* [program] is accepted by both compilers.  Its body decides the route: the
   preview language uses [form]/[term], while AppliedML uses [fn] and friends.
   Checking legacy-only forms first prevents an old program from being sent to
   Rehovot merely because both dialects share a declaration header. *)
let document_dialect text =
  match !dialect_override with
  | Some dialect -> dialect
  | None ->
      let code = source_code_mask text in
      if has_line_start code ["form "; "term "] then Legacy_amlc
      else if has_line_start code ["contract "; "Contract "; "program "; "Program ";
                                   "interface "; "Interface "] then Appliedml
      else Legacy_amlc

(* Contract files use the pinned Rehovot parser rather than the bundled preview
   AMLC, whose older grammar reports false lexical errors for [self.field]. *)
let is_appliedml_contract text = document_dialect text = Appliedml

let checker_name text = if is_appliedml_contract text then "rehovot-check" else "amlc"

let terminate_process pid =
  (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
  let deadline = Unix.gettimeofday () +. 0.2 in
  let rec wait () =
    match Unix.waitpid [Unix.WNOHANG] pid with
    | 0, _ when Unix.gettimeofday () < deadline -> ignore (Unix.select [] [] [] 0.02); wait ()
    | 0, _ ->
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
        ignore (Unix.waitpid [] pid)
    | _, _ -> ()
  in
  wait ()

(* Diagnostic workers lead a dedicated process group.  A cancelled worker can
   be waiting on a compiler subprocess, so killing only the worker would leave
   that compiler running after the editor has moved on. *)
let terminate_process_group leader =
  (try Unix.kill (-leader) Sys.sigterm with Unix.Unix_error _ ->
    try Unix.kill leader Sys.sigterm with Unix.Unix_error _ -> ());
  let deadline = Unix.gettimeofday () +. 0.2 in
  let rec wait () =
    match Unix.waitpid [Unix.WNOHANG] leader with
    | 0, _ when Unix.gettimeofday () < deadline ->
        ignore (Unix.select [] [] [] 0.02); wait ()
    | 0, _ ->
        (try Unix.kill (-leader) Sys.sigkill with Unix.Unix_error _ ->
          try Unix.kill leader Sys.sigkill with Unix.Unix_error _ -> ());
        ignore (Unix.waitpid [] leader)
    | _, _ -> ()
  in
  wait ()

(* Compiler output is intentionally collected without a shell.  The event loop
   bounds both elapsed time and captured output so a broken compiler cannot
   indefinitely freeze the language server or exhaust its memory. *)
let read_process command arguments =
  let read_fd, write_fd = Unix.pipe () in
  let null_fd = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0o600 in
  let pid =
    try
      let child = Unix.create_process command (Array.of_list (command :: arguments)) Unix.stdin write_fd null_fd in
      Unix.close write_fd;
      Unix.close null_fd;
      child
    with error ->
      close_noerr read_fd;
      close_noerr write_fd;
      close_noerr null_fd;
      raise error
  in
  let buffer = Buffer.create 512 in
  let bytes = Bytes.create 8192 in
  let deadline = Unix.gettimeofday () +. compiler_timeout_seconds in
  let rec collect child_status eof =
    if Unix.gettimeofday () >= deadline then begin
      close_noerr read_fd;
      terminate_process pid;
      raise (Compiler_timeout command)
    end;
    let readable, _, _ = Unix.select (if eof then [] else [read_fd]) [] [] 0.05 in
    let eof =
      match readable with
      | [] -> eof
      | _ ->
          let count = Unix.read read_fd bytes 0 (Bytes.length bytes) in
          if count = 0 then begin close_noerr read_fd; true end
          else begin
            if Buffer.length buffer + count > max_compiler_output_bytes then begin
              close_noerr read_fd;
              terminate_process pid;
              raise (Compiler_output_limit command)
            end;
            Buffer.add_subbytes buffer bytes 0 count;
            false
          end
    in
    let child_status =
      match child_status with
      | Some _ -> child_status
      | None ->
          match Unix.waitpid [Unix.WNOHANG] pid with
          | 0, _ -> None
          | _, status -> Some status
    in
    match child_status, eof with
    | Some status, true -> status, Buffer.contents buffer
    | _ -> collect child_status eof
  in
  try collect None false with error ->
    close_noerr read_fd;
    (try terminate_process pid with Unix.Unix_error _ -> ());
    raise error

let check_document ?path text =
  (* Keep the temporary source beside the real document when possible.  Rehovot
     imports are relative to their importing file, so /tmp would make an
     otherwise valid [import X from "./x.aml"] look unrelated to its module. *)
  let file =
    match path with
    | Some path -> Filename.temp_file ~temp_dir:(Filename.dirname path) ".amlc-lsp-" ".aml"
    | None -> Filename.temp_file "amlc-lsp-" ".aml"
  in
  Fun.protect ~finally:(fun () -> Sys.remove file) (fun () ->
      let channel = open_out_bin file in
      Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () -> output_string channel text; close_out channel);
      let compiler = if is_appliedml_contract text then rehovot_command () else compiler_command () in
      read_process compiler [ "check"; file; "--diagnostics=json" ])

let position_of_json json =
  match (int_member "line" json, int_member "column" json) with
  | Some line, Some column when line > 0 && column > 0 ->
      Some { line = line - 1; character = column - 1; offset = int_member "offset" json }
  | _ -> None

let symbol_of_json json =
  match string_member "kind" json, string_member "name" json, string_member "type" json with
  | Some kind, Some name, Some typ ->
      let selection =
        match object_member "selectionRange" json with
        | Some selection -> Some selection
        | None -> object_member "range" json
      in
      let selection_start, selection_end =
        match selection with
        | Some selection -> position_of_json (Util.member "start" selection), position_of_json (Util.member "end" selection)
        | None -> None, None
      in
      let occurrences =
        match Util.member "occurrences" json with
        | `List values -> List.filter_map (fun occurrence ->
            match string_member "role" occurrence, object_member "range" occurrence with
            | Some role, Some range ->
                begin match position_of_json (Util.member "start" range), position_of_json (Util.member "end" range) with
                | Some start_position, Some end_position -> Some (role, start_position, end_position)
                | _ -> None
                end
            | _ -> None) values
        | _ -> []
      in
      Some {
        id = string_member "id" json;
        kind; name; typ; signature = string_member "signature" json;
        selection_start; selection_end; occurrences;
      }
  | _ -> None

let semantic_token_of_json json =
  match string_member "type" json, object_member "range" json with
  | Some token_type, Some range ->
      begin match position_of_json (Util.member "start" range), position_of_json (Util.member "end" range) with
      | Some token_start, Some token_end -> Some { token_type; token_start; token_end }
      | _ -> None
      end
  | _ -> None

let compiler_metadata_for_text ?path text =
  let file =
    match path with
    | Some path -> Filename.temp_file ~temp_dir:(Filename.dirname path) ".amlc-lsp-symbols-" ".aml"
    | None -> Filename.temp_file "amlc-lsp-symbols-" ".aml"
  in
  Fun.protect ~finally:(fun () -> Sys.remove file) (fun () ->
      let channel = open_out_bin file in
      Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
          output_string channel text;
          close_out channel);
      let compiler = if is_appliedml_contract text then rehovot_command () else compiler_command () in
      match read_process compiler [ "check"; file; "--symbols=json" ] with
      | Unix.WEXITED 0, output ->
          begin
            try
              match from_string output with
              | `List values -> List.filter_map symbol_of_json values, []
              | `Assoc fields ->
                  let symbols = match List.assoc_opt "symbols" fields with
                    | Some (`List values) -> List.filter_map symbol_of_json values | _ -> [] in
                  let semantic_tokens = match List.assoc_opt "semanticTokens" fields with
                    | Some (`List values) -> List.filter_map semantic_token_of_json values | _ -> [] in
                  symbols, semantic_tokens
              | _ -> [], []
            with Yojson.Json_error _ -> [], []
          end
      | _ -> [], [])

let compiler_symbols_for_text ?path text = fst (compiler_metadata_for_text ?path text)

let symbols_document text =
  match Hashtbl.find_opt symbol_cache text with
  | Some symbols -> symbols
  | None ->
      let symbols = compiler_symbols_for_text text in
      if Hashtbl.length symbol_cache >= max_cached_documents then Hashtbl.reset symbol_cache;
      Hashtbl.replace symbol_cache text symbols;
      symbols

let project_symbols_of_json json =
  match Util.member "sources" json with
  | `List sources -> List.filter_map (fun source ->
      match string_member "path" source, string_list_member "dependencies" source,
          string_list_member "roots" source, Util.member "symbols" source with
      | Some path, Some dependencies, Some roots, symbols_json ->
          let imports =
            match Util.member "imports" source with
            | `List imports -> List.filter_map (fun item ->
                match string_member "path" item, string_member "alias" item with
                | Some path, Some alias -> Some { path; alias }
                | _ -> None) imports
            | _ -> []
          in
          let exports = match string_list_member "exports" source with Some values -> values | None -> [] in
          let symbols =
            match symbols_json with
            | `List symbols -> List.filter_map symbol_of_json symbols
            | `Assoc _ ->
                begin match Util.member "symbols" symbols_json with
                | `List symbols -> List.filter_map symbol_of_json symbols
                | _ -> []
                end
            | _ -> []
          in
          Some { path; dependencies; roots; imports; exports; symbols }
      | _ -> None) sources
  | _ -> []

let canonical_path path = try Unix.realpath path with Unix.Unix_error _ -> path

let path_of_uri uri =
  let path = if starts_with "file://" uri then String.sub uri 7 (String.length uri - 7) else uri in
  canonical_path path

let uri_of_path path = "file://" ^ canonical_path path

let project_manifests () =
  !workspace_roots
  |> List.filter_map (fun root ->
      let path = path_of_uri root in
      let manifest = if String.equal (Filename.extension path) ".amlp" then path else Filename.concat path "project.amlp" in
      if Sys.file_exists manifest then Some manifest else None)

let project_stamp manifest sources =
  let base = Filename.dirname manifest in
  let files = manifest :: List.map (fun source -> Filename.concat base source.path) sources in
  List.fold_left (fun latest path ->
      try max latest (Unix.stat path).Unix.st_mtime with Unix.Unix_error _ -> infinity) 0. files

let project_symbols_document manifest =
  match Hashtbl.find_opt project_symbol_cache manifest with
  | Some index when Float.equal index.stamp (project_stamp manifest index.sources) -> index.sources
  | _ ->
      let sources =
        match read_process (compiler_command ()) [ "check"; manifest; "--symbols=json" ] with
        | Unix.WEXITED 0, output ->
            begin try project_symbols_of_json (from_string output) with Yojson.Json_error _ -> [] end
        | _ -> []
      in
      Hashtbl.replace project_symbol_cache manifest { stamp = project_stamp manifest sources; sources };
      sources

let severity_of_json json =
  match string_member "severity" json with Some "warning" -> 2 | Some "information" -> 3 | Some "hint" -> 4 | _ -> 1

(* The AMLC contract is one JSON diagnostic object per stdout line.  Invalid
   lines are ignored so incidental compiler output cannot break diagnostics. *)
let diagnostic_of_json json =
  match (string_member "message" json, object_member "start" json, object_member "end" json) with
  | Some message, Some start_json, Some end_json ->
      (match (position_of_json start_json, position_of_json end_json) with
      | Some start_position, Some end_position ->
          Some {
            message;
            code = Option.value ~default:(diagnostic_code message) (string_member "code" json);
            severity = severity_of_json json; start_position; end_position;
          }
      | _ -> None)
  | _ -> None

let parse_diagnostics output =
  output |> String.split_on_char '\n' |> List.filter_map (fun line ->
      let line = String.trim line in
      if line = "" then None else try diagnostic_of_json (from_string line) with Yojson.Json_error _ -> None)

let dedupe_diagnostics diagnostics =
  let same left right =
    String.equal left.code right.code
    && String.equal left.message right.message
    && left.start_position.offset = right.start_position.offset
    && left.end_position.offset = right.end_position.offset
  in
  List.fold_left
    (fun kept diagnostic -> if List.exists (same diagnostic) kept then kept else diagnostic :: kept)
    [] diagnostics
  |> List.rev

let utf16_position text offset =
  let limit = min (max 0 offset) (String.length text) in
  let rec walk index line character =
    if index >= limit then { line; character; offset = Some offset }
    else if text.[index] = '\n' then walk (index + 1) (line + 1) 0
    else
      let width = min (utf8_width (Char.code text.[index])) (limit - index) in
      walk (index + width) line (character + utf16_width text index width)
  in
  walk 0 0 0

let lsp_position text position =
  let position = match position.offset with Some offset -> utf16_position text offset | None -> position in
  `Assoc [ ("line", `Int position.line); ("character", `Int position.character) ]

let diagnostic text value =
  `Assoc [
    ("range", `Assoc [ ("start", lsp_position text value.start_position); ("end", lsp_position text value.end_position) ]);
    ("severity", `Int value.severity);
    ("source", `String (if starts_with "REHOVOT" value.code then "rehovot" else "amlc"));
    ("code", `String value.code);
    ("message", `String value.message);
  ]

let fallback_diagnostic text message = diagnostic text {
  message; code = "AMLC000"; severity = 1; start_position = { line = 0; character = 0; offset = None }; end_position = { line = 0; character = 0; offset = None };
}

let compiler_fallback ?(code = "AMLC000") message = {
  message; code; severity = 1;
  start_position = { line = 0; character = 0; offset = None };
  end_position = { line = 0; character = 0; offset = None };
}

(* Rehovot accepts capitalised declaration aliases for compatibility.  Keep
   them valid, but make the canonical spelling discoverable without changing
   the compiler's acceptance rules. *)
let canonical_declaration_diagnostics text =
  if not (is_appliedml_contract text) then [] else
  let code = source_code_mask text in
  let rec walk line offset = function
    | [] -> []
    | value :: rest ->
        let first =
          let rec skip index =
            if index < String.length value && (value.[index] = ' ' || value.[index] = '\t')
            then skip (index + 1) else index
          in skip 0
        in
        let replacement =
          if starts_with "Contract " (String.sub value first (String.length value - first))
          then Some ("REHOVOT001", "Contract is a compatibility spelling; use contract", "Contract")
          else if starts_with "Program " (String.sub value first (String.length value - first))
          then Some ("REHOVOT002", "Program is a compatibility spelling; use program", "Program")
          else None
        in
        let current = Option.to_list (Option.map (fun (code, message, word) -> {
            message; code; severity = 2;
            start_position = { line; character = first; offset = Some (offset + first) };
            end_position = { line; character = first + String.length word;
                             offset = Some (offset + first + String.length word) };
          }) replacement) in
        current @ walk (line + 1) (offset + String.length value + 1) rest
  in
  walk 0 0 (String.split_on_char '\n' code)

let too_large_diagnostic text = {
  message = Printf.sprintf "document exceeds the %d byte analysis limit" max_document_bytes;
  code = "AMLC900"; severity = 2;
  start_position = { line = 0; character = 0; offset = Some 0 };
  end_position = { line = 0; character = 0; offset = Some (min 1 (String.length text)) };
}

let has_machine_diagnostics output =
  String.split_on_char '\n' output
  |> List.filter (fun line -> String.trim line <> "")
  |> List.for_all (fun line ->
      try
        match from_string line with
        | `Assoc fields ->
            List.mem_assoc "message" fields && List.mem_assoc "start" fields && List.mem_assoc "end" fields
        | _ -> false
      with Yojson.Json_error _ -> false)

let publish output uri diagnostics =
  Jsonrpc.write output (`Assoc [
    ("jsonrpc", `String "2.0"); ("method", `String "textDocument/publishDiagnostics");
    ("params", `Assoc [ ("uri", `String uri); ("diagnostics", `List diagnostics) ]);
  ])

let parse_project_diagnostics output =
  output |> String.split_on_char '\n' |> List.filter_map (fun line ->
      let line = String.trim line in
      if line = "" then None else
      try Option.bind (string_member "path" (from_string line)) (fun path ->
          Option.map (fun diagnostic -> path, diagnostic) (diagnostic_of_json (from_string line)))
      with Yojson.Json_error _ -> None)

let import_position text (item : project_import) =
  let needle = "import \"" ^ item.path ^ "\" as " ^ item.alias in
  let rec find line = function
    | [] -> { line = 0; character = 0; offset = Some 0 }
    | value :: rest ->
        if contains value needle then
          { line; character = 0; offset = Some (line_start text line) }
        else find (line + 1) rest
  in
  find 0 (String.split_on_char '\n' text)

let module_import_diagnostics manifest sources =
  let base = Filename.dirname manifest in
  let known = List.map (fun (source : project_source) ->
      canonical_path (Filename.concat base source.path)) sources in
  sources |> List.concat_map (fun (source : project_source) ->
      let full_path = canonical_path (Filename.concat base source.path) in
      let text =
        let uri = uri_of_path full_path in
        match Hashtbl.find_opt documents uri with
        | Some document -> document.text
        | None ->
            begin try In_channel.with_open_bin full_path In_channel.input_all
            with Sys_error _ -> ""
            end
      in
      let seen = Hashtbl.create 4 in
      source.imports |> List.filter_map (fun (item : project_import) ->
          let target = canonical_path (Filename.concat (Filename.dirname full_path) item.path) in
          let issue =
            if Hashtbl.mem seen item.alias then
              Some ("AMLC202", "import alias is repeated: " ^ item.alias)
            else if String.equal target full_path then
              Some ("AMLC203", "module cannot import itself: " ^ item.path)
            else if not (List.mem target known) then
              Some ("AMLC201", "import target is not a project source: " ^ item.path)
            else None
          in
          Hashtbl.replace seen item.alias true;
          Option.map (fun (code, message) ->
              let start_position = import_position text item in
              let end_position = { start_position with character = String.length item.alias } in
              full_path, { message; code; severity = 1; start_position; end_position }) issue))

let project_module_diagnostics () =
  project_manifests () |> List.concat_map (fun manifest ->
      module_import_diagnostics manifest (project_symbols_document manifest))

let module_diagnostics_for_uri uri text =
  if not (contains text "import ") then [] else
  project_manifests () |> List.concat_map (fun manifest ->
      match read_process (compiler_command ()) [ "check"; manifest; "--diagnostics=json" ] with
      | _, output ->
          let base = Filename.dirname manifest in
          parse_project_diagnostics output |> List.filter_map (fun (relative, diagnostic) ->
              let path = canonical_path (Filename.concat base relative) in
              if String.equal (uri_of_path path) uri then Some diagnostic else None))

let publish_project_diagnostics output =
  List.iter (fun manifest ->
      match read_process (compiler_command ()) [ "check"; manifest; "--diagnostics=json" ] with
      | _, details ->
          let base = Filename.dirname manifest in
          let grouped = Hashtbl.create 8 in
          List.iter (fun (relative, diagnostic) ->
              let full = canonical_path (Filename.concat base relative) in
              let current = Option.value ~default:[] (Hashtbl.find_opt grouped full) in
              Hashtbl.replace grouped full (diagnostic :: current)) (parse_project_diagnostics details);
          Hashtbl.iter (fun path diagnostics ->
              let uri = uri_of_path path in
              if not (Hashtbl.mem documents uri) then
                begin try
                  let text = In_channel.with_open_bin path In_channel.input_all in
                  publish output uri (List.rev_map (diagnostic text) diagnostics)
                with Sys_error _ -> ()
                end) grouped
      ) (project_manifests ())

let diagnostics_for_text uri text =
  if String.length text > max_document_bytes then [too_large_diagnostic text]
  else
    match Hashtbl.find_opt diagnostic_cache text with
    | Some diagnostics -> diagnostics
    | None ->
        let diagnostics =
          try
            let status, details = check_document ~path:(path_of_uri uri) text in
            let diagnostics = parse_diagnostics details |> dedupe_diagnostics in
            if not (has_machine_diagnostics details) then
              [compiler_fallback
                ~code:(if is_appliedml_contract text then "REHOVOT900" else "AMLC901")
                (checker_name text ^ " does not support the required JSON diagnostics interface")]
            else begin
              match status with
              | Unix.WEXITED 0 -> diagnostics
              | _ when diagnostics <> [] -> diagnostics
              | _ -> [compiler_fallback (checker_name text ^ " check failed without JSON diagnostics")]
            end
          with
          | Compiler_timeout command ->
              [compiler_fallback
                ~code:(if is_appliedml_contract text then "REHOVOT902" else "AMLC902")
                (command ^ " exceeded the 5 second analysis timeout")]
          | Compiler_output_limit command ->
              [compiler_fallback
                ~code:(if is_appliedml_contract text then "REHOVOT903" else "AMLC903")
                (command ^ " exceeded the 4 MB compiler-output limit")]
          | Unix.Unix_error (error, _, _) ->
              [compiler_fallback ("could not run " ^ checker_name text ^ ": " ^ Unix.error_message error)]
        in
        let diagnostics = diagnostics @ canonical_declaration_diagnostics text in
        if Hashtbl.length diagnostic_cache >= max_cached_documents then Hashtbl.reset diagnostic_cache;
        Hashtbl.replace diagnostic_cache text diagnostics;
        diagnostics

let analyze_document uri text =
  let diagnostics = diagnostics_for_text uri text in
  let symbols, semantic_tokens =
    if List.exists (fun diagnostic -> diagnostic.severity = 1) diagnostics then [], []
    else
      try compiler_metadata_for_text ~path:(path_of_uri uri) text with
      | Compiler_timeout _ | Compiler_output_limit _ | Unix.Unix_error _ -> [], []
  in
  { diagnostics; symbols; semantic_tokens }

let publish_diagnostics output uri text diagnostics =
  publish output uri (List.map (diagnostic text) diagnostics)

let cancel_diagnostic_job uri =
  match Hashtbl.find_opt diagnostic_jobs uri with
  | None -> ()
  | Some job ->
      Hashtbl.remove diagnostic_jobs uri;
      close_noerr job.output;
      (try terminate_process_group job.pid with Unix.Unix_error _ -> ())

let start_diagnostic_job uri document =
  cancel_diagnostic_job uri;
  let read_fd, write_fd = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      close_noerr read_fd;
      ignore (Unix.setsid ());
      let channel = Unix.out_channel_of_descr write_fd in
      let result =
        try Ok (analyze_document uri document.text)
        with error -> Error (Printexc.to_string error)
      in
      Marshal.to_channel channel result [];
      close_out_noerr channel;
      exit 0
  | pid ->
      close_noerr write_fd;
      Hashtbl.replace diagnostic_jobs uri {
        pid; output = read_fd; buffer = Buffer.create 512; started_at = Unix.gettimeofday ();
        eof = false; status = None;
      }

let collect_job_output job =
  let bytes = Bytes.create 8192 in
  let count = Unix.read job.output bytes 0 (Bytes.length bytes) in
  if count = 0 then begin close_noerr job.output; job.eof <- true end
  else if Buffer.length job.buffer + count > max_compiler_output_bytes + 65_536 then begin
    close_noerr job.output;
    job.eof <- true
  end else Buffer.add_subbytes job.buffer bytes 0 count

let finish_diagnostic_job output uri document job =
  Hashtbl.remove diagnostic_jobs uri;
  close_noerr job.output;
  let diagnostics =
    try
      match (Marshal.from_bytes (Bytes.of_string (Buffer.contents job.buffer)) 0 :
        (document_analysis, string) result) with
      | Ok analysis ->
          if Hashtbl.length symbol_cache >= max_cached_documents then Hashtbl.reset symbol_cache;
          Hashtbl.replace symbol_cache document.text analysis.symbols;
          if Hashtbl.length semantic_token_cache >= max_cached_documents then Hashtbl.reset semantic_token_cache;
          Hashtbl.replace semantic_token_cache document.text analysis.semantic_tokens;
          analysis.diagnostics
      | Error message -> [compiler_fallback ("diagnostic worker failed: " ^ message)]
    with _ -> [compiler_fallback "diagnostic worker returned invalid output"]
  in
  match Hashtbl.find_opt documents uri with
  | Some current when String.equal current.text document.text ->
      publish_diagnostics output uri current.text diagnostics
  | _ -> ()

let poll_diagnostic_jobs output readable =
  let now = Unix.gettimeofday () in
  Hashtbl.to_seq diagnostic_jobs |> List.of_seq |> List.iter (fun (uri, job) ->
      if now -. job.started_at >= analysis_timeout_seconds then begin
        Hashtbl.remove diagnostic_jobs uri;
        close_noerr job.output;
        (try terminate_process_group job.pid with Unix.Unix_error _ -> ());
        match Hashtbl.find_opt documents uri with
        | Some document ->
            publish_diagnostics output uri document.text
              [compiler_fallback
                ~code:(if is_appliedml_contract document.text then "REHOVOT902" else "AMLC902")
                "compiler worker exceeded the analysis timeout"]
        | None -> ()
      end else begin
        if List.mem job.output readable && not job.eof then collect_job_output job;
        if job.status = None then
          match Unix.waitpid [Unix.WNOHANG] job.pid with
          | 0, _ -> ()
          | _, status -> job.status <- Some status;
        if job.eof && Option.is_some job.status then
          match Hashtbl.find_opt documents uri with
          | Some document -> finish_diagnostic_job output uri document job
          | None -> Hashtbl.remove diagnostic_jobs uri
      end)

let schedule_diagnostics uri document =
  cancel_diagnostic_job uri;
  Hashtbl.replace pending_checks uri (document, Unix.gettimeofday () +. debounce_seconds)

let flush_due_diagnostics _output =
  let now = Unix.gettimeofday () in
  let due = Hashtbl.fold (fun uri (document, deadline) due ->
      if deadline <= now then (uri, document) :: due else due) pending_checks [] in
  List.iter (fun (uri, document) ->
      Hashtbl.remove pending_checks uri;
      match Hashtbl.find_opt documents uri with
      | Some current when String.equal current.text document.text -> start_diagnostic_job uri current
      | _ -> ()) due

let next_check_timeout () =
  Hashtbl.fold (fun _ (_, deadline) timeout ->
      min timeout (max 0. (deadline -. Unix.gettimeofday ()))) pending_checks 1.0

let response id result = `Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ]
let error_response id code message = `Assoc [
  ("jsonrpc", `String "2.0"); ("id", id); ("error", `Assoc [ ("code", `Int code); ("message", `String message) ]);
]

let initialize_result = `Assoc [
  ("capabilities", `Assoc [
    ("textDocumentSync", `Assoc [ ("openClose", `Bool true); ("change", `Int 2) ]);
    ("diagnosticProvider", `Assoc [
      ("identifier", `String "amlc-lsp");
      ("interFileDependencies", `Bool false);
      ("workspaceDiagnostics", `Bool false);
    ]);
    ("completionProvider", `Assoc [ ("triggerCharacters", `List []) ]);
    ("documentSymbolProvider", `Bool true);
    ("hoverProvider", `Bool true);
    ("definitionProvider", `Bool true);
    ("declarationProvider", `Bool true);
    ("referencesProvider", `Bool true);
    ("renameProvider", `Assoc [ ("prepareProvider", `Bool true) ]);
    ("codeActionProvider", `Bool true);
    ("documentFormattingProvider", `Bool true);
    ("documentHighlightProvider", `Bool true);
    ("inlayHintProvider", `Bool true);
    ("foldingRangeProvider", `Bool true);
    ("selectionRangeProvider", `Bool true);
    ("semanticTokensProvider", `Assoc [
      ("legend", `Assoc [ ("tokenTypes", `List [
        `String "keyword"; `String "type"; `String "function"; `String "parameter";
        `String "property"; `String "event"; `String "variable"; `String "string";
        `String "number"; `String "operator";
      ]); ("tokenModifiers", `List []) ]);
      ("full", `Bool true);
      ("range", `Bool false);
    ]);
    ("signatureHelpProvider", `Assoc [ ("triggerCharacters", `List [`String "("; `String ","]) ]);
    ("workspaceSymbolProvider", `Bool true);
    ("workspace", `Assoc [ ("workspaceFolders", `Assoc [
      ("supported", `Bool true); ("changeNotifications", `Bool true);
    ]) ]);
    ("serverInfo", `Assoc [ ("name", `String "amlc-lsp"); ("version", `String "0.1.0") ]);
  ]);
]

let position_from_params params =
  Option.bind (object_member "position" params) (fun position ->
      Option.bind (int_member "line" position) (fun line ->
          Option.map (fun character -> line, character) (int_member "character" position)))

let uri_from_params params =
  Option.bind (object_member "textDocument" params) (string_member "uri")

let workspace_roots_from_params params =
  let root_uri = match string_member "rootUri" params with Some uri -> [uri] | None -> [] in
  let folders = match Util.member "workspaceFolders" params with
    | `List values -> List.filter_map (string_member "uri") values
    | _ -> []
  in
  List.sort_uniq String.compare (root_uri @ folders)

let apply_workspace_folder_change params =
  match object_member "event" params with
  | None -> ()
  | Some event ->
      let uris name = match Util.member name event with
        | `List folders -> List.filter_map (string_member "uri") folders
        | _ -> [] in
      let added = uris "added" in
      let removed = uris "removed" in
      workspace_roots := !workspace_roots
        |> List.filter (fun uri -> not (List.mem uri removed))
        |> List.append added
        |> List.sort_uniq String.compare;
      Hashtbl.reset project_symbol_cache

let range_from_offsets text first last =
  `Assoc [
    ("start", lsp_position text (utf16_position text first));
    ("end", lsp_position text (utf16_position text last));
  ]

let location uri text symbol =
  `Assoc [
    ("uri", `String uri);
    ("range", range_from_offsets text symbol.start_offset symbol.end_offset);
  ]

let compiler_location uri text (symbol : compiler_symbol) =
  match symbol.selection_start, symbol.selection_end with
  | Some start_position, Some end_position ->
      Some (`Assoc [
        ("uri", `String uri);
        ("range", `Assoc [
          ("start", lsp_position text start_position);
          ("end", lsp_position text end_position);
        ]);
      ])
  | _ -> None

let compiler_occurrence_locations ?(include_declaration = true) uri text (symbol : compiler_symbol) =
  symbol.occurrences
  |> List.filter (fun (role, _, _) -> include_declaration || not (String.equal role "declaration"))
  |> List.map (fun (_role, start_position, end_position) ->
      `Assoc [
        ("uri", `String uri);
        ("range", `Assoc [
          ("start", lsp_position text start_position);
          ("end", lsp_position text end_position);
        ]);
      ])

let compiler_occurrence_edits text replacement (symbol : compiler_symbol) =
  symbol.occurrences
  |> List.map (fun (_role, start_position, end_position) ->
      `Assoc [
        ("range", `Assoc [
          ("start", lsp_position text start_position);
          ("end", lsp_position text end_position);
        ]);
        ("newText", `String replacement);
      ])

let position_in_range text line character start_position end_position =
  let normalise position =
    match position.offset with Some offset -> utf16_position text offset | None -> position
  in
  let start_position = normalise start_position in
  let end_position = normalise end_position in
  (line > start_position.line
   || (line = start_position.line && character >= start_position.character))
  && (line < end_position.line
      || (line = end_position.line && character < end_position.character))

let compiler_occurrence_at document line character =
  Option.bind (word_at document.text line character) (fun (word, _, _) ->
      Option.bind (Hashtbl.find_opt symbol_cache document.text) (fun symbols ->
          List.find_map (fun (symbol : compiler_symbol) ->
              if not (String.equal symbol.name word) then None else
              List.find_map (fun (role, start_position, end_position) ->
                  if position_in_range document.text line character start_position end_position
                  then Some (symbol, role, start_position, end_position)
                  else None) symbol.occurrences) symbols))

let legacy_completion_keywords = [
  "program"; "term"; "form"; "let"; "in"; "if"; "then"; "else";
  "case"; "of"; "use"; "split"; "fold"; "every"; "any"; "count";
  "total"; "true"; "false"; "unit"; "int"; "bool"; "bytes"; "vec";
]

(* AppliedML spellings documented by Octra's current examples and cheatsheet.
   The compiler accepts additional compatibility aliases; those remain valid,
   but are not presented as the default completion path. *)
let appliedml_completion_keywords = [
  "program"; "contract"; "state"; "event"; "constructor";
  "fn"; "view"; "pure"; "private"; "public"; "internal"; "payable";
  "const"; "return"; "assert"; "require"; "emit"; "while"; "for";
  "self"; "caller"; "origin"; "epoch"; "epoch_time"; "value"; "balance";
  "invariant"; "struct"; "enum"; "match"; "interface"; "implements";
  "import"; "error"; "revert"; "where"; "option";
  "unwrap"; "is_some"; "self_addr"; "tree_hash";
  "node_id"; "tx_hash"; "nonreentrant"; "log"; "indexed";
]

let completion_keywords = legacy_completion_keywords @ appliedml_completion_keywords

let completion_keywords_for text =
  match document_dialect text with
  | Legacy_amlc -> legacy_completion_keywords
  | Appliedml -> appliedml_completion_keywords

(* Snapshot of the type alternatives in Octra node's Rehovot parse_type.
   Legacy [unit] and [vec] remain below solely for preview AMLC documents. *)
let appliedml_types = [
  "int"; "bool"; "bytes"; "bytes32"; "string"; "address";
  "u64"; "u128"; "u256"; "uint"; "cipher"; "pubkey";
  "map"; "list"; "Option"; "option";
]

let aml_types = "unit" :: "vec" :: appliedml_types

let completion_item ?(kind = 14) ?(detail = "AMLC") label =
  `Assoc [ ("label", `String label); ("kind", `Int kind); ("detail", `String detail) ]

let symbol_completion_item (symbol : compiler_symbol) =
  completion_item ~kind:3 ~detail:(Option.value ~default:symbol.typ symbol.signature) symbol.name

let lsp_symbol_kind = function
  | "program" | "contract" | "interface" -> 2
  | "struct" -> 23
  | "enum" -> 10
  | "field" -> 8
  | "event" -> 24
  | "constant" -> 14
  | "function" | "form" | "method" | "constructor" -> 12
  | _ -> 13

let text_edit text first last replacement =
  `Assoc [ ("range", range_from_offsets text first last); ("newText", `String replacement) ]

let positions_for_symbol uri text name =
  identifier_occurrences text name
  |> List.map (fun (first, last) ->
      `Assoc [ ("uri", `String uri); ("range", range_from_offsets text first last) ])

let form_declaration_at text name first =
  List.exists (fun symbol ->
      symbol.kind = 12 && String.equal symbol.name name && symbol.start_offset = first) (symbols text)

let direct_call_at text last =
  let rec skip index =
    if index < String.length text && (text.[index] = ' ' || text.[index] = '\t' || text.[index] = '\n') then skip (index + 1)
    else index
  in
  let next = skip last in
  next < String.length text && text.[next] = '('

(* AMLC forms are declared with [form] and invoked with a direct call.  Limiting
   edits to those two syntactic roles avoids renaming a same-spelled local bind. *)
let semantic_occurrences text name =
  identifier_occurrences text name
  |> List.filter (fun (first, last) -> form_declaration_at text name first || direct_call_at text last)

let compiler_form document name =
  List.find_opt (fun (symbol : compiler_symbol) ->
      List.mem symbol.kind ["form"; "function"; "constructor"] && String.equal symbol.name name)
    (Option.value ~default:[] (Hashtbl.find_opt symbol_cache document.text))

let open_documents () =
  Hashtbl.fold (fun uri document documents -> (uri, document) :: documents) documents []

let declaration_locations name =
  open_documents ()
  |> List.concat_map (fun (uri, document) ->
      symbols document.text
      |> List.filter (fun symbol -> String.equal symbol.name name)
      |> List.map (location uri document.text))

let documents_declaring name =
  open_documents ()
  |> List.filter (fun (_uri, document) -> Option.is_some (symbol_named document.text name))

let trim_right value =
  let rec last index =
    if index > 0 && (value.[index - 1] = ' ' || value.[index - 1] = '\t') then last (index - 1) else index
  in
  let length = last (String.length value) in
  if length = String.length value then value else String.sub value 0 length

let count_character value character =
  String.fold_left (fun count current -> if current = character then count + 1 else count) 0 value

let structural_braces value =
  let rec scan index in_string escaped opens closes =
    if index >= String.length value then opens, closes
    else
      let current = value.[index] in
      if in_string then
        if escaped then scan (index + 1) true false opens closes
        else if current = '\\' then scan (index + 1) true true opens closes
        else if current = '"' then scan (index + 1) false false opens closes
        else scan (index + 1) true false opens closes
      else if current = '/' && index + 1 < String.length value && value.[index + 1] = '/' then opens, closes
      else if current = '"' then scan (index + 1) true false opens closes
      else if current = '{' then scan (index + 1) false false (opens + 1) closes
      else if current = '}' then scan (index + 1) false false opens (closes + 1)
      else scan (index + 1) false false opens closes
  in
  scan 0 false false 0 0

let format_document text =
  let _, lines = List.fold_left (fun (depth, formatted) line ->
      let content = String.trim (trim_right line) in
      if content = "" then depth, "" :: formatted
      else
        let closing = if starts_with "}" content then 1 else 0 in
        let indentation = max 0 (depth - closing) in
        let opens, closes = structural_braces content in
        let next_depth = max 0 (depth + opens - closes) in
        next_depth, (String.make (indentation * 2) ' ' ^ content) :: formatted)
    (0, []) (String.split_on_char '\n' text)
  in
  String.concat "\n" (List.rev lines)

(* The formatter only changes indentation and outer whitespace.  Multiline
   strings/comments are deliberately left alone: changing their line layout
   would preserve syntax while unexpectedly changing user-visible content. *)
let has_multiline_sensitive_lexeme text =
  let rec scan index in_string in_comment escaped =
    if index >= String.length text then in_string || in_comment
    else if in_comment then
      if index + 1 < String.length text && text.[index] = '*' && text.[index + 1] = '/'
      then scan (index + 2) in_string false false
      else if text.[index] = '\n' then true
      else scan (index + 1) in_string true false
    else if in_string then
      if text.[index] = '\n' then true
      else if escaped then scan (index + 1) true false false
      else if text.[index] = '\\' then scan (index + 1) true false true
      else if text.[index] = '"' then scan (index + 1) false false false
      else scan (index + 1) true false false
    else if index + 1 < String.length text && text.[index] = '/' && text.[index + 1] = '*'
    then scan (index + 2) false true false
    else if text.[index] = '"' then scan (index + 1) true false false
    else scan (index + 1) false false false
  in
  scan 0 false false false

let compiler_accepts ?path text =
  try
    let status, output = check_document ?path text in
    status = Unix.WEXITED 0 && has_machine_diagnostics output
      && not (List.exists (fun diagnostic -> diagnostic.severity = 1) (parse_diagnostics output))
  with Compiler_timeout _ | Compiler_output_limit _ | Unix.Unix_error _ -> false

let semantic_token_type forms parameters word =
  if List.mem word aml_types then 3
  else if List.mem word completion_keywords then 0
  else if List.mem word forms then 1
  else if List.mem word parameters then 4
  else 2

let form_parameters text =
  let rec scan index values =
    if index >= String.length text then List.rev values
    else
      let marker = if starts_with "many " (String.sub text index (String.length text - index)) then Some 5
        else if starts_with "once " (String.sub text index (String.length text - index)) then Some 5
        else None
      in
      match marker with
      | None -> scan (index + 1) values
      | Some length ->
          let first = index + length in
          let rec finish last = if last < String.length text && is_identifier text.[last] then finish (last + 1) else last in
          let last = finish first in
          if last > first && last < String.length text && text.[last] = ':' then
            scan last (String.sub text first (last - first) :: values)
          else scan first values
  in
  scan 0 []

let contract_parameters text =
  let identifiers_before_colon value =
    let length = String.length value in
    let rec scan index out =
      if index >= length then out
      else if not (is_identifier value.[index]) then scan (index + 1) out
      else
        let rec finish cursor = if cursor < length && is_identifier value.[cursor] then finish (cursor + 1) else cursor in
        let stop = finish index in
        let rec spaces cursor = if cursor < length && (value.[cursor] = ' ' || value.[cursor] = '\t') then spaces (cursor + 1) else cursor in
        let next = spaces stop in
        if next < length && value.[next] = ':' then scan stop (String.sub value index (stop - index) :: out)
        else scan stop out
    in
    scan 0 []
  in
  String.split_on_char '\n' text |> List.concat_map (fun line ->
      match String.index_opt line '(' with
      | None -> []
      | Some first ->
          let remainder = String.sub line (first + 1) (String.length line - first - 1) in
          let parameters = match String.index_opt remainder ')' with Some last -> String.sub remainder 0 last | None -> remainder in
          identifiers_before_colon parameters)

let semantic_token_kind = function
  | "keyword" -> 0 | "type" -> 1 | "function" -> 2 | "parameter" -> 3
  | "property" -> 4 | "event" -> 5 | "variable" -> 6 | "string" -> 7
  | "number" -> 8 | "operator" -> 9 | _ -> 6

let semantic_tokens text compiler_symbols compiler_tokens =
  let compiler_tokens = compiler_tokens |> List.map (fun token ->
      let start_position = match token.token_start.offset with Some offset -> utf16_position text offset | None -> token.token_start in
      let end_position = match token.token_end.offset with Some offset -> utf16_position text offset | None -> token.token_end in
      start_position.line, start_position.character,
      max 0 (end_position.character - start_position.character), semantic_token_kind token.token_type) in
  let tokens = if compiler_tokens <> [] then compiler_tokens else compiler_symbols
    |> List.concat_map (fun (symbol : compiler_symbol) ->
        if not (List.mem symbol.kind ["form"; "function"; "method"; "constructor"])
        then [] else
        symbol.occurrences |> List.map (fun (_role, start_position, end_position) ->
            let start_position = match start_position.offset with Some offset -> utf16_position text offset | None -> start_position in
            let end_position = match end_position.offset with Some offset -> utf16_position text offset | None -> end_position in
            start_position.line, start_position.character,
            max 0 (end_position.character - start_position.character), semantic_token_kind "function"))
    |> List.sort compare
  in
  let _, _, data = List.fold_left (fun (previous_line, previous_character, output) (line, character, width, kind) ->
      let line_delta = line - previous_line in
      let character_delta = if line_delta = 0 then character - previous_character else character in
      (line, character, output @ [ line_delta; character_delta; width; kind; 0 ]))
    (0, 0, []) tokens
  in
  `Assoc [ ("data", `List (List.map (fun value -> `Int value) data)) ]

let case_contains text query = contains (String.lowercase_ascii text) (String.lowercase_ascii query)

let project_source_text uri path =
  match Hashtbl.find_opt documents uri with
  | Some document -> Some document.text
  | None ->
      begin try Some (In_channel.with_open_bin path In_channel.input_all) with Sys_error _ -> None end

let substring_index text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec walk index =
    if index + needle_length > text_length then None
    else if String.sub text index needle_length = needle then Some index
    else walk (index + 1)
  in
  if needle = "" then Some 0 else walk 0

let contract_imports text =
  String.split_on_char '\n' text |> List.filter_map (fun line ->
      let line = String.trim line in
      if not (starts_with "import " line) then None else
      let body = String.sub line 7 (String.length line - 7) in
      match substring_index body " from \"" with
      | None -> None
      | Some marker ->
          let names = String.sub body 0 marker |> String.split_on_char ',' |> List.map String.trim |> List.filter valid_identifier in
          let path_start = marker + 7 in
          match String.index_from_opt body path_start '"' with
          | None -> None
          | Some _ when names = [] -> None
          | Some path_end -> Some { names; path = String.sub body path_start (path_end - path_start) })

let contract_import_target uri text name =
  let current = path_of_uri uri in
  contract_imports text |> List.find_map (fun (imported : contract_import) ->
      if not (List.mem name imported.names) then None else
      let target = canonical_path (Filename.concat (Filename.dirname current) imported.path) in
      let target_uri = uri_of_path target in
      Option.map (fun target_text -> target_uri, target_text) (project_source_text target_uri target))

let contract_import_definition uri text name =
  match contract_import_target uri text name with
  | None -> None
  | Some (target_uri, target_text) ->
      Option.map (location target_uri target_text)
        (List.find_opt (fun symbol -> String.equal symbol.name name) (symbols target_text))

let quoted_at text offset =
  let start =
    let rec walk index =
      if index <= 0 || text.[index - 1] = '\n' then index else walk (index - 1)
    in
    walk (min offset (String.length text))
  in
  let rec scan index in_string escaped =
    if index >= offset then in_string
    else if in_string then
      if escaped then scan (index + 1) true false
      else if text.[index] = '\\' then scan (index + 1) true true
      else if text.[index] = '"' then scan (index + 1) false false
      else scan (index + 1) true false
    else if text.[index] = '"' then scan (index + 1) true false
    else scan (index + 1) false false
  in
  scan start false false

let contract_import_references uri text name =
  Option.map (fun (target_uri, target_text) ->
      let local = identifier_occurrences text name
        |> List.filter (fun (first, _) -> not (quoted_at text first))
        |> List.map (fun (first, last) -> `Assoc [ ("uri", `String uri); ("range", range_from_offsets text first last) ]) in
      let declaration = symbols target_text
        |> List.find_opt (fun symbol -> String.equal symbol.name name)
        |> Option.to_list
        |> List.map (fun symbol -> `Assoc [ ("uri", `String target_uri); ("range", range_from_offsets target_text symbol.start_offset symbol.end_offset) ]) in
      declaration @ local) (contract_import_target uri text name)

let contract_rename_imported uri text name replacement =
  Option.map (fun (target_uri, target_text) ->
      let current_edits = identifier_occurrences text name
        |> List.filter (fun (first, _) -> not (quoted_at text first))
        |> List.map (fun (first, last) -> text_edit text first last replacement) in
      let target_edits = identifier_occurrences target_text name
        |> List.map (fun (first, last) -> text_edit target_text first last replacement) in
      `Assoc [ ("changes", `Assoc [ (uri, `List current_edits); (target_uri, `List target_edits) ]) ])
    (contract_import_target uri text name)

let contract_imported_symbols uri text =
  let current = path_of_uri uri in
  contract_imports text |> List.concat_map (fun (imported : contract_import) ->
      let target = canonical_path (Filename.concat (Filename.dirname current) imported.path) in
      let target_uri = uri_of_path target in
      match project_source_text target_uri target with
      | None -> []
      | Some target_text -> symbols_document target_text
          |> List.filter (fun (symbol : compiler_symbol) -> List.mem symbol.name imported.names)
          |> List.map (fun (symbol : compiler_symbol) -> symbol.name, Option.value ~default:symbol.typ symbol.signature))

let qualified_alias text start =
  if start = 0 || text.[start - 1] <> '.' then None
  else
    let rec left index =
      if index > 0 && is_identifier text.[index - 1] then left (index - 1) else index
    in
    let finish = start - 1 in
    let first = left finish in
    if finish > first then Some (String.sub text first (finish - first)) else None

let completion_alias text line character =
  let offset = byte_offset text line character in
  let rec left index =
    if index > 0 && is_identifier text.[index - 1] then left (index - 1) else index
  in
  let word_start = left offset in
  if word_start = 0 || text.[word_start - 1] <> '.' then None else
  let alias_end = word_start - 1 in
  let alias_start = left alias_end in
  if alias_start = alias_end then None
  else Some (String.sub text alias_start (alias_end - alias_start))

let qualified_occurrences text alias name =
  identifier_occurrences text name
  |> List.filter (fun (first, _last) ->
      first > String.length alias
      && text.[first - 1] = '.'
      && String.sub text (first - String.length alias - 1) (String.length alias) = alias)

let qualified_import_definition uri text start name =
  match qualified_alias text start with
  | None -> None
  | Some alias ->
      let current = path_of_uri uri in
      let rec manifests = function
        | [] -> None
        | manifest :: rest ->
            let base = Filename.dirname manifest in
            let sources = project_symbols_document manifest in
            match List.find_opt (fun (source : project_source) ->
                String.equal (canonical_path (Filename.concat base source.path)) current) sources with
            | None -> manifests rest
            | Some source ->
                begin match List.find_opt (fun item -> String.equal item.alias alias) source.imports with
                | None -> manifests rest
                | Some imported ->
                    let target = canonical_path
                      (Filename.concat (Filename.dirname current) imported.path) in
                    begin match List.find_opt (fun (candidate : project_source) ->
                        String.equal (canonical_path (Filename.concat base candidate.path)) target
                        && List.mem name candidate.exports) sources with
                    | None -> None
                    | Some _ ->
                        let target_uri = uri_of_path target in
                        Option.bind (project_source_text target_uri target) (fun target_text ->
                            Option.map (location target_uri target_text)
                              (List.find_opt (fun symbol ->
                                  symbol.kind = 12 && String.equal symbol.name name)
                                (symbols target_text)))
                    end
                end
      in
      manifests (project_manifests ())

let imported_forms uri =
  let current = path_of_uri uri in
  project_manifests () |> List.concat_map (fun manifest ->
      let base = Filename.dirname manifest in
      let sources = project_symbols_document manifest in
      match List.find_opt (fun (source : project_source) ->
          String.equal (canonical_path (Filename.concat base source.path)) current) sources with
      | None -> []
      | Some source -> source.imports |> List.concat_map (fun (item : project_import) ->
          let target = canonical_path
            (Filename.concat (Filename.dirname current) item.path) in
          match List.find_opt (fun (candidate : project_source) ->
              String.equal (canonical_path (Filename.concat base candidate.path)) target) sources with
          | None -> []
          | Some target_source -> target_source.symbols
              |> List.filter (fun (symbol : compiler_symbol) ->
                  String.equal symbol.kind "form" && List.mem symbol.name target_source.exports)
              |> List.map (fun (symbol : compiler_symbol) ->
                  item.alias ^ "." ^ symbol.name, symbol.typ)))

let project_rename_imported uri text start name replacement : Yojson.Safe.t option =
  match qualified_alias text start with
  | None -> None
  | Some alias ->
      let current = path_of_uri uri in
      let rec manifests = function
        | [] -> None
        | manifest :: rest ->
            let base = Filename.dirname manifest in
            let sources = project_symbols_document manifest in
            match List.find_opt (fun (source : project_source) ->
                String.equal (canonical_path (Filename.concat base source.path)) current) sources with
            | None -> manifests rest
            | Some owner ->
                begin match List.find_opt (fun item -> String.equal item.alias alias) owner.imports with
                | None -> None
                | Some imported ->
                    let target = canonical_path (Filename.concat (Filename.dirname current) imported.path) in
                    match List.find_opt (fun (source : project_source) ->
                        String.equal (canonical_path (Filename.concat base source.path)) target
                        && List.mem name source.exports) sources with
                    | None -> None
                    | Some _ ->
                        let edits = sources |> List.filter_map (fun (source : project_source) ->
                            let path = canonical_path (Filename.concat base source.path) in
                            let item_uri = uri_of_path path in
                            match project_source_text item_uri path with
                            | None -> None
                            | Some source_text when String.equal path target ->
                                let edits : Yojson.Safe.t list = semantic_occurrences source_text name
                                  |> List.map (fun (first, last) -> text_edit source_text first last replacement) in
                                Some (item_uri, edits)
                            | Some source_text ->
                                let aliases = source.imports
                                  |> List.filter_map (fun (item : project_import) ->
                                      let imported_path = canonical_path
                                        (Filename.concat (Filename.dirname path) item.path) in
                                      if String.equal imported_path target then Some item.alias else None) in
                                let edits : Yojson.Safe.t list = aliases |> List.concat_map (fun alias ->
                                    qualified_occurrences source_text alias name
                                    |> List.map (fun (first, last) -> text_edit source_text first last replacement)) in
                                if edits = [] then None else Some (item_uri, edits)) in
                        let changes = List.map (fun (item_uri, edits) -> item_uri, `List edits) edits in
                        Some ((`Assoc [ ("changes", `Assoc changes) ]) : Yojson.Safe.t)
                end
      in
      manifests (project_manifests ())

let project_references_imported uri text start name : Yojson.Safe.t list option =
  match qualified_alias text start with
  | None -> None
  | Some alias ->
      let current = path_of_uri uri in
      let rec manifests = function
        | [] -> None
        | manifest :: rest ->
            let base = Filename.dirname manifest in
            let sources = project_symbols_document manifest in
            match List.find_opt (fun (source : project_source) ->
                String.equal (canonical_path (Filename.concat base source.path)) current) sources with
            | None -> manifests rest
            | Some owner ->
                begin match List.find_opt (fun (item : project_import) -> String.equal item.alias alias) owner.imports with
                | None -> None
                | Some imported ->
                    let target = canonical_path (Filename.concat (Filename.dirname current) imported.path) in
                    if not (List.exists (fun (source : project_source) ->
                        String.equal (canonical_path (Filename.concat base source.path)) target
                        && List.mem name source.exports) sources) then None
                    else
                      let locations : Yojson.Safe.t list = sources |> List.concat_map (fun (source : project_source) ->
                          let path = canonical_path (Filename.concat base source.path) in
                          let item_uri = uri_of_path path in
                          match project_source_text item_uri path with
                          | None -> []
                          | Some source_text when String.equal path target ->
                              semantic_occurrences source_text name |> List.map (fun (first, last) ->
                                  `Assoc [ ("uri", `String item_uri); ("range", range_from_offsets source_text first last) ])
                          | Some source_text ->
                              source.imports |> List.concat_map (fun (item : project_import) ->
                                  let imported_path = canonical_path
                                    (Filename.concat (Filename.dirname path) item.path) in
                                  if not (String.equal imported_path target) then [] else
                                  qualified_occurrences source_text item.alias name
                                  |> List.map (fun (first, last) ->
                                      `Assoc [ ("uri", `String item_uri); ("range", range_from_offsets source_text first last) ]))) in
                      Some locations
                end
      in
      manifests (project_manifests ())

let project_workspace_symbols query =
  project_manifests ()
  |> List.concat_map (fun manifest ->
      let base = Filename.dirname manifest in
      project_symbols_document manifest
      |> List.concat_map (fun (source : project_source) ->
          let full_path = Filename.concat base source.path in
          let uri = uri_of_path full_path in
          match project_source_text uri full_path with
          | None -> []
          | Some text ->
              source.symbols
              |> List.filter (fun (symbol : compiler_symbol) -> query = "" || case_contains symbol.name query)
              |> List.filter_map (fun (symbol : compiler_symbol) ->
                  Option.map (fun location ->
                    `Assoc [
                      ("name", `String symbol.name); ("kind", `Int (lsp_symbol_kind symbol.kind));
                      ("location", location);
                      ("containerName", `String source.path);
                    ]) (compiler_location uri text symbol))))

let workspace_symbols query =
  let open_symbols = open_documents ()
  |> List.concat_map (fun (uri, document) ->
      Option.value ~default:[] (Hashtbl.find_opt symbol_cache document.text)
      |> List.filter (fun (symbol : compiler_symbol) -> query = "" || case_contains symbol.name query)
      |> List.filter_map (fun (symbol : compiler_symbol) ->
          Option.map (fun location ->
            `Assoc [
              ("name", `String symbol.name); ("kind", `Int (lsp_symbol_kind symbol.kind));
              ("location", location);
              ("containerName", `String uri);
            ]) (compiler_location uri document.text symbol)))
  in
  let known_uris = open_documents () |> List.map fst in
  project_workspace_symbols query
  |> List.filter (fun item -> match Util.member "location" item with
      | `Assoc location ->
          begin match List.assoc_opt "uri" location with
          | Some (`String uri) -> not (List.mem uri known_uris)
          | _ -> true
          end
      | _ -> true)
  |> List.append open_symbols

let project_declaration_locations name =
  project_workspace_symbols name
  |> List.filter_map (fun item ->
      match Util.member "name" item, Util.member "location" item with
      | `String item_name, ((`Assoc _) as location) when String.equal item_name name -> Some location
      | _ -> None)

let signature_help document line character =
  let offset = byte_offset document.text line character in
  let rec call_open index depth =
    if index <= 0 then None else
    match document.text.[index - 1] with
    | ')' -> call_open (index - 1) (depth + 1)
    | '(' when depth = 0 -> Some (index - 1)
    | '(' -> call_open (index - 1) (depth - 1)
    | _ -> call_open (index - 1) depth
  in
  let count_active_parameter open_offset =
    let rec scan index parens brackets braces count =
      if index >= offset then count else
      match document.text.[index] with
      | '(' -> scan (index + 1) (parens + 1) brackets braces count
      | ')' when parens > 0 -> scan (index + 1) (parens - 1) brackets braces count
      | '[' -> scan (index + 1) parens (brackets + 1) braces count
      | ']' when brackets > 0 -> scan (index + 1) parens (brackets - 1) braces count
      | '{' -> scan (index + 1) parens brackets (braces + 1) count
      | '}' when braces > 0 -> scan (index + 1) parens brackets (braces - 1) count
      | ',' when parens = 0 && brackets = 0 && braces = 0 -> scan (index + 1) parens brackets braces (count + 1)
      | _ -> scan (index + 1) parens brackets braces count
    in
    scan (open_offset + 1) 0 0 0 0
  in
  match call_open offset 0 with
  | Some open_offset ->
      let rec start index = if index > 0 && is_identifier document.text.[index - 1] then start (index - 1) else index in
      let word_start = start open_offset in
      let word = if word_start < open_offset then Some (String.sub document.text word_start (open_offset - word_start)) else None in
      begin match word with
      | Some word ->
      begin match compiler_form document word with
      | Some form ->
          `Assoc [
            ("signatures", `List [ `Assoc [
              ("label", `String (Option.value ~default:(word ^ "(...) -> " ^ form.typ) form.signature));
              ("documentation", `String ("AMLC form returning " ^ form.typ));
            ] ]);
            ("activeSignature", `Int 0); ("activeParameter", `Int (count_active_parameter open_offset));
          ]
      | None -> `Null
      end
      | None -> `Null
      end
  | None -> `Null

let inlay_hints document =
  Option.value ~default:[] (Hashtbl.find_opt symbol_cache document.text)
  |> List.filter (fun (symbol : compiler_symbol) ->
      List.mem symbol.kind ["form"; "function"; "method"; "constructor"]
      && symbol.typ <> "")
  |> List.filter_map (fun (symbol : compiler_symbol) ->
      Option.map (fun end_position ->
          `Assoc [
            ("position", lsp_position document.text end_position);
            ("label", `String (": " ^ symbol.typ));
            ("kind", `Int 1); ("paddingLeft", `Bool true);
            ("tooltip", `String ("Compiler-reported return type of " ^ symbol.name));
          ]) symbol.selection_end)

let document_highlights document line character =
  match compiler_occurrence_at document line character with
  | Some (symbol, _, _, _) ->
      symbol.occurrences
      |> List.map (fun (role, start_position, end_position) ->
          `Assoc [
            ("range", `Assoc [
              ("start", lsp_position document.text start_position);
              ("end", lsp_position document.text end_position);
            ]);
            ("kind", `Int (if String.equal role "declaration" then 3 else 2));
          ])
  | None -> []

let folding_ranges text =
  let _, ranges = String.split_on_char '\n' text |> List.mapi (fun line value -> line, value)
    |> List.fold_left (fun (opens, ranges) (line, value) ->
        let balance = count_character value '{' - count_character value '}' in
        let rec close count opens ranges =
          if count = 0 then opens, ranges
          else match opens with
            | start :: rest when start < line -> close (count - 1) rest (`Assoc [ ("startLine", `Int start); ("endLine", `Int line) ] :: ranges)
            | _ -> opens, ranges
        in
        let opens, ranges = close (max 0 (-balance)) opens ranges in
        let unmatched = max 0 balance in
        let rec push count opens = if count = 0 then opens else push (count - 1) (line :: opens) in
        push unmatched opens, ranges)
      ([], [])
  in
  List.rev ranges

let selection_range text line character =
  let whole = range_from_offsets text 0 (String.length text) in
  let start = line_start text line in
  let finish = match String.index_from_opt text start '\n' with Some index -> index | None -> String.length text in
  let line_range = range_from_offsets text start finish in
  let parent = `Assoc [ ("range", line_range); ("parent", `Assoc [ ("range", whole) ]) ] in
  match word_at text line character with
  | Some (_, first, last) -> `Assoc [ ("range", range_from_offsets text first last); ("parent", parent) ]
  | None -> parent

let code_actions uri params =
  match Util.member "context" params with
  | `Assoc fields ->
      begin
        match List.assoc_opt "diagnostics" fields with
        | Some (`List (`Assoc diagnostic :: _)) ->
            begin
              match List.assoc_opt "code" diagnostic, List.assoc_opt "range" diagnostic with
              | Some (`String code), Some range ->
                  let action title replacement =
                    `Assoc [
                      ("title", `String title);
                      ("kind", `String "quickfix");
                      ("isPreferred", `Bool false);
                      ("edit", `Assoc [
                        ("changes", `Assoc [
                          (uri, `List [ `Assoc [
                            ("range", range);
                            ("newText", `String replacement);
                          ] ]);
                        ]);
                      ]);
                    ]
                  in
                  let actions = match code with
                    | "AMLC101" -> [ action "Insert missing ')'" ")" ]
                    | "AMLC102" -> [ action "Insert missing '}'" "}" ]
                    | "AMLC103" -> [ action "Insert missing ']'" "]" ]
                    | "AMLC104" -> [ action "Insert missing ','" "," ]
                    | "AMLC105" -> [ action "Insert missing 'in'" "in " ]
                    | "AMLC106" -> [ action "Insert missing 'then'" "then " ]
                    | "AMLC107" -> [ action "Insert missing 'else'" "else " ]
                    | "AMLC108" -> [ action "Insert missing ':'" ": " ]
                    | "AMLC100" -> [ action "Insert unit expression" "unit " ]
                    | "REHOVOT101" -> [ action "Insert missing ':'" ": " ]
                    | "REHOVOT102" -> [ action "Insert missing '}'" "}" ]
                    | "REHOVOT103" -> [ action "Insert missing ')'" ")" ]
                    | "REHOVOT104" -> [ action "Insert missing ']'" "]" ]
                    | "REHOVOT105" -> [ action "Insert missing ','" "," ]
                    | "REHOVOT001" -> [ action "Use canonical 'contract'" "contract" ]
                    | "REHOVOT002" -> [ action "Use canonical 'program'" "program" ]
                    | _ -> []
                  in
                  `List actions
              | _ -> `List []
            end
        | _ -> `List []
      end
  | _ -> `List []

let request_result method_name params =
  let document = Option.bind (uri_from_params params) (fun uri ->
      Option.map (fun document -> uri, document) (Hashtbl.find_opt documents uri)) in
  match method_name, document with
  | "textDocument/diagnostic", Some (_uri, document) ->
      let diagnostics = Option.value ~default:[] (Hashtbl.find_opt diagnostic_cache document.text) in
      `Assoc [ ("kind", `String "full"); ("items", `List (List.map (diagnostic document.text) diagnostics)) ]
  | "workspace/symbol", _ ->
      `List (workspace_symbols (Option.value ~default:"" (string_member "query" params)))
  | "textDocument/hover", Some (_uri, document) ->
      begin
        match position_from_params params with
        | Some (line, character) ->
            begin
              match word_at document.text line character with
              | Some (word, _, _) ->
                  begin match List.find_opt (fun (symbol : compiler_symbol) -> String.equal symbol.name word)
                    (Option.value ~default:[] (Hashtbl.find_opt symbol_cache document.text)) with
                  | Some symbol ->
                      let typ = Option.value ~default:symbol.typ symbol.signature in
                      `Assoc [ ("contents", `Assoc [ ("kind", `String "markdown");
                        ("value", `String ("`" ^ word ^ "` : `" ^ typ ^ "`\\n\\nAMLC " ^ symbol.kind)) ]) ]
                  | None -> `Null
                  end
              | None -> `Null
            end
        | None -> `Null
      end
  | ("textDocument/definition" | "textDocument/declaration"), Some (uri, document) ->
      begin
        match position_from_params params with
        | Some (line, character) ->
            begin
              match word_at document.text line character with
              | Some (word, _, _) ->
                  Option.value ~default:(`List [])
                    (Option.map (fun location -> `List [ location ])
                      (Option.bind
                        (List.find_opt (fun (symbol : compiler_symbol) ->
                           String.equal symbol.name word)
                          (Option.value ~default:[] (Hashtbl.find_opt symbol_cache document.text)))
                        (compiler_location uri document.text)))
              | None -> `List []
            end
        | None -> `List []
      end
  | "textDocument/completion", Some _ ->
      let compiler_items =
        Option.value ~default:[] (Option.map (fun (_uri, document) ->
          Option.value ~default:[] (Hashtbl.find_opt symbol_cache document.text)) document)
        |> List.map symbol_completion_item
      in
      let keywords = match document with
        | None -> legacy_completion_keywords
        | Some (_uri, document) -> completion_keywords_for document.text
      in
      `Assoc [
        ("isIncomplete", `Bool false);
        ("items", `List (List.map completion_item keywords @ compiler_items));
      ]
  | "textDocument/documentSymbol", Some (_uri, document) ->
      `List (Option.value ~default:[] (Hashtbl.find_opt symbol_cache document.text)
        |> List.filter_map (fun (symbol : compiler_symbol) ->
            match symbol.selection_start, symbol.selection_end with
            | Some start_position, Some end_position ->
                Some (`Assoc [
                  ("name", `String symbol.name); ("kind", `Int (lsp_symbol_kind symbol.kind));
                  ("range", `Assoc [
                    ("start", lsp_position document.text start_position);
                    ("end", lsp_position document.text end_position);
                  ]);
                  ("selectionRange", `Assoc [
                    ("start", lsp_position document.text start_position);
                    ("end", lsp_position document.text end_position);
                  ]);
                ])
            | _ -> None))
  | "textDocument/references", Some (uri, document) ->
      begin
        match position_from_params params with
        | Some (line, character) ->
            begin match compiler_occurrence_at document line character with
            | Some (symbol, _, _, _) ->
                let include_declaration =
                  match object_member "context" params with
                  | Some context -> (match Util.member "includeDeclaration" context with `Bool value -> value | _ -> false)
                  | None -> false
                in
                `List (compiler_occurrence_locations ~include_declaration uri document.text symbol)
            | None -> `List []
            end
        | None -> `List []
      end
  | "textDocument/prepareRename", Some (_uri, document) ->
      begin match position_from_params params with
      | Some (line, character) ->
          begin match compiler_occurrence_at document line character with
          | Some (symbol, _, start_position, end_position) ->
              `Assoc [
                ("range", `Assoc [
                  ("start", lsp_position document.text start_position);
                  ("end", lsp_position document.text end_position);
                ]);
                ("placeholder", `String symbol.name);
              ]
          | None -> `Null
          end
      | None -> `Null
      end
  | "textDocument/rename", Some (uri, document) ->
      begin
        match position_from_params params, string_member "newName" params with
        | Some (line, character), Some replacement ->
            begin
              match compiler_occurrence_at document line character with
              | Some (symbol, _, _, _) when valid_identifier replacement ->
                  let symbols = Option.value ~default:[] (Hashtbl.find_opt symbol_cache document.text) in
                  if not (List.exists (fun (other : compiler_symbol) ->
                      String.equal other.name replacement && other.id <> symbol.id) symbols)
                  then `Assoc [ ("changes", `Assoc [
                        (uri, `List (compiler_occurrence_edits document.text replacement symbol));
                      ]) ]
                  else `Null
              | _ -> `Null
            end
        | _ -> `Null
      end
  | "textDocument/codeAction", Some (_uri, _document) ->
      code_actions (Option.value ~default:"" (uri_from_params params)) params
  | "textDocument/signatureHelp", Some (_uri, document) ->
      begin match position_from_params params with
      | Some (line, character) -> signature_help document line character
      | None -> `Null
      end
  | "textDocument/inlayHint", Some (_uri, document) -> `List (inlay_hints document)
  | "textDocument/documentHighlight", Some (_uri, document) ->
      begin match position_from_params params with
      | Some (line, character) -> `List (document_highlights document line character)
      | None -> `List []
      end
  | "textDocument/foldingRange", Some (_uri, document) -> `List (folding_ranges document.text)
  | "textDocument/selectionRange", Some (_uri, document) ->
      begin match Util.member "positions" params with
      | `List positions -> `List (List.filter_map (fun position ->
          Option.bind (int_member "line" position) (fun line ->
              Option.map (fun character -> selection_range document.text line character) (int_member "character" position))) positions)
      | _ -> `List []
      end
  | "textDocument/formatting", Some (uri, document) ->
      if has_multiline_sensitive_lexeme document.text then `List [] else
      let formatted = format_document document.text in
      if String.equal formatted document.text
          || not (compiler_accepts ~path:(path_of_uri uri) formatted) then `List []
      else `List [ text_edit document.text 0 (String.length document.text) formatted ]
  | "textDocument/semanticTokens/full", Some (_uri, document) ->
      semantic_tokens document.text
        (Option.value ~default:[] (Hashtbl.find_opt symbol_cache document.text))
        (Option.value ~default:[] (Hashtbl.find_opt semantic_token_cache document.text))
  | "textDocument/diagnostic", None -> `Assoc [ ("kind", `String "full"); ("items", `List []) ]
  | "textDocument/hover", None -> `Null
  | "textDocument/definition", None | "textDocument/declaration", None | "textDocument/documentSymbol", None
  | "textDocument/references", None | "textDocument/codeAction", None | "textDocument/formatting", None
  | "textDocument/inlayHint", None | "textDocument/documentHighlight", None | "textDocument/foldingRange", None
  | "textDocument/selectionRange", None -> `List []
  | "textDocument/completion", None -> `Assoc [ ("isIncomplete", `Bool false); ("items", `List []) ]
  | "textDocument/semanticTokens/full", None -> `Assoc [ ("data", `List []) ]
  | "textDocument/rename", None | "textDocument/prepareRename", None | "textDocument/signatureHelp", None -> `Null
  | _ -> `Null

let document_from_params params =
  match object_member "textDocument" params with
  | Some document -> Option.bind (string_member "uri" document) (fun uri ->
      Option.map (fun text -> (uri, { text; version = int_member "version" document })) (string_member "text" document))
  | None -> None

let changed_document params =
  match object_member "textDocument" params with
  | Some document -> Option.bind (string_member "uri" document) (fun uri ->
      match Util.member "contentChanges" params with
      | `List changes ->
          begin match Hashtbl.find_opt documents uri with
          | None -> None
          | Some current ->
              let apply text change =
                match string_member "text" change with
                | None -> None
                | Some replacement ->
                    begin match object_member "range" change with
                    | None -> Some replacement
                    | Some range ->
                        begin match object_member "start" range, object_member "end" range with
                        | Some start_position, Some end_position ->
                            begin match int_member "line" start_position, int_member "character" start_position,
                                int_member "line" end_position, int_member "character" end_position with
                            | Some start_line, Some start_character, Some end_line, Some end_character ->
                                let first = byte_offset text start_line start_character in
                                let last = byte_offset text end_line end_character in
                                if last < first then None
                                else Some (String.sub text 0 first ^ replacement ^ String.sub text last (String.length text - last))
                            | _ -> None
                            end
                        | _ -> None
                        end
                    end
              in
              Option.map (fun text -> uri, { text; version = int_member "version" document })
                (List.fold_left (fun text change -> Option.bind text (fun value -> apply value change)) (Some current.text) changes)
          end
      | _ -> None)
  | None -> None

let handle_notification output method_name params =
  let open_document document = match document with
    | Some (uri, document) ->
        Hashtbl.replace documents uri document;
        Hashtbl.remove pending_checks uri;
        schedule_diagnostics uri document
    | None -> Jsonrpc.log ("ignored malformed " ^ method_name ^ " notification")
  in
  let change_document document = match document with
    | Some (uri, document) ->
        let unchanged = match Hashtbl.find_opt documents uri with Some previous -> String.equal previous.text document.text | None -> false in
        Hashtbl.replace documents uri document;
        if not unchanged then begin
          Hashtbl.reset project_symbol_cache;
          schedule_diagnostics uri document
        end
    | None -> Jsonrpc.log ("ignored malformed " ^ method_name ^ " notification")
  in
  let apply_dialect_settings settings =
    let configured =
      match string_member "dialect" settings with
      | Some value -> Some value
      | None -> Option.bind (object_member "amlcLsp" settings) (string_member "dialect")
    in
    Option.iter (fun value ->
        set_dialect_override (dialect_of_string (String.lowercase_ascii value));
        Hashtbl.iter (fun uri document -> schedule_diagnostics uri document) documents) configured
  in
  match method_name with
  | "textDocument/didOpen" -> open_document (document_from_params params)
  | "textDocument/didChange" -> change_document (changed_document params)
  | "textDocument/didSave" -> (match Option.bind (object_member "textDocument" params) (string_member "uri") with
      | Some uri ->
          Hashtbl.reset project_symbol_cache;
          begin match Hashtbl.find_opt documents uri with
          | Some document -> schedule_diagnostics uri document
          | None -> ()
          end
      | None -> Jsonrpc.log "ignored malformed textDocument/didSave notification")
  | "textDocument/didClose" -> (match Option.bind (object_member "textDocument" params) (string_member "uri") with
      | Some uri ->
          Hashtbl.remove documents uri;
          Hashtbl.remove pending_checks uri;
          cancel_diagnostic_job uri;
          publish output uri []
      | None -> Jsonrpc.log "ignored malformed textDocument/didClose notification")
  | "workspace/didChangeWorkspaceFolders" -> apply_workspace_folder_change params
  | "workspace/didChangeConfiguration" ->
      Option.iter apply_dialect_settings (object_member "settings" params)
  | "exit" -> raise Exit
  | _ -> ()

let handle_message output message =
  let method_name = string_member "method" message in
  let params = Util.member "params" message in
  let id = Util.member "id" message in
  match (method_name, id) with
  | Some "initialize", id when id <> `Null && not !initialized ->
      workspace_roots := workspace_roots_from_params params;
      Option.iter (fun options ->
          Option.iter (fun value -> set_dialect_override (dialect_of_string (String.lowercase_ascii value)))
            (string_member "dialect" options))
        (object_member "initializationOptions" params);
      initialized := true;
      Jsonrpc.write output (response id initialize_result)
  | Some "initialize", id when id <> `Null -> Jsonrpc.write output (error_response id (-32600) "server already initialized")
  | Some "shutdown", id when id <> `Null && !initialized -> shutting_down := true; Jsonrpc.write output (response id `Null)
  | Some "shutdown", id when id <> `Null -> Jsonrpc.write output (error_response id (-32002) "server is not initialized")
  | Some method_name, `Null when !initialized && not !shutting_down -> handle_notification output method_name params
  | Some method_name, id when id <> `Null && !initialized && not !shutting_down ->
      begin
        match method_name with
        | "textDocument/completion" | "textDocument/documentSymbol" | "textDocument/hover"
        | "textDocument/diagnostic"
        | "textDocument/signatureHelp" | "textDocument/definition"
        | "textDocument/declaration" | "textDocument/references"
        | "textDocument/prepareRename" | "textDocument/rename"
        | "textDocument/codeAction" | "textDocument/inlayHint"
        | "textDocument/documentHighlight" | "textDocument/foldingRange"
        | "textDocument/selectionRange" | "textDocument/formatting"
        | "textDocument/semanticTokens/full" | "workspace/symbol" ->
            Jsonrpc.write output (response id (request_result method_name params))
        | _ -> Jsonrpc.write output (error_response id (-32601) ("unsupported method: " ^ method_name))
      end
  | Some _, `Null -> ()
  | Some method_name, id -> Jsonrpc.write output (error_response id (-32601) ("unsupported method: " ^ method_name))
  | None, _ -> Jsonrpc.log "ignored message without a method"

let run () =
  try
    while true do
      let stdin_fd = Unix.descr_of_in_channel stdin in
      let job_fds = Hashtbl.to_seq_values diagnostic_jobs |> List.of_seq
        |> List.filter (fun job -> not job.eof)
        |> List.map (fun job -> job.output) in
      let readable, _, _ = Unix.select (stdin_fd :: job_fds) [] [] (next_check_timeout ()) in
      if List.mem stdin_fd readable then (
        match Jsonrpc.read stdin with
        | Some message -> (try handle_message stdout message with error -> Jsonrpc.log (Printexc.to_string error))
        | None -> raise Exit);
      poll_diagnostic_jobs stdout readable;
      flush_due_diagnostics stdout
    done
  with Exit ->
    Hashtbl.to_seq_keys diagnostic_jobs |> List.of_seq |> List.iter cancel_diagnostic_job
