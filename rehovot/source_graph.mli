val canonical_path : string -> string
exception Source_limit
val imports : string -> (Oct_lang.import_decl * int * int) list
val read_source : (string * string) list -> string -> string
val dependencies : overlays:(string * string) list -> path:string -> string -> Yojson.Safe.t
val validate :
  ?check:((Oct_lang.contract -> [ `Callable | `Constant ] -> string -> string * Oct_lang.contract) ->
    string -> Oct_lang.contract -> Oct_lang.contract -> (int * int * string * string) list) ->
  overlays:(string * string) list -> path:string -> string -> (int * int * string * string) list
