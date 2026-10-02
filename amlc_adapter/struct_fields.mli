type symbol = { owner : string; name : string; typ : Octra_vm.Oct_lang.typ;
  first : int; last : int; uses : (int * int) list }

val symbols : string -> Octra_vm.Oct_lang.contract -> symbol list
(** Declaration ranges whose field list matches one struct, plus uses on
    storage paths whose receiver resolves to that struct. Root state fields,
    a trailing list or map [length], and local [name.member] accesses are not
    uses. Struct fields before that [length] still are. A field named [length]
    stays a normal segment. A mismatch between the path order and the lexer
    drops every use. Callers clear uses unless original-source checking succeeds. *)