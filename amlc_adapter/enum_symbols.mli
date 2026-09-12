type symbol = { name : string; owner : string option; first : int; last : int;
  uses : (int * int) list }

val symbols : string -> Octra_vm.Oct_lang.contract -> symbol list
(** Original-token ranges matched to parsed enum declarations and qualified
    variants. The caller must discard uses unless original-source checking
    succeeds. Type annotations and unqualified names are not indexed here. *)
