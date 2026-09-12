type symbol = { name : string; typ : Octra_vm.Oct_lang.typ; first : int; last : int;
  uses : (int * int) list }

val symbols : string -> Octra_vm.Oct_lang.contract -> symbol list
(** AST-matched state declarations and original-token root [self.field] uses.
    Callers must discard uses unless original-source checking succeeds.
    Nested struct fields and form effect targets are not indexed here. *)
