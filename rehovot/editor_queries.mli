val in_code : string -> int -> bool
val complete : ?overlays:(string * string) list -> type_name:(Oct_lang.typ -> string) -> path:string -> string -> int -> Yojson.Safe.t list
val definition : ?overlays:(string * string) list -> path:string -> string -> int -> Yojson.Safe.t
val references : ?overlays:(string * string) list -> ?roots:string list -> path:string -> string -> int -> Yojson.Safe.t
val rename : ?overlays:(string * string) list -> ?roots:string list -> ?replacement:string -> path:string -> string -> int -> Yojson.Safe.t
