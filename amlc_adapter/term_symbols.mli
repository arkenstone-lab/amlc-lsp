type parameter = { form : string; name : string; typ : string option;
  first : int; last : int; uses : (int * int) list }

val index : string -> Octra_vm.C_parse.t ->
  parameter list * (string * int * int) list
(** Colon-bound parameters of checked term forms, and direct [name(] calls.
    Parameter uses require the body variables to match the lexer in order;
    otherwise only selections are returned. The call list is empty for a form
    that is not a direct form. Synthetic binder names are ignored. *)