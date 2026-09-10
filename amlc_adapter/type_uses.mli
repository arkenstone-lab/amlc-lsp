val parse : Octra_vm.Oct_lex.token_stream ->
  Octra_vm.Oct_lang.typ * (string * int * int) list
(** Parse exactly one official type and return ordered, lexer-verified named-type
    ranges. The stream advances exactly as with the official parser. Positions
    are UTF-8 byte offsets into the stream's source; refinements are excluded. *)

val declarations : string -> Octra_vm.Oct_lang.contract -> (string * int * int) list
(** Named types in AST-matched state, struct, event, constant and interface
    declarations. The caller must require successful original-source checking
    before exposing these ranges as references. *)
