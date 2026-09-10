(** Verified variable-token ranges within one officially parsed expression.
    Returns outer uses, typed expression-local bindings and explicit [use]
    form targets (not ordinary calls or same-named variables). Initializers
    and free body variables retain outer scope. Returns no ranges when ordered token
    roles cannot be matched (including colliding type/name roles). A binding's
    optional [scope] is its parser-verified body interval, with an exclusive end.
    Offsets are absolute UTF-8 bytes; [last] is exclusive. *)
type binding = { name : string; typ : Octra_vm.Oct_lang.typ;
  first : int; last : int; uses : (int * int) list; scope : (int * int) option }

val index : string -> int -> int -> Octra_vm.Oct_lang.expr ->
  (string * int * int) list * binding list * (string * int * int) list

(** Call-name ranges paired with their original AST expressions. Dispatch to a
    user function versus a builtin must still be verified by the caller. *)
val call_spans : string -> int -> int -> Octra_vm.Oct_lang.expr ->
  (string * int * int * Octra_vm.Oct_lang.expr) list
