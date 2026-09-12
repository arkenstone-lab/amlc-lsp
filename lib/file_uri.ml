(* Paths are decoded exactly once at the protocol boundary. In particular,
   '+' is a literal filename character, not a form-encoded space. *)
let starts_with prefix value =
  String.length value >= String.length prefix
  && String.sub value 0 (String.length prefix) = prefix

let decode value =
  let hex = function
    | '0' .. '9' as c -> Char.code c - Char.code '0'
    | 'a' .. 'f' as c -> Char.code c - Char.code 'a' + 10
    | 'A' .. 'F' as c -> Char.code c - Char.code 'A' + 10
    | _ -> invalid_arg "invalid file URI escape"
  in
  let out = Buffer.create (String.length value) in
  let rec loop i =
    if i < String.length value then
      if value.[i] = '%' then begin
        if i + 2 >= String.length value then invalid_arg "incomplete file URI escape";
        let byte = (hex value.[i + 1] lsl 4) lor hex value.[i + 2] in
        if byte = 0 then invalid_arg "NUL in file URI";
        Buffer.add_char out (Char.chr byte);
        loop (i + 3)
      end else begin
        if value.[i] = '\000' then invalid_arg "NUL in file URI";
        Buffer.add_char out value.[i]; loop (i + 1)
      end
  in
  loop 0;
  Buffer.contents out

let to_path uri =
  if not (starts_with "file://" uri) then uri else
  let rest = String.sub uri 7 (String.length uri - 7) in
  let path =
    if starts_with "/" rest then rest
    else if starts_with "localhost/" rest then
      String.sub rest 9 (String.length rest - 9)
    else invalid_arg "unsupported file URI authority"
  in
  let path = decode path in
  if Sys.win32 && String.length path >= 3 && path.[2] = ':' then
    String.sub path 1 (String.length path - 1)
  else path

let of_path path =
  let path = if Sys.win32 then String.map (function '\\' -> '/' | c -> c) path else path in
  let path = if String.length path >= 2 && path.[1] = ':' then "/" ^ path else path in
  let out = Buffer.create (String.length path + 7) in
  Buffer.add_string out "file://";
  String.iter (function
    | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '~' | '/' | ':') as c ->
        Buffer.add_char out c
    | c -> Buffer.add_string out (Printf.sprintf "%%%02X" (Char.code c))) path;
  Buffer.contents out
