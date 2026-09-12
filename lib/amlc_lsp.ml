open Yojson.Safe

module Jsonrpc = struct
  let log message = prerr_endline ("amlc-lsp: " ^ message)

  let content_length header =
    match String.split_on_char ':' header with
    | name :: value :: _ when String.lowercase_ascii (String.trim name) = "content-length" ->
        (try Some (int_of_string (String.trim value)) with Failure _ -> None)
    | _ -> None

  let read_headers read_line =
    let rec loop length =
      match read_line () with
      | exception End_of_file -> None
      | "\r" | "" -> Some length
      | header ->
          let next = match content_length header with Some value -> Some value | None -> length in
          loop next
    in
    loop None

  let read_frame read_line read_exact =
    match read_headers read_line with
    | None -> None
    | Some None -> failwith "message is missing Content-Length"
    | Some (Some length) when length < 0 -> failwith "message has a negative Content-Length"
    | Some (Some length) -> Some (from_string (read_exact length))

  let read input = read_frame (fun () -> input_line input) (really_input_string input)

  let read_fd input =
    (* Do not read ahead: select observes the descriptor, not OCaml's channel
       buffer. Prefetching a second frame can leave it waiting indefinitely. *)
    let read_exact length =
      let bytes = Bytes.create length in
      let rec fill offset =
        if offset < length then
          match Unix.read input bytes offset (length - offset) with
          | 0 -> raise End_of_file
          | count -> fill (offset + count)
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill offset in
      fill 0; Bytes.to_string bytes in
    let read_line () =
      let line = Buffer.create 64 in
      let rec loop () = match read_exact 1 with
        | "\n" -> Buffer.contents line
        | byte -> Buffer.add_string line byte; loop () in
      loop () in
    read_frame read_line read_exact

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

type document = { uri : string; text : string; version : int option }

(* Analysis depends on the source directory (relative imports), not just bytes.
   Dialect changes clear analysis caches before rescheduling analysis. *)
type analysis_key = string * string
let document_key document = document.uri, document.text
type diagnostic_job = {
  pid : int;
  temporary_files : (string * string) option;
  document : document;
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
  completion_scopes : (position * position) list;
  occurrences : (string * position * position) list;
}
type compiler_semantic_token = {
  token_type : string;
  token_start : position;
  token_end : position;
}
type compiler_member_site = { member_start : position; member_end : position; member_items : Yojson.Safe.t list }
type compiler_signature_site = { signature_start : position; signature_end : position; signature_help : Yojson.Safe.t }
type document_analysis = {
  diagnostics : compiler_diagnostic list;
  symbols : compiler_symbol list;
  semantic_tokens : compiler_semantic_token list;
  members : compiler_member_site list;
  signatures : compiler_signature_site list;
  formatting : (int * int * int) list option;
  dependencies : string list option;
}

(* The official launcher supplies an in-process analyzer before initialization.
   It still runs in the existing bounded worker, never in the transport loop. *)
let library_analyzer : (string -> string -> document_analysis) option ref = ref None
let library_workspace_analyzer :
  (string -> string list -> (string * string) list -> string -> string -> int -> string option -> Yojson.Safe.t) option ref = ref None
type project_import = { path : string; alias : string }
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
let worker_temporary_files : (string * string) option ref = ref None
let diagnostic_cache : (analysis_key, compiler_diagnostic list) Hashtbl.t = Hashtbl.create 32
let symbol_cache : (analysis_key, compiler_symbol list) Hashtbl.t = Hashtbl.create 32
let semantic_token_cache : (analysis_key, compiler_semantic_token list) Hashtbl.t = Hashtbl.create 32
let member_cache : (analysis_key, compiler_member_site list) Hashtbl.t = Hashtbl.create 32
let signature_cache : (analysis_key, compiler_signature_site list) Hashtbl.t = Hashtbl.create 32
let formatting_cache : (analysis_key, (int * int * int) list option) Hashtbl.t = Hashtbl.create 32
let project_symbol_cache : (string, project_index) Hashtbl.t = Hashtbl.create 8
let document_dependencies : (string, string list option) Hashtbl.t = Hashtbl.create 32
let workspace_roots : string list ref = ref []
let supports_document_changes = ref false
let debounce_seconds = 0.2
let max_document_bytes = 1_000_000
let compiler_timeout_seconds = 5.
let analysis_timeout_seconds = (2. *. compiler_timeout_seconds) +. 0.5
type dialect = Legacy_amlc | Appliedml
type editor_request = {
  request_id : Yojson.Safe.t; method_name : string; params : Yojson.Safe.t;
  snapshot : document; dialect : dialect option; deadline : float;
}
let editor_requests : editor_request list ref = ref []
(* Do not answer an analysis-backed request with an empty fallback while its
   worker is still within the server's own deadline. *)
let editor_wait_seconds = analysis_timeout_seconds
let max_editor_requests = 64
let max_compiler_output_bytes = 4_000_000

exception Compiler_timeout of string
exception Compiler_output_limit of string

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()
let max_cached_documents = 64
let analysis_recency : analysis_key list ref = ref []

let forget_analysis key =
  Hashtbl.remove diagnostic_cache key;
  Hashtbl.remove symbol_cache key;
  Hashtbl.remove semantic_token_cache key;
  Hashtbl.remove member_cache key;
  Hashtbl.remove signature_cache key;
  Hashtbl.remove formatting_cache key;
  analysis_recency := List.filter ((<>) key) !analysis_recency

let remember_analysis key =
  analysis_recency := List.filter ((<>) key) !analysis_recency;
  (* Evict one oldest snapshot across all feature caches. Clearing a full cache
     erased unrelated fresh analysis when another worker finished afterwards. *)
  if List.length !analysis_recency >= max_cached_documents then
    Option.iter forget_analysis (List.nth_opt !analysis_recency (max_cached_documents - 1));
  analysis_recency := key :: !analysis_recency

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
  if contains message "expected = ) actual =" || starts_with "expected )," message then "AMLC101"
  else if contains message "expected = } actual =" || starts_with "expected }," message then "AMLC102"
  else if contains message "expected = ] actual =" || starts_with "expected ]," message then "AMLC103"
  else if contains message "expected = , actual =" || starts_with "expected ,," message then "AMLC104"
  else if contains message "expected = in actual =" || starts_with "expected in," message then "AMLC105"
  else if contains message "expected = then actual =" || starts_with "expected then," message then "AMLC106"
  else if contains message "expected = else actual =" || starts_with "expected else," message then "AMLC107"
  else if contains message "expected = : actual =" || starts_with "expected :," message then "AMLC108"
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

(* LSP columns count UTF-16 code units; compiler offsets count UTF-8 bytes.
   Keep conversion at range/edit boundaries, never use columns as byte indices. *)
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

let valid_identifier name =
  String.length name > 0
  && (match name.[0] with 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false)
  && String.for_all (function
       | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
       | _ -> false) name

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

let installed_checker name =
  let executable = if Filename.is_implicit Sys.executable_name then
      executable_in_path Sys.executable_name else Sys.executable_name in
  (* Some launchers expose the server through a bin-directory symlink. *)
  let executable = try Unix.realpath executable with Unix.Unix_error _ -> executable in
  let bundled = Filename.concat (Filename.dirname executable)
      ("../lib/amlc-lsp/" ^ name) in
  try Unix.access bundled [Unix.X_OK]; bundled
  with Unix.Unix_error _ -> executable_in_path name

let compiler_command () =
  match Sys.getenv_opt "AMLC" with
  | Some command when command <> "" -> command
  | _ -> installed_checker "amlc"

let rehovot_command () =
  match Sys.getenv_opt "REHOVOT_CHECK" with
  | Some command when command <> "" -> command
  | _ -> installed_checker "rehovot-check"

let dialect_override : dialect option ref = ref None

let dialect_of_string = function
  | "legacy" | "legacy-amlc" -> Some Legacy_amlc
  | "appliedml" | "applied" -> Some Appliedml
  | "auto" -> None
  | _ -> None

let set_dialect_override value =
  dialect_override := value;
  analysis_recency := [];
  Hashtbl.reset diagnostic_cache;
  Hashtbl.reset symbol_cache;
  Hashtbl.reset semantic_token_cache;
  Hashtbl.reset member_cache;
  Hashtbl.reset signature_cache;
  Hashtbl.reset formatting_cache;
  Hashtbl.reset document_dependencies;
  Hashtbl.reset project_symbol_cache

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

(* [program] and [form] are shared by the calculation-oriented AMLC language
   and the callable Program syntax parsed by Rehovot.  Top-level calculation
   declarations select AMLC; other Program declarations select Rehovot.  A
   form-only AMLC source can force that route with [dialect = legacy]. *)
let document_dialect text =
  match !dialect_override with
  | Some dialect -> dialect
  | None ->
      let code = source_code_mask text in
      if has_line_start code ["term "; "input "; "permit "; "size ";
                              "measure "; "law "; "data "; "shape "]
      then Legacy_amlc
      else if has_line_start code ["contract "; "Contract "; "program "; "Program ";
                                   "interface "] then Appliedml
      else Legacy_amlc

(* The legacy profile routes contract files through the pinned Rehovot parser
   instead of its patched preview AMLC, whose grammar rejects [self.field]. *)
let is_appliedml_contract text = document_dialect text = Appliedml

let checker_name text =
  if Option.is_some !library_analyzer then "amlc.vm"
  else if is_appliedml_contract text then "rehovot-check" else "amlc"

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

let canonical_document_path uri =
  let path = File_uri.to_path uri in
  try Unix.realpath path with Unix.Unix_error _ ->
    Filename.concat (Unix.realpath (Filename.dirname path)) (Filename.basename path)

let remove_temporary_file file =
  try Sys.remove file with Sys_error _ -> ()

let remove_worker_files (source, overlays) =
  remove_temporary_file source;
  remove_temporary_file overlays

let with_analysis_file ?temp_dir ?(overlay = false) prefix suffix run =
  match !worker_temporary_files with
  | Some (source, overlays) -> run (if overlay then overlays else source)
  | None ->
      let file = Filename.temp_file ?temp_dir prefix suffix in
      Fun.protect ~finally:(fun () -> remove_temporary_file file) (fun () -> run file)

let with_document_overlays run =
  let overlays = Hashtbl.fold (fun uri target overlays ->
    try (canonical_document_path uri, `String target.text) :: overlays
    with Unix.Unix_error _ | Invalid_argument _ -> overlays) documents [] in
  if overlays = [] then run [] else
  with_analysis_file ~overlay:true ".amlc-lsp-overlays-" ".json" (fun file ->
    Yojson.Safe.to_file file (`Assoc overlays);
    run ["--overlays=json"; file])

let check_document ?path text =
  (* Keep the temporary source beside the real document when possible.  Rehovot
     imports are relative to their importing file, so /tmp would make an
     otherwise valid [import X from "./x.aml"] look unrelated to its module. *)
  with_analysis_file ?temp_dir:(Option.map Filename.dirname path) ".amlc-lsp-" ".aml" (fun file ->
      let channel = open_out_bin file in
      Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () -> output_string channel text; close_out channel);
      let compiler = if is_appliedml_contract text then rehovot_command () else compiler_command () in
      let run options = read_process compiler ([ "check"; file; "--diagnostics=json" ] @ options) in
      if is_appliedml_contract text then with_document_overlays run else run [])

