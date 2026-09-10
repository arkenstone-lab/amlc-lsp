(** Lexer-verified call contexts for signature help, including unfinished calls.
    Ranges are inclusive cursor positions in UTF-8 bytes. At most 4096 sites
    are retained. Explicit [use] captures and its following argument are distinct
    contexts; ordinary indexing does not connect them. Names are syntactic
    candidates, not dispatch evidence. *)
type kind = Direct | Captures | Argument
type site = { first : int; last : int; name : string; name_start : int; parameter : int; kind : kind }
val sites : string -> site list
