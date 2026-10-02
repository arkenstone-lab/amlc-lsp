(** Validate one-based compiler byte coordinates, including UTF-8 boundaries. *)
val point : string -> int -> int -> int option

(** Recover only AMLC's anchored diagnostic header. With [origin], require an
    exact [source = ...] prefix so imported-file locations remain unlocated in
    the current document. The original message is not rewritten. *)
val offset : ?origin:string -> source:string -> string -> int option