let position_of_json json =
  match (int_member "line" json, int_member "column" json) with
  | Some line, Some column when line > 0 && column > 0 ->
      Some { line = line - 1; character = column - 1; offset = int_member "offset" json }
  | _ -> None

let open_document_at_path path =
  Hashtbl.fold (fun uri document found ->
    match found with Some _ -> found | None ->
      try if canonical_document_path uri = path then Some (uri, document) else None
      with Unix.Unix_error _ | Invalid_argument _ -> None) documents None

let compiler_editor_query ?replacement document flag offset =
  if Option.is_some !library_analyzer || not (is_appliedml_contract document.text)
      || String.length document.text > max_document_bytes then `Null else
  try
    let path = File_uri.to_path document.uri in
    let file = Filename.temp_file ~temp_dir:(Filename.dirname path) ".amlc-lsp-completion-" ".aml" in
    Fun.protect ~finally:(fun () -> Sys.remove file) (fun () ->
      Out_channel.with_open_bin file (fun output -> output_string output document.text);
      let run options =
        let options = (match replacement with Some name -> ["--new-name"; name] | None -> []) @ options in
        let options = if flag = "--references=json" || flag = "--rename=json" then
          let roots = List.filter_map (fun uri ->
            try Some (`String (canonical_document_path uri))
            with Unix.Unix_error _ | Invalid_argument _ -> None) !workspace_roots in
          ["--source-path"; canonical_document_path document.uri;
           "--workspace-roots=json"; Yojson.Safe.to_string (`List roots)] @ options else options in
        match read_process (rehovot_command ()) (["check"; file; flag; string_of_int offset] @ options) with
        | Unix.WEXITED 0, output -> from_string output
        | _ -> `Null in
      with_document_overlays run)
  with Compiler_timeout _ | Compiler_output_limit _ | Unix.Unix_error _
     | Sys_error _ | Yojson.Json_error _ | Invalid_argument _ -> `Null

let compiler_completions document offset =
  match compiler_editor_query document "--completion=json" offset with
  | `Assoc fields ->
      (match List.assoc_opt "items" fields with Some (`List items) -> items | _ -> []),
      List.assoc_opt "suppressFallback" fields = Some (`Bool true)
  | _ -> [], false

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
        selection_start; selection_end; completion_scopes = []; occurrences;
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
  with_analysis_file ?temp_dir:(Option.map Filename.dirname path) ".amlc-lsp-symbols-" ".aml" (fun file ->
      let channel = open_out_bin file in
      Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
          output_string channel text;
          close_out channel);
      let compiler = if is_appliedml_contract text then rehovot_command () else compiler_command () in
      let run options = read_process compiler (["check"; file;
        (if is_appliedml_contract text then "--analysis-metadata=json" else "--symbols=json")] @ options) in
      match (if is_appliedml_contract text then with_document_overlays run else run []) with
      | Unix.WEXITED 0, output ->
          begin
            try
              match from_string output with
              | `List values -> List.filter_map symbol_of_json values, [], None
              | `Assoc fields ->
                  let symbols = match List.assoc_opt "symbols" fields with
                    | Some (`List values) -> List.filter_map symbol_of_json values | _ -> [] in
                  let semantic_tokens = match List.assoc_opt "semanticTokens" fields with
                    | Some (`List values) -> List.filter_map semantic_token_of_json values | _ -> [] in
                  let dependencies = match List.assoc_opt "dependencies" fields with
                    | Some json when Util.member "complete" json = `Bool true ->
                        (match Util.member "paths" json with
                         | `List paths when List.for_all (function `String _ -> true | _ -> false) paths ->
                             Some (List.map Util.to_string paths)
                         | _ -> None)
                    | _ -> None in
                  symbols, semantic_tokens, dependencies
              | _ -> [], [], None
            with Yojson.Json_error _ -> [], [], None
          end
      | _ -> [], [], None)

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
  canonical_path (File_uri.to_path uri)

let uri_of_path path = File_uri.of_path (canonical_path path)

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

let publish output uri ?version diagnostics =
  let params = [ ("uri", `String uri) ]
    @ Option.to_list (Option.map (fun value -> "version", `Int value) version)
    @ [ ("diagnostics", `List diagnostics) ] in
  Jsonrpc.write output (`Assoc [
    ("jsonrpc", `String "2.0"); ("method", `String "textDocument/publishDiagnostics");
    ("params", `Assoc params);
  ])

let diagnostics_for_text uri text =
  if String.length text > max_document_bytes then [too_large_diagnostic text]
  else
    match Hashtbl.find_opt diagnostic_cache (uri, text) with
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
        remember_analysis (uri, text);
        Hashtbl.replace diagnostic_cache (uri, text) diagnostics;
        diagnostics

let analyze_document uri text =
  match !library_analyzer with
  | Some analyze -> analyze uri text
  | None ->
  let diagnostics = diagnostics_for_text uri text in
  let symbols, semantic_tokens, dependencies =
    if String.length text > max_document_bytes then [], [], None
    else if not (is_appliedml_contract text) && List.exists (fun diagnostic -> diagnostic.severity = 1) diagnostics then [], [], None
    else
      try compiler_metadata_for_text ~path:(path_of_uri uri) text with
      | Compiler_timeout _ | Compiler_output_limit _ | Unix.Unix_error _ | Sys_error _ -> [], [], None
  in
  { diagnostics; symbols; semantic_tokens; members = []; signatures = []; formatting = None; dependencies }

let publish_diagnostics output document diagnostics =
  publish output document.uri ?version:document.version
    (List.map (diagnostic document.text) diagnostics)

let close_job_output job =
  (* EOF may precede process exit. Once closed, this descriptor number can
     belong to another worker before finish, cancellation or timeout runs. *)
  if not job.eof then begin
    close_noerr job.output;
    job.eof <- true
  end

