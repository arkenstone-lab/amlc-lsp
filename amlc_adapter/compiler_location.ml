let point source line column =
  let rec start current offset =
    if current = line then Some offset
    else match String.index_from_opt source offset '\n' with
      | None -> None
      | Some index -> start (current + 1) (index + 1) in
  if line < 1 || column < 1 then None else
  Option.bind (start 1 0) (fun start ->
    let finish = Option.value ~default:(String.length source)
        (String.index_from_opt source start '\n') in
    (* Compare before adding, so an overflowing column cannot wrap around. *)
    if column - 1 > finish - start then None else
    let offset = start + column - 1 in
    if offset < String.length source && Char.code source.[offset] land 0xc0 = 0x80
    then None else Some offset)

let offset ?origin ~source message =
  let strip prefix text =
    if String.starts_with ~prefix text then
      Some (String.sub text (String.length prefix) (String.length text - String.length prefix))
    else None in
  (* compile_multi prefixes located errors with the source path. Only its
     exact synthetic main path belongs to this document; imports do not. *)
  let header = match origin with
    | Some path -> strip ("source = " ^ path ^ " ") message
    | None -> Some message in
  Option.bind header (fun header ->
    Option.bind (strip "line " header) (fun header ->
      let number text =
        let rec digits index =
          if index < String.length text && text.[index] >= '0' && text.[index] <= '9'
          then digits (index + 1) else index in
        let length = digits 0 in
        if length = 0 then None else
        Option.map (fun value -> value,
          String.sub text length (String.length text - length))
          (int_of_string_opt (String.sub text 0 length)) in
      Option.bind (number header) (fun (line, rest) ->
        if String.starts_with ~prefix:": " rest then point source line 1 else
        Option.bind (strip " column " rest) (fun rest ->
          Option.bind (number rest) (fun (column, rest) ->
            if String.starts_with ~prefix:": " rest then point source line column
            else None)))))
