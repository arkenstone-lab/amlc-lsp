(** Leading-indent layout from official lexer tokens: zero-based line, existing
    ASCII whitespace width, brace depth. Multiline strings/comments are protected;
    line endings and all non-leading bytes must be preserved by the caller. *)
val lines : string -> (int * int * int) list

(** Equivalent layout using the term lexer's source spans. Comment-prefixed
    lines are left untouched because comments are gaps in its token stream. *)
val term_lines : string -> (int * int * int) list option