let cancel_diagnostic_job uri =
  match Hashtbl.find_opt diagnostic_jobs uri with
  | None -> ()
  | Some job ->
      Hashtbl.remove diagnostic_jobs uri;
      close_job_output job;
      (try terminate_process_group job.pid with Unix.Unix_error _ -> ());
      Option.iter remove_worker_files job.temporary_files

let start_diagnostic_job uri document =
  cancel_diagnostic_job uri;
  (* Allocate before forking: cancellation can kill the child's finally blocks,
     so the parent must own every analysis file and remove it after reaping. *)
  let temporary_files = if Option.is_some !library_analyzer then None else
    let source = Filename.temp_file ~temp_dir:(Filename.dirname (File_uri.to_path uri)) ".amlc-lsp-" ".aml" in
    let overlays = try Filename.temp_file ".amlc-lsp-overlays-" ".json"
      with error -> remove_temporary_file source; raise error in
    Some (source, overlays) in
  let read_fd, write_fd = try Unix.pipe () with error ->
    Option.iter remove_worker_files temporary_files; raise error in
  match Unix.fork () with
  | exception error ->
      close_noerr read_fd; close_noerr write_fd;
      Option.iter remove_worker_files temporary_files;
      raise error
  | 0 ->
      worker_temporary_files := temporary_files;
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
        pid; temporary_files; document; output = read_fd; buffer = Buffer.create 512; started_at = Unix.gettimeofday ();
        eof = false; status = None;
      }

let collect_job_output job =
  let bytes = Bytes.create 8192 in
  let count = Unix.read job.output bytes 0 (Bytes.length bytes) in
  if count = 0 || Buffer.length job.buffer + count > max_compiler_output_bytes + 65_536 then
    close_job_output job
  else Buffer.add_subbytes job.buffer bytes 0 count

let publish_analysis_result output uri document result =
  (* The result belongs to an analysis snapshot, never the latest buffer. *)
  match Hashtbl.find_opt documents uri with
  | Some current when current.text = document.text ->
      remember_analysis (document_key document);
      let diagnostics =
          match result with
          | Ok (analysis : document_analysis) ->
              Hashtbl.replace document_dependencies uri analysis.dependencies;
              Hashtbl.replace symbol_cache (document_key document) analysis.symbols;
              Hashtbl.replace semantic_token_cache (document_key document) analysis.semantic_tokens;
              Hashtbl.replace member_cache (document_key document) analysis.members;
              Hashtbl.replace signature_cache (document_key document) analysis.signatures;
              Hashtbl.replace formatting_cache (document_key document) analysis.formatting;
              analysis.diagnostics
          | Error message -> [compiler_fallback ("diagnostic analysis failed: " ^ message)]
      in
      (* Process workers cannot update the parent's caches. Publish and pull
         must share the result committed here. *)
      Hashtbl.replace diagnostic_cache (document_key document) diagnostics;
      publish_diagnostics output current diagnostics
  | _ -> ()

let finish_diagnostic_job output uri job =
  let document = job.document in
  Hashtbl.remove diagnostic_jobs uri;
  close_job_output job;
  Option.iter remove_worker_files job.temporary_files;
  let result =
    try
      (Marshal.from_bytes (Bytes.of_string (Buffer.contents job.buffer)) 0 :
        (document_analysis, string) result)
    with Failure _ | Invalid_argument _ ->
      Error "diagnostic worker returned invalid output"
  in
  publish_analysis_result output uri document result

let poll_diagnostic_jobs output readable =
  let now = Unix.gettimeofday () in
  Hashtbl.to_seq diagnostic_jobs |> List.of_seq |> List.iter (fun (uri, job) ->
      if now -. job.started_at >= analysis_timeout_seconds then begin
        Hashtbl.remove diagnostic_jobs uri;
        close_job_output job;
        (try terminate_process_group job.pid with Unix.Unix_error _ -> ());
        Option.iter remove_worker_files job.temporary_files;
        match Hashtbl.find_opt documents uri with
        | Some document ->
            publish_diagnostics output document
              [compiler_fallback
                ~code:(if Option.is_none !library_analyzer && is_appliedml_contract document.text
                  then "REHOVOT902" else "AMLC902")
                "compiler worker exceeded the analysis timeout"]
        | None -> ()
      end else begin
        if List.mem job.output readable && not job.eof then collect_job_output job;
        if job.status = None then begin
          match Unix.waitpid [Unix.WNOHANG] job.pid with
          | 0, _ -> ()
          | _, status -> job.status <- Some status
        end;
        if job.eof && Option.is_some job.status then
          match Hashtbl.find_opt documents uri with
          | Some _ -> finish_diagnostic_job output uri job
          | None ->
              Hashtbl.remove diagnostic_jobs uri;
              Option.iter remove_worker_files job.temporary_files
      end)

let schedule_diagnostics uri document =
  cancel_diagnostic_job uri;
  Hashtbl.replace pending_checks uri (document, Unix.gettimeofday () +. debounce_seconds)

let refresh_open_diagnostics ?changed () =
  let changed_path = Option.bind changed (fun uri ->
    try Some (canonical_document_path uri) with Unix.Unix_error _ | Invalid_argument _ -> None) in
  let affected = Hashtbl.to_seq documents |> List.of_seq |> List.filter (fun (uri, _) ->
    Some uri = changed || match changed_path, Hashtbl.find_opt document_dependencies uri with
    | Some path, Some (Some dependencies) -> List.mem path dependencies
    | _ -> true) in
  (* Use compiler-provided transitive edges; unknown/incomplete graphs stay
     conservative. Invalidate them before new workers fork so a changed import
     header cannot leave an in-flight worker using the previous graph. *)
  Hashtbl.reset project_symbol_cache;
  List.iter (fun (uri, document) ->
    let retain (cached_uri, _) _ = cached_uri <> uri in
    analysis_recency := List.filter (fun (cached_uri, _) -> cached_uri <> uri) !analysis_recency;
    Hashtbl.filter_map_inplace (fun key value -> if retain key value then Some value else None) diagnostic_cache;
    Hashtbl.filter_map_inplace (fun key value -> if retain key value then Some value else None) symbol_cache;
    Hashtbl.filter_map_inplace (fun key value -> if retain key value then Some value else None) semantic_token_cache;
    Hashtbl.filter_map_inplace (fun key value -> if retain key value then Some value else None) member_cache;
    Hashtbl.filter_map_inplace (fun key value -> if retain key value then Some value else None) signature_cache;
    Hashtbl.filter_map_inplace (fun key value -> if retain key value then Some value else None) formatting_cache;
    Hashtbl.remove document_dependencies uri;
    schedule_diagnostics uri document) affected

let flush_due_diagnostics output =
  let now = Unix.gettimeofday () in
  let due = Hashtbl.fold (fun uri (document, deadline) due ->
      if deadline <= now then (uri, document) :: due else due) pending_checks [] in
  List.iter (fun (uri, document) ->
      Hashtbl.remove pending_checks uri;
      match Hashtbl.find_opt documents uri with
      | Some current when String.equal current.text document.text ->
          (try start_diagnostic_job uri current with Sys_error message ->
            publish_diagnostics output current [compiler_fallback message]
          | Unix.Unix_error (error, _, _) ->
            publish_diagnostics output current [compiler_fallback (Unix.error_message error)])
      | _ -> ()) due

let windows_worker_flag = "--amlc-lsp-analysis-worker"
let max_worker_overlay_bytes = 8_000_000

