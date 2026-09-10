type site = { first : int; last : int; items : (string * string * int) list }
(** Cursor intervals are inclusive; items contain label, type and LSP kind.
    Empty sites suppress unrelated completion for unknown receivers. *)

val sites : ?statement_source:string -> string -> Octra_vm.Oct_lang.contract ->
  (Octra_vm.Oct_lang.typ -> string) -> site list
(** Lexer-backed completion for self storage paths and enum variants, capped at
    4096 sites. Bracketed state keys preserve their receiver, including nested
    key expressions. This does not resolve ordinary local-variable member access. *)
(* [statement_source] supplies offset-preserving recovered parser input, when
   different from source. Statement-only list methods use its AST locations. *)
