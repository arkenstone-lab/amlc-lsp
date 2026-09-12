type candidate = { text : string; eof_anchor : bool }

val candidates : ?before:int -> string -> candidate list
(** At most eight offset-preserving callable parser inputs. A trailing statement
    may be masked up to its real block end and missing delimiters closed.
    A synthetic bare return anchors visibility after retained bindings, without
    inventing an initializer or declaration. [eof_anchor] marks its virtual
    position one byte past the original EOF.
    [before] limits cut points to those before the original error byte offset.
    Lexer errors, mismatched
    delimiters and nesting beyond 128 levels disable recovery. Never compile
    these inputs or use them to replace diagnostics for the original source. *)