let windows_worker_request uri text =
  let _, _, overlays = Hashtbl.fold (fun open_uri document (count, bytes, overlays) ->
    let size = String.length open_uri + String.length document.text + 64 in
    if String.equal open_uri uri || count >= 4 * max_editor_requests
      || bytes + size > max_worker_overlay_bytes then count, bytes, overlays
    else count + 1, bytes + size, `Assoc [
      "uri", `String open_uri; "text", `String document.text;
      "version", Option.value ~default:`Null (Option.map (fun value -> `Int value) document.version)
    ] :: overlays) documents (0, 0, []) in
  `Assoc [
    "uri", `String uri; "text", `String text; "documents", `List overlays;
    "dialect", (match !dialect_override with
      | Some Legacy_amlc -> `String "legacy"
      | Some Appliedml -> `String "appliedml"
      | None -> `Null)
  ]

let run_windows_worker uri text =
  let request = Filename.temp_file "amlc-lsp-request-" ".json" in
  let response = Filename.temp_file "amlc-lsp-response-" ".bin" in
  let pid = ref None and reaped = ref false in
  Fun.protect ~finally:(fun () ->
    Option.iter (fun child ->
      if not !reaped then begin
        (try Unix.kill child Sys.sigkill with Unix.Unix_error _ -> ());
        (try ignore (Unix.waitpid [] child) with Unix.Unix_error _ -> ())
      end) !pid;
    remove_temporary_file request;
    remove_temporary_file response) (fun () ->
      Yojson.Safe.to_file request (windows_worker_request uri text);
      let executable = Sys.executable_name in
      let arguments = [|executable; windows_worker_flag; request; response|] in
      (* The worker communicates only through its request and response files.
         Do not share the LSP pipes with the Windows reader thread or allow a
         library message to corrupt the protocol stream. *)
      let null = Unix.openfile "NUL" [Unix.O_RDWR] 0o600 in
      let child =
        try
          let child = Unix.create_process executable arguments null null null in
          close_noerr null;
          child
        with error -> close_noerr null; raise error in
      pid := Some child;
      let deadline = Unix.gettimeofday () +. analysis_timeout_seconds in
      let rec wait () =
        match Unix.waitpid [Unix.WNOHANG] child with
        | 0, _ when Unix.gettimeofday () < deadline -> Unix.sleepf 0.02; wait ()
        | 0, _ -> Error "worker exceeded the analysis timeout"
        | _, Unix.WEXITED 0 ->
            reaped := true;
            let stat = Unix.stat response in
            if stat.st_size > max_compiler_output_bytes + 65_536 then
              Error "worker exceeded the analysis output limit"
            else
              In_channel.with_open_bin response (fun channel ->
                try (Marshal.from_channel channel : (document_analysis, string) result)
                with Failure _ | Invalid_argument _ -> Error "worker returned invalid output")
        | _, _ -> reaped := true; Error "worker exited unsuccessfully"
      in
      wait ())

(* Native Windows has no [fork]. Run the same executable as a bounded, one-shot
   official-library worker after coalescing protocol frames. *)
let flush_pending_diagnostics_windows output =
  let now = Unix.gettimeofday () in
  let pending = Hashtbl.fold (fun uri (document, deadline) pending ->
    if deadline <= now then (uri, document, deadline) :: pending else pending) pending_checks [] in
  let requested document = List.exists (fun request ->
    request.snapshot = document) !editor_requests in
  let pending = List.sort (fun (_, left, left_deadline) (_, right, right_deadline) ->
    compare (not (requested left), left_deadline) (not (requested right), right_deadline)) pending in
  match pending with
  | (uri, document, _) :: _ ->
    Hashtbl.remove pending_checks uri;
    begin match Hashtbl.find_opt documents uri with
      | Some current when String.equal current.text document.text ->
          let result = try run_windows_worker uri current.text
            with error -> Error (Printexc.to_string error) in
          publish_analysis_result output uri current result
      | _ -> ()
    end
  | [] -> ()

type input_event = Input_message of Yojson.Safe.t | Input_end | Input_error of exn

let windows_input_reader () =
  let queue = Queue.create () in
  let mutex = Mutex.create () in
  let space = Condition.create () in
  let capacity = 4 * max_editor_requests in
  let push event =
    Mutex.lock mutex;
    while Queue.length queue >= capacity do Condition.wait space mutex done;
    Queue.add event queue;
    Mutex.unlock mutex in
  let pop () =
    Mutex.lock mutex;
    let event = Queue.take_opt queue in
    Option.iter (fun _ -> Condition.signal space) event;
    Mutex.unlock mutex;
    event in
  let rec read () = match Jsonrpc.read stdin with
    | Some message -> push (Input_message message); read ()
    | None -> push Input_end
    | exception error -> push (Input_error error) in
  ignore (Thread.create read ());
  pop

let next_check_timeout () =
  let now = Unix.gettimeofday () in
  let timeout = Hashtbl.fold (fun _ (_, deadline) timeout ->
      min timeout (max 0. (deadline -. now))) pending_checks 1.0 in
  List.fold_left (fun timeout request -> min timeout (max 0. (request.deadline -. now)))
    timeout !editor_requests

let response id result = `Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ]
let error_response id code message = `Assoc [
  ("jsonrpc", `String "2.0"); ("id", id); ("error", `Assoc [ ("code", `Int code); ("message", `String message) ]);
]

let initialize_result = `Assoc [
  ("capabilities", `Assoc [
    ("textDocumentSync", `Assoc [ ("openClose", `Bool true); ("change", `Int 2) ]);
    (* Workers publish complete reports, including dependency-only changes.
       Do not also advertise pull: clients keep its reports separately from
       pushed diagnostics, leaving duplicate or stale entries after edits.
       The explicit diagnostic request remains a cached compatibility query. *)
    ("completionProvider", `Assoc [ ("triggerCharacters", `List [`String "."]) ]);
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
  ]);
  ("serverInfo", `Assoc [ ("name", `String "amlc-lsp"); ("version", `String "0.3.0") ]);
]

let library_methods = [
  "textDocument/diagnostic"; "textDocument/completion";
  "textDocument/documentSymbol";
  "textDocument/definition"; "textDocument/declaration"; "textDocument/references";
  "textDocument/prepareRename"; "textDocument/rename"; "textDocument/codeAction";
  "textDocument/hover"; "textDocument/signatureHelp"; "textDocument/formatting";
  "textDocument/semanticTokens/full";
  "textDocument/foldingRange"; "textDocument/selectionRange";
]

let initialized_result () =
  if Option.is_none !library_analyzer then initialize_result else
  let fields = Util.to_assoc initialize_result in
  let capabilities = Util.member "capabilities" initialize_result |> Util.to_assoc in
  let capabilities = List.filter (fun (key, _) -> List.mem key [
    "textDocumentSync"; "foldingRangeProvider"; "selectionRangeProvider"; "workspace";
    "documentSymbolProvider"; "definitionProvider"; "declarationProvider"; "hoverProvider";
    "documentFormattingProvider"; "semanticTokensProvider"; "referencesProvider";
    "renameProvider"; "codeActionProvider"
  ]) capabilities in
  `Assoc (("capabilities", `Assoc (("completionProvider",
      `Assoc ["triggerCharacters", `List [`String "."]]) ::
      ("signatureHelpProvider", `Assoc ["triggerCharacters", `List [`String "("; `String ","; `String "["]]) :: capabilities))
    :: List.remove_assoc "capabilities" fields)

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

let same_compiler_symbol (first : compiler_symbol) (second : compiler_symbol) =
  match first.id, second.id with
  | Some first, Some second -> String.equal first second
  | _ -> first.kind = second.kind && first.name = second.name
      && first.selection_start = second.selection_start
      && first.selection_end = second.selection_end

(* Compiler ranges remain authoritative for edits.  The lexical pass only
   proves that no same-spelled identifier was omitted from every compiler
   symbol; an unexplained token makes rename unavailable rather than becoming
   an edit by textual matching. *)
let compiler_occurrences_complete document name symbols =
  let indexed = Hashtbl.create 16 in
  let ranges_valid = ref true in
  symbols |> List.filter (fun (symbol : compiler_symbol) -> symbol.name = name)
  |> List.iter (fun symbol ->
      List.iter (fun (_, first, last) ->
        match first.offset, last.offset with
        | Some first, Some last when first < last && last <= String.length document.text
            && String.sub document.text first (last - first) = name ->
            Hashtbl.replace indexed (first, last) ()
        | _ -> ranges_valid := false) symbol.occurrences);
  let code = source_code_mask document.text in
  let rec scan index =
    if index >= String.length code then true
    else if is_identifier code.[index] then
      let rec finish last =
        if last < String.length code && is_identifier code.[last] then finish (last + 1)
        else last in
      let last = finish (index + 1) in
      if last - index = String.length name
          && String.sub code index (last - index) = name
          && not (Hashtbl.mem indexed (index, last))
      then false else scan last
    else scan (index + 1) in
  !ranges_valid && Hashtbl.length indexed > 0 && scan 0

let source_has_identifier source name =
  let code = source_code_mask source in
  let rec scan index =
    if index >= String.length code then false
    else if is_identifier code.[index] then
      let rec finish last =
        if last < String.length code && is_identifier code.[last] then finish (last + 1)
        else last in
      let last = finish (index + 1) in
      (last - index = String.length name && String.sub code index (last - index) = name)
      || scan last
    else scan (index + 1) in
  scan 0

let compiler_rename_safe document symbol =
  Hashtbl.find_opt diagnostic_cache (document_key document) = Some []
  && match Hashtbl.find_opt symbol_cache (document_key document) with
     | Some symbols -> compiler_occurrences_complete document symbol.name symbols
     | None -> false

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
      Option.bind (Hashtbl.find_opt symbol_cache (document_key document)) (fun symbols ->
          List.find_map (fun (symbol : compiler_symbol) ->
              if not (String.equal symbol.name word) then None else
              List.find_map (fun (role, start_position, end_position) ->
                  if position_in_range document.text line character start_position end_position
                  then Some (symbol, role, start_position, end_position)
                  else None) symbol.occurrences) symbols))

let legacy_completion_keywords = [
  "program"; "import"; "export"; "size"; "measure"; "law"; "input";
  "term"; "form"; "kind"; "marks"; "under"; "steps"; "depth"; "work";
  "data"; "shape"; "permit"; "tag"; "make"; "erase"; "once"; "many";
  "let"; "in"; "if"; "then"; "else"; "case"; "of"; "use"; "split";
  "fold"; "every"; "some"; "any"; "count"; "total"; "orbit"; "from";
  "with"; "step"; "equal"; "fit"; "wide"; "length"; "read"; "write";
  "emit"; "fail"; "cat"; "take"; "drop"; "vcat"; "at"; "uncons";
  "close"; "max"; "abs"; "ok"; "err"; "fst"; "snd";
  "true"; "false"; "unit"; "int"; "bool"; "bytes"; "vec"; "seq";
  "sint"; "uint"; "cap"; "result"; "res";
]

(* AppliedML spellings documented by Octra's current examples and cheatsheet.
   The compiler accepts additional compatibility aliases; those remain valid,
   but are not presented as the default completion path. *)
let appliedml_completion_keywords = [
  "program"; "contract"; "state"; "event"; "constructor";
  "fn"; "form"; "main"; "view"; "pure"; "private"; "public"; "internal"; "payable";
  "const"; "return"; "assert"; "require"; "emit"; "while"; "for";
  "self"; "caller"; "origin"; "epoch"; "epoch_time"; "value"; "balance";
  "invariant"; "struct"; "enum"; "match"; "interface"; "implements";
  "import"; "error"; "revert"; "where"; "option"; "some"; "none";
  "unwrap"; "is_some"; "self_addr"; "tree_hash";
  "node_id"; "tx_hash"; "nonreentrant"; "log"; "indexed";
  "once"; "many"; "marks"; "under"; "steps"; "depth"; "work";
  "use"; "split"; "orbit"; "equal"; "then"; "from"; "with";
  "write"; "read"; "fail";
]

let completion_keywords_for text =
  match document_dialect text with
  | Legacy_amlc -> legacy_completion_keywords
  | Appliedml -> appliedml_completion_keywords

let rename_reserved_words = legacy_completion_keywords @ appliedml_completion_keywords @ [
  "Contract"; "None"; "Option"; "Program"; "Some"; "address"; "and"; "as"; "bytes32"; "cipher";
  "list"; "map"; "not"; "or"; "pubkey"; "string";
  "u64"; "u128"; "u256"; "var"; "void";
]

let valid_rename_identifier name =
  valid_identifier name
  && not (List.mem name rename_reserved_words)

let completion_item ?(kind = 14) ?(detail = "AppliedML") label =
  `Assoc [ ("label", `String label); ("kind", `Int kind); ("detail", `String detail) ]

let scoped_symbol (symbol : compiler_symbol) = List.mem symbol.kind ["local"; "parameter"; "iterator"]

let symbol_completion_item (symbol : compiler_symbol) =
  completion_item ~kind:(if scoped_symbol symbol then 6 else match symbol.kind with "enum" -> 13 | "struct" -> 22 | _ -> 3)
    ~detail:(Option.value ~default:symbol.typ symbol.signature) symbol.name

let lsp_symbol_kind = function
  | "program" | "contract" | "interface" -> 2
  | "struct" -> 23
  | "enum" -> 10
  | "enumMember" -> 22
  | "field" -> 8
  | "event" -> 24
  | "constant" -> 14
  | "constructor" -> 9
  | "function" | "form" | "method" -> 12
  | _ -> 13

let text_edit text first last replacement =
  `Assoc [ ("range", range_from_offsets text first last); ("newText", `String replacement) ]

let compiler_form document name =
  List.find_opt (fun (symbol : compiler_symbol) ->
      List.mem symbol.kind ["form"; "function"; "constructor"] && String.equal symbol.name name)
    (Option.value ~default:[] (Hashtbl.find_opt symbol_cache (document_key document)))

let open_documents () =
  Hashtbl.fold (fun uri document documents -> (uri, document) :: documents) documents []

let library_workspace_query method_name document line character replacement =
  Option.bind !library_workspace_analyzer (fun query ->
    try
      let path = canonical_document_path document.uri in
      let roots = !workspace_roots |> List.filter_map (fun uri ->
        try Some (canonical_document_path uri) with Unix.Unix_error _ | Invalid_argument _ -> None) in
      if roots = [] || not (Sys.file_exists path) then None else
      let overlays = open_documents () |> List.filter_map (fun (_, open_document) ->
        try Some (canonical_document_path open_document.uri, open_document.text)
        with Unix.Unix_error _ | Invalid_argument _ -> None) in
      Some (query method_name roots overlays path document.text
        (byte_offset document.text line character) replacement)
    with Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> None)

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
  let _, _, reversed_data = List.fold_left (fun (previous_line, previous_character, output) (line, character, width, kind) ->
      let line_delta = line - previous_line in
      let character_delta = if line_delta = 0 then character - previous_character else character in
      (line, character, 0 :: kind :: width :: character_delta :: line_delta :: output))
    (0, 0, []) tokens
  in
  `Assoc [ ("data", `List (List.rev_map (fun value -> `Int value) reversed_data)) ]

let case_contains text query = contains (String.lowercase_ascii text) (String.lowercase_ascii query)

let project_source_text uri path =
  match Hashtbl.find_opt documents uri with
  | Some document -> Some document.text
  | None ->
      begin try Some (In_channel.with_open_bin path In_channel.input_all) with Sys_error _ -> None end

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
      Option.value ~default:[] (Hashtbl.find_opt symbol_cache (document_key document))
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
  Option.value ~default:[] (Hashtbl.find_opt symbol_cache (document_key document))
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

let code_actions uri document params =
  let range_coordinates range =
    let coordinate name = Option.bind (object_member name range) (fun position ->
      Option.bind (int_member "line" position) (fun line ->
        Option.map (fun character -> line, character) (int_member "character" position))) in
    Option.bind (coordinate "start") (fun first ->
      Option.map (fun last -> first, last) (coordinate "end")) in
  let current = Option.value ~default:[]
      (Hashtbl.find_opt diagnostic_cache (document_key document))
    |> List.map (diagnostic document.text) in
  let current_diagnostic value = List.exists (fun known ->
    Util.member "code" known = Util.member "code" value
    && range_coordinates (Util.member "range" known)
       = range_coordinates (Util.member "range" value)) current in
  let action_for = function
    | `Assoc _ as diagnostic when current_diagnostic diagnostic ->
        begin match Util.member "code" diagnostic, Util.member "range" diagnostic with
        | `String code, range ->
            let action title replacement =
              `Assoc [
                ("title", `String title);
                ("kind", `String "quickfix");
                ("isPreferred", `Bool false);
                ("diagnostics", `List [diagnostic]);
                ("edit", `Assoc [
                  ("changes", `Assoc [
                    (uri, `List [ `Assoc [
                      ("range", range);
                      ("newText", `String replacement);
                    ] ]);
                  ]);
                ]);
              ] in
            begin match code with
            | "AMLC101" -> [ action "Insert missing ')'" ")" ]
            | "AMLC102" -> [ action "Insert missing '}'" "}" ]
            | "AMLC103" -> [ action "Insert missing ']'" "]" ]
            | "AMLC104" -> [ action "Insert missing ','" "," ]
            | "AMLC105" -> [ action "Insert missing 'in'" "in " ]
            | "AMLC106" -> [ action "Insert missing 'then'" "then " ]
            | "AMLC107" -> [ action "Insert missing 'else'" "else " ]
            | "AMLC108" -> [ action "Insert missing ':'" ": " ]
            | "REHOVOT101" -> [ action "Insert missing ':'" ": " ]
            | "REHOVOT102" -> [ action "Insert missing '}'" "}" ]
            | "REHOVOT103" -> [ action "Insert missing ')'" ")" ]
            | "REHOVOT104" -> [ action "Insert missing ']'" "]" ]
            | "REHOVOT105" -> [ action "Insert missing ','" "," ]
            | "REHOVOT001" -> [ action "Use canonical 'contract'" "contract" ]
            | "REHOVOT002" -> [ action "Use canonical 'program'" "program" ]
            | _ -> []
            end
        | _ -> []
        end
    | _ -> [] in
  match Util.member "context" params with
  | `Assoc fields ->
      (match List.assoc_opt "diagnostics" fields with
       | Some (`List diagnostics) -> `List (List.concat_map action_for diagnostics)
       | _ -> `List [])
  | _ -> `List []

let editor_locations result =
  match result with
  | `Assoc _ as result ->
      (match string_member "path" result, int_member "start" result, int_member "end" result with
       | Some path, Some first, Some last ->
           (try
              let uri, text = match open_document_at_path path with
                | Some (uri, target) -> uri, target.text
                | None -> uri_of_path path, In_channel.with_open_bin path In_channel.input_all in
              (* Use ranges only with the exact snapshot queried by the helper. *)
              let unchanged = match string_member "sourceHash" result with
                | Some hash -> hash = Digest.to_hex (Digest.string text)
                | None -> text = In_channel.with_open_bin path In_channel.input_all in
              if unchanged && first >= 0 && last >= first && last <= String.length text then
                [`Assoc ["uri", `String uri; "range", range_from_offsets text first last]]
              else []
            with Sys_error _ -> [])
       | _ -> [])
  | _ -> []

let imported_definition document offset =
  editor_locations (compiler_editor_query document "--definition=json" offset)

let rename_workspace_edit replacement result =
  let items = match result with
    | `Assoc fields -> (match List.assoc_opt "items" fields with Some (`List items) -> items | _ -> [])
    | _ -> [] in
  let locations = List.map (function
    | `Assoc _ as item when string_member "sourceHash" item <> None -> editor_locations item
    | _ -> []) items in
  let invalid_target = function
    | [location] ->
        (match Option.bind (string_member "uri" location) (Hashtbl.find_opt documents) with
         | Some { version = None; _ } -> true
         | _ -> false)
    | _ -> true in
  if items = [] || List.exists invalid_target locations then `Null else
  let edits = Hashtbl.create 16 in
  List.iter (fun locations ->
    let location = List.hd locations in
    let uri = Util.member "uri" location |> Util.to_string in
    let edit = `Assoc ["range", Util.member "range" location; "newText", `String replacement] in
    Hashtbl.replace edits uri (edit :: Option.value ~default:[] (Hashtbl.find_opt edits uri))) locations;
  `Assoc ["documentChanges", `List (Hashtbl.fold (fun uri edits all -> (uri, edits) :: all) edits []
    |> List.sort compare |> List.map (fun (uri, edits) ->
      let version = match Hashtbl.find_opt documents uri with
        | Some { version = Some version; _ } -> `Int version | _ -> `Null in
      `Assoc ["textDocument", `Assoc ["uri", `String uri; "version", version];
        "edits", `List (List.rev edits)]))]

let request_result method_name params =
  let document = Option.bind (uri_from_params params) (fun uri ->
      Option.map (fun document -> uri, document) (Hashtbl.find_opt documents uri)) in
  Option.iter (fun (_, document) ->
    if Hashtbl.mem diagnostic_cache (document_key document) then remember_analysis (document_key document)) document;
  match method_name, document with
  | "textDocument/diagnostic", Some (_uri, document) ->
      let diagnostics = Option.value ~default:[] (Hashtbl.find_opt diagnostic_cache (document_key document)) in
      `Assoc [ ("kind", `String "full"); ("items", `List (List.map (diagnostic document.text) diagnostics)) ]
  | "workspace/symbol", _ ->
      `List (workspace_symbols (Option.value ~default:"" (string_member "query" params)))
  | ("textDocument/definition" | "textDocument/declaration"), Some (uri, document)
    when Option.is_some !library_analyzer ->
      let location = Option.bind (position_from_params params) (fun (line, character) ->
        Option.bind (compiler_occurrence_at document line character)
          (fun (symbol, _, _, _) -> compiler_location uri document.text symbol)) in
      `List (Option.to_list location)
  | "textDocument/hover", Some (_uri, document) when Option.is_some !library_analyzer ->
      let hover = Option.bind (position_from_params params) (fun (line, character) ->
        Option.map (fun (symbol, _, first, last) ->
          `Assoc [
            "contents", `Assoc ["kind", `String "plaintext";
              "value", `String (Option.value ~default:symbol.name symbol.signature)];
            "range", `Assoc ["start", lsp_position document.text first;
              "end", lsp_position document.text last]
          ]) (compiler_occurrence_at document line character)) in
      Option.value ~default:`Null hover
  | "textDocument/hover", Some (_uri, document) ->
      begin
        match position_from_params params with
        | Some (line, character) ->
            begin
              match word_at document.text line character with
              | Some (word, _, _) ->
                  begin match List.find_opt (fun (symbol : compiler_symbol) -> String.equal symbol.name word)
                    (Option.value ~default:[] (Hashtbl.find_opt symbol_cache (document_key document))) with
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
                  let local = Option.bind
                    (List.find_opt (fun (symbol : compiler_symbol) -> String.equal symbol.name word)
                      (Option.value ~default:[] (Hashtbl.find_opt symbol_cache (document_key document))))
                    (compiler_location uri document.text) in
                  (match local with
                   | Some location -> `List [location]
                   | None -> `List (imported_definition document (byte_offset document.text line character)))
              | None -> `List []
            end
        | None -> `List []
      end
  | "textDocument/completion", Some (_, current) ->
      let compiler_items =
        Option.value ~default:[] (Option.map (fun (_uri, document) ->
          Option.value ~default:[] (Hashtbl.find_opt symbol_cache (document_key document))) document)
        |> List.filter (fun (symbol : compiler_symbol) ->
            if Option.is_none !library_analyzer then true
            else if List.mem symbol.kind ["constructor"; "enumMember"; "field"] then false
            else if not (scoped_symbol symbol) then true else
            match position_from_params params with
            | Some cursor -> List.exists (fun (first, last) ->
                (first.line, first.character) <= cursor &&
                (cursor < (last.line, last.character) ||
                 (Option.is_none symbol.selection_start && cursor = (last.line, last.character)
                  && last.offset = Some (String.length current.text)))) symbol.completion_scopes
            | _ -> false)
        |> (fun symbols -> if Option.is_none !library_analyzer then symbols else
            let locals, others = List.partition scoped_symbol symbols in
            (* Recovered EOF ranges may share an inclusive endpoint. Prefer the
               innermost matching scope before deduplicating same-named items. *)
            let cursor = position_from_params params in
            let start symbol = match cursor with
              | None -> -1, -1
              | Some cursor -> List.fold_left (fun latest (first, last) ->
                  let first = first.line, first.character and last = last.line, last.character in
                  if first <= cursor && cursor <= last then max latest first else latest)
                  (-1, -1) symbol.completion_scopes in
            let locals = List.stable_sort (fun a b -> compare (start b) (start a)) locals in
            locals @ others)
        |> List.map symbol_completion_item
      in
      let keywords = match document with
        | None -> legacy_completion_keywords
        | Some (_uri, document) -> completion_keywords_for document.text
      in
      let local_items, member = match position_from_params params with
        | Some (line, character) ->
            let offset = byte_offset current.text line character in
            let rec start i = if i > 0 && is_identifier current.text.[i - 1] then start (i - 1) else i in
            let first = start offset in
            let items, suppress = if Option.is_none !library_analyzer then compiler_completions current offset
              else
                let sites = Option.value ~default:[] (Hashtbl.find_opt member_cache (document_key current)) in
                match List.find_opt (fun site ->
                  (site.member_start.line, site.member_start.character) <= (line, character)
                  && (line, character) <= (site.member_end.line, site.member_end.character)) sites with
                | Some site -> site.member_items, true
                | None -> [], false in
            items, suppress || (first > 0 && current.text.[first - 1] = '.')
        | None -> [], false in
      let keyword_items = List.map completion_item keywords in
      let items = if member then local_items else local_items @
        (if Option.is_some !library_analyzer then compiler_items @ keyword_items
         else keyword_items @ compiler_items) in
      let seen = Hashtbl.create 32 in
      let items = List.filter (fun item -> match string_member "label" item with
        | None -> false
        | Some label when Hashtbl.mem seen label -> false
        | Some label -> Hashtbl.add seen label (); true) items in
      `Assoc [
        ("isIncomplete", `Bool (Option.is_some !library_analyzer &&
          Hashtbl.find_opt diagnostic_cache (document_key current) <> Some []));
        ("items", `List items);
      ]
  | "textDocument/documentSymbol", Some (_uri, document) ->
      `List (Option.value ~default:[] (Hashtbl.find_opt symbol_cache (document_key document))
        |> List.filter_map (fun (symbol : compiler_symbol) ->
            match symbol.selection_start, symbol.selection_end with
            | _ when Option.is_some !library_analyzer
                && (scoped_symbol symbol || symbol.kind = "import") -> None
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
      if Option.is_some !library_analyzer
        && Hashtbl.find_opt diagnostic_cache (document_key document) <> Some [] then `List []
      else if Option.is_none !library_analyzer && is_appliedml_contract document.text then
        (match position_from_params params with
         | Some (line, character) ->
             let include_declaration = match object_member "context" params with
               | Some context -> Util.member "includeDeclaration" context = `Bool true
               | None -> false in
             (match compiler_editor_query document "--references=json" (byte_offset document.text line character) with
              | `Assoc _ as result ->
                  if Util.member "complete" result <> `Bool true then
                    Jsonrpc.log "references: workspace analysis is incomplete; returning verified matches only";
                  let references = match Util.member "items" result with `List items -> items | _ -> [] in
                  `List (references |> List.concat_map (fun reference ->
                  if include_declaration || string_member "role" reference <> Some "declaration"
                  then editor_locations reference else []))
              | _ -> `List [])
         | None -> `List [])
      else
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
                let local () = `List (compiler_occurrence_locations
                  ~include_declaration uri document.text symbol) in
                if Option.is_some !library_analyzer && List.mem symbol.kind ["interface"; "import"] then
                  (match library_workspace_query "references" document line character None with
                   | Some (`Assoc _ as result) ->
                       if Util.member "complete" result <> `Bool true then
                         Jsonrpc.log "references: workspace analysis is incomplete; returning verified matches only";
                       let items = match Util.member "items" result with `List items -> items | _ -> [] in
                       let locations = items |> List.concat_map (fun item ->
                         if include_declaration || string_member "role" item <> Some "declaration"
                         then editor_locations item else []) in
                       if locations = [] then local () else `List locations
                   | _ -> local ())
                else local ()
            | None -> `List []
            end
        | None -> `List []
      end
  | "textDocument/prepareRename", Some (_uri, document) ->
      if Option.is_none !library_analyzer && is_appliedml_contract document.text then
        (match position_from_params params with
         | Some (line, character) when !supports_document_changes ->
             let result = compiler_editor_query document "--rename=json" (byte_offset document.text line character) in
             let name = match result with `Assoc _ -> string_member "name" result | _ -> None in
             (match name, word_at document.text line character with
              | Some name, Some (_, first, last) when rename_workspace_edit name result <> `Null ->
                  `Assoc ["placeholder", `String name; "range", range_from_offsets document.text first last]
              | _ -> `Null)
         | _ -> `Null)
      else if Option.is_some !library_analyzer
          && Hashtbl.find_opt diagnostic_cache (document_key document) <> Some [] then `Null
      else
      begin match position_from_params params with
      | Some (line, character) ->
          begin match compiler_occurrence_at document line character with
          | Some (symbol, _, start_position, end_position) ->
              let prepared = `Assoc [
                  ("range", `Assoc [
                    ("start", lsp_position document.text start_position);
                    ("end", lsp_position document.text end_position);
                  ]);
                  ("placeholder", `String symbol.name);
                ] in
              if Option.is_some !library_analyzer && List.mem symbol.kind ["interface"; "import"] then
                if not !supports_document_changes then `Null else
                (match library_workspace_query "rename" document line character None with
                 | Some (`Assoc _ as result) when rename_workspace_edit symbol.name result <> `Null -> prepared
                 | _ -> `Null)
              else if Option.is_none !library_analyzer || compiler_rename_safe document symbol
              then prepared else `Null
          | None -> `Null
          end
      | None -> `Null
      end
  | "textDocument/rename", Some (uri, document) ->
      if Option.is_none !library_analyzer && is_appliedml_contract document.text then
        (match position_from_params params, string_member "newName" params with
         | Some (line, character), Some replacement
             when !supports_document_changes && valid_rename_identifier replacement ->
             rename_workspace_edit replacement
               (compiler_editor_query ~replacement document "--rename=json" (byte_offset document.text line character))
         | _ -> `Null)
      else if Option.is_some !library_analyzer
          && Hashtbl.find_opt diagnostic_cache (document_key document) <> Some [] then `Null
      else
      begin
        match position_from_params params, string_member "newName" params with
        | Some (line, character), Some replacement ->
            begin
              match compiler_occurrence_at document line character with
              | Some (symbol, _, _, _) when valid_rename_identifier replacement ->
                  let local_rename () =
                    let symbols = Option.value ~default:[] (Hashtbl.find_opt symbol_cache (document_key document)) in
                    if (Option.is_none !library_analyzer || compiler_rename_safe document symbol)
                      && (replacement = symbol.name
                          || not (source_has_identifier document.text replacement))
                      && not (List.exists (fun (other : compiler_symbol) ->
                        String.equal other.name replacement && not (same_compiler_symbol other symbol)) symbols)
                    then `Assoc [ ("changes", `Assoc [
                          (uri, `List (compiler_occurrence_edits document.text replacement symbol));
                        ]) ]
                    else `Null in
                  if Option.is_some !library_analyzer && List.mem symbol.kind ["interface"; "import"]
                      && Option.is_some !library_workspace_analyzer then
                    if not !supports_document_changes then `Null else
                    (match library_workspace_query "rename" document line character (Some replacement) with
                     | Some result -> rename_workspace_edit replacement result
                     | None -> `Null)
                  else local_rename ()
              | _ -> `Null
            end
        | _ -> `Null
      end
  | "textDocument/codeAction", Some (_uri, document) ->
      code_actions (Option.value ~default:"" (uri_from_params params)) document params
  | "textDocument/signatureHelp", Some (_uri, document) ->
      begin match position_from_params params with
      | Some (line, character) when Option.is_some !library_analyzer ->
          let sites = Option.value ~default:[] (Hashtbl.find_opt signature_cache (document_key document)) in
          (match List.find_opt (fun site ->
              (site.signature_start.line, site.signature_start.character) <= (line, character)
              && (line, character) <= (site.signature_end.line, site.signature_end.character)) sites with
           | Some site -> site.signature_help | None -> `Null)
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
  | "textDocument/formatting", Some (_, document) when Option.is_some !library_analyzer ->
      let options = Util.member "options" params in
      let size = Option.value ~default:2 (int_member "tabSize" options) in
      if size < 1 || size > 16 then `List [] else
      let spaces = Util.member "insertSpaces" options <> `Bool false in
      let lines = Array.of_list (String.split_on_char '\n' document.text) in
      let layout = Option.join (Hashtbl.find_opt formatting_cache (document_key document)) in
      let bytes = ref (String.length document.text) in
      let edits = Option.value ~default:[] layout |> List.filter_map (fun (line, width, depth) ->
        if !bytes > max_document_bytes then None else
        let replacement = String.make (if spaces then depth * size else depth) (if spaces then ' ' else '\t') in
        bytes := !bytes + String.length replacement - width;
        if String.sub lines.(line) 0 width = replacement then None else
        Some (`Assoc ["range", `Assoc [
          "start", `Assoc ["line", `Int line; "character", `Int 0];
          "end", `Assoc ["line", `Int line; "character", `Int width]];
          "newText", `String replacement])) in
      if !bytes > max_document_bytes then `List [] else `List edits
  | "textDocument/formatting", Some (uri, document) ->
      if has_multiline_sensitive_lexeme document.text then `List [] else
      let formatted = format_document document.text in
      if String.equal formatted document.text
          || not (compiler_accepts ~path:(path_of_uri uri) formatted) then `List []
      else `List [ text_edit document.text 0 (String.length document.text) formatted ]
  | "textDocument/semanticTokens/full", Some (_uri, document) ->
      semantic_tokens document.text
        (Option.value ~default:[] (Hashtbl.find_opt symbol_cache (document_key document)))
        (Option.value ~default:[] (Hashtbl.find_opt semantic_token_cache (document_key document)))
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

let cancel_editor_requests output predicate code message =
  let cancelled, retained = List.partition predicate !editor_requests in
  editor_requests := retained;
  List.iter (fun request -> Jsonrpc.write output (error_response request.request_id code message)) cancelled

let flush_editor_requests output =
  let now = Unix.gettimeofday () in
  let ready, waiting = List.partition (fun request ->
    match Hashtbl.find_opt documents request.snapshot.uri with
    | Some current when current = request.snapshot && !dialect_override = request.dialect ->
        Hashtbl.mem diagnostic_cache (document_key current) || now >= request.deadline
    | _ -> true) !editor_requests in
  editor_requests := waiting;
  List.iter (fun request ->
    let message = match Hashtbl.find_opt documents request.snapshot.uri with
      | Some current when current = request.snapshot && !dialect_override = request.dialect ->
          response request.request_id (request_result request.method_name request.params)
      | _ -> error_response request.request_id (-32801) "document changed while awaiting analysis" in
    Jsonrpc.write output message) ready

let defer_editor_request id method_name params =
  if Option.is_none !library_analyzer
    || not (List.mem method_name ["textDocument/completion"; "textDocument/signatureHelp";
      "textDocument/formatting"; "textDocument/semanticTokens/full"; "textDocument/hover";
      "textDocument/definition"; "textDocument/declaration"; "textDocument/references";
      "textDocument/prepareRename"; "textDocument/rename";
      "textDocument/documentSymbol"; "textDocument/diagnostic"])
    || List.length !editor_requests >= max_editor_requests then false else
  let has_position = List.mem method_name ["textDocument/formatting"; "textDocument/semanticTokens/full";
    "textDocument/documentSymbol"; "textDocument/diagnostic"]
    || Option.is_some (position_from_params params) in
  match Option.bind (uri_from_params params) (Hashtbl.find_opt documents), has_position with
  | Some document, true when not (Hashtbl.mem diagnostic_cache (document_key document)) ->
      let now = Unix.gettimeofday () in
      editor_requests := !editor_requests @ [{ request_id = id; method_name; params;
        snapshot = document; dialect = !dialect_override; deadline = now +. editor_wait_seconds }];
      (* Reuse an active worker; only expedite a debounced/missing check. *)
      if not (Hashtbl.mem diagnostic_jobs document.uri) then
        Hashtbl.replace pending_checks document.uri (document, now);
      true
  | _ -> false

let document_from_params params =
  match object_member "textDocument" params with
  | Some document -> Option.bind (string_member "uri" document) (fun uri ->
      Option.map (fun text -> (uri, { uri; text; version = int_member "version" document })) (string_member "text" document))
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
              Option.map (fun text -> uri, { uri; text; version = int_member "version" document })
                (List.fold_left (fun text change -> Option.bind text (fun value -> apply value change)) (Some current.text) changes)
          end
      | _ -> None)
  | None -> None

let handle_notification output method_name params =
  let open_document document = match document with
    | Some (uri, document) ->
        Hashtbl.replace documents uri document;
        Hashtbl.remove pending_checks uri;
        refresh_open_diagnostics ~changed:uri ()
    | None -> Jsonrpc.log ("ignored malformed " ^ method_name ^ " notification")
  in
  let change_document document = match document with
    | Some (uri, document) ->
        let unchanged = match Hashtbl.find_opt documents uri with Some previous -> String.equal previous.text document.text | None -> false in
        Hashtbl.replace documents uri document;
        if not unchanged then begin
          refresh_open_diagnostics ~changed:uri ()
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
  | "$/cancelRequest" ->
      let id = Util.member "id" params in
      cancel_editor_requests output (fun request -> request.request_id = id) (-32800) "request cancelled"
  | "textDocument/didOpen" -> open_document (document_from_params params)
  | "textDocument/didChange" -> change_document (changed_document params)
  | "textDocument/didSave" -> (match Option.bind (object_member "textDocument" params) (string_member "uri") with
      | Some uri -> refresh_open_diagnostics ~changed:uri ()
      | None -> Jsonrpc.log "ignored malformed textDocument/didSave notification")
  | "textDocument/didClose" -> (match Option.bind (object_member "textDocument" params) (string_member "uri") with
      | Some uri ->
          Hashtbl.remove documents uri;
          Hashtbl.remove document_dependencies uri;
          Hashtbl.remove pending_checks uri;
          cancel_diagnostic_job uri;
          refresh_open_diagnostics ~changed:uri ();
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
  | Some "exit", `Null -> raise Exit
  | Some "initialize", id when id <> `Null && not !initialized ->
      workspace_roots := workspace_roots_from_params params;
      supports_document_changes :=
        (match Option.bind (object_member "capabilities" params) (object_member "workspace")
          |> fun workspace -> Option.bind workspace (object_member "workspaceEdit") with
         | Some edit -> Util.member "documentChanges" edit = `Bool true
         | None -> false);
      Option.iter (fun options ->
          Option.iter (fun value -> set_dialect_override (dialect_of_string (String.lowercase_ascii value)))
            (string_member "dialect" options))
        (object_member "initializationOptions" params);
      initialized := true;
      Jsonrpc.write output (response id (initialized_result ()))
  | Some "initialize", id when id <> `Null -> Jsonrpc.write output (error_response id (-32600) "server already initialized")
  | Some "shutdown", id when id <> `Null && !initialized ->
      cancel_editor_requests output (fun _ -> true) (-32800) "server shutting down";
      shutting_down := true; Jsonrpc.write output (response id `Null)
  | Some "shutdown", id when id <> `Null -> Jsonrpc.write output (error_response id (-32002) "server is not initialized")
  | Some method_name, id when id <> `Null && !initialized && not !shutting_down
      && Option.is_some !library_analyzer && not (List.mem method_name library_methods) ->
      Jsonrpc.write output (error_response id (-32601)
        ("unsupported by official AMLC analysis: " ^ method_name))
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
            if not (defer_editor_request id method_name params) then
              Jsonrpc.write output (response id (request_result method_name params))
        | _ -> Jsonrpc.write output (error_response id (-32601) ("unsupported method: " ^ method_name))
      end
  | Some _, `Null -> ()
  | Some method_name, id -> Jsonrpc.write output (error_response id (-32601) ("unsupported method: " ^ method_name))
  | None, _ -> Jsonrpc.log "ignored message without a method"

let run ?analyze ?workspace_analyze () =
  library_analyzer := analyze;
  library_workspace_analyzer := workspace_analyze;
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  if Array.length Sys.argv = 4 && Sys.argv.(1) = windows_worker_flag
      && Option.is_some !library_analyzer then begin
    let result =
      try
        let stat = Unix.stat Sys.argv.(2) in
        if stat.st_kind <> Unix.S_REG
          || stat.st_size > max_document_bytes + max_worker_overlay_bytes + 262_144
        then Error "worker request exceeded the input limit"
        else
          let request = Yojson.Safe.from_file Sys.argv.(2) in
          begin match string_member "dialect" request with
            | Some value -> set_dialect_override (dialect_of_string value)
            | None -> set_dialect_override None
          end;
          begin match Util.member "documents" request with
            | `List values -> List.iter (fun value ->
                match string_member "uri" value, string_member "text" value with
                | Some uri, Some text when String.length text <= max_document_bytes ->
                    Hashtbl.replace documents uri {
                      uri; text; version = int_member "version" value }
                | _ -> ()) values
            | _ -> ()
          end;
          match string_member "uri" request, string_member "text" request with
          | Some uri, Some text -> Ok (analyze_document uri text)
          | _ -> Error "worker received an invalid request"
      with error -> Error (Printexc.to_string error)
    in
    Out_channel.with_open_bin Sys.argv.(3) (fun channel -> Marshal.to_channel channel result []);
    exit (if Result.is_ok result then 0 else 1)
  end;
  try
    if Sys.win32 && Option.is_some !library_analyzer then begin
      (* A reader thread lets the main loop preserve debounce while a native
         Windows stdin pipe has no portable [select]. Drain each burst before
         starting the bounded one-shot worker, so rapid edits analyze only the
         latest document snapshot. *)
      let pop_input = windows_input_reader () in
      while true do
        let handled = ref false in
        let rec drain () = match pop_input () with
          | Some (Input_message message) ->
              handled := true;
              (try handle_message stdout message with
               | Exit -> raise Exit
               | error -> Jsonrpc.log (Printexc.to_string error));
              drain ()
          | Some Input_end -> raise Exit
          | Some (Input_error error) -> raise error
          | None -> () in
        drain ();
        flush_pending_diagnostics_windows stdout;
        flush_editor_requests stdout;
        if not !handled then Thread.delay 0.01
      done
    end
    else
      while true do
        let stdin_fd = Unix.descr_of_in_channel stdin in
        let job_fds = Hashtbl.to_seq_values diagnostic_jobs |> List.of_seq
          |> List.filter (fun job -> not job.eof)
          |> List.map (fun job -> job.output) in
        let readable, _, _ = Unix.select (stdin_fd :: job_fds) [] [] (next_check_timeout ()) in
        if List.mem stdin_fd readable then (
          match Jsonrpc.read_fd stdin_fd with
          | Some message -> (try handle_message stdout message with
              | Exit -> raise Exit
              | error -> Jsonrpc.log (Printexc.to_string error))
          | None -> raise Exit);
        poll_diagnostic_jobs stdout readable;
        flush_due_diagnostics stdout;
        flush_editor_requests stdout
      done
  with Exit ->
    Hashtbl.to_seq_keys diagnostic_jobs |> List.of_seq |> List.iter cancel_diagnostic_job
