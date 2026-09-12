(** Analysis through the separately installed, unmodified [amlc.vm] library.
    Single-document [analyze] performs no filesystem access or subprocess
    execution; its optional resolver is caller-owned. Workspace entry points
    perform bounded, read-only traversal. Callers must isolate compiler work in
    a bounded worker, as with CLI analysis. *)

type syntax = Auto | Term | Callable
type span = { first : int; last : int }
(** Zero-based UTF-8 byte offsets; [last] is exclusive. Not LSP columns. *)

type diagnostic = { message : string; span : span option }
(** A missing span means that upstream did not provide a reliable location. *)

type declaration = {
  name : string;
  kind : string;
  parameters : string list;
  parameter_types : string list;
  return_type : string option;
  selection : span option;
  visibility : span list;
  uses : span list;
}
(** Lexer-verified declaration names and a partial set of verified uses.
    Uses cover checked explicit/direct form calls, dispatch-verified function
    calls and callable variable expressions, including initializers, assignments, conditions and storage
    keys/values, callable form parameters and expression-local term binders.
    Qualified enum receivers/variants and enum/struct types in callable parameter,
    return, local and declaration annotations are indexed. Expression type sites remain partial.
    [visibility] bounds parameter completion to the body and local completion
    after initialization, ending at shadowing or the function's closing brace.
    Disjoint intervals restore an outer binding after a [for] body. A scoped
    binding shadowed by [if]/[while]/[match] is suppressed where upstream's
    scope and codegen stages disagree; branch locals stay within their bodies.
    A scoped symbol without any intervals is not a completion candidate. This is
    not a complete reference/rename index. Unchecked/recovered scoped candidates
    have no selection or uses and must be used only for completion. Recovery
    never changes diagnostics and may include the EOF cursor in visibility. *)

type status = Checked | Needs_imports of string list | Input_too_large
type member_site = { member_start : int; member_end : int; items : (string * string * int) list }
(** Inclusive UTF-8 cursor interval with completion-only label/type/LSP-kind items. *)

type signature_site = { signature_start : int; signature_end : int; signature_name : string;
  signature_parameters : (string * string) list; signature_return : string; parameter : int }
(** Inclusive UTF-8 cursor interval with parsed, dispatch-filtered signature
    metadata. This is editor guidance, not proof that arguments typecheck. *)

type analysis = {
  status : status;
  diagnostics : diagnostic list;
  declarations : declaration list;
  members : member_site list;
  signatures : signature_site list;
  (* Checked line/prefix-width/brace-depth layout. None forbids edits. *)
  formatting : (int * int * int) list option;
}

val analyze : ?syntax:syntax -> ?resolve:(string -> string option) -> string -> analysis
(** Checks a single source document, up to 1 MB. [Auto] uses upstream's source
    classifier. Without [resolve], imports are explicitly deferred. With it,
    upstream checks direct interface imports; the caller must bound reads and
    enforce its filesystem policy. The resolver receives raw import paths.
    [Checked] means checking was attempted, not that the source is valid or
    that every declaration has a precise source range. *)

val workspace_references : overlays:(string * string) list -> roots:string list ->
  path:string -> string -> int -> Yojson.Safe.t
val workspace_rename : overlays:(string * string) list -> roots:string list ->
  ?replacement:string -> path:string -> string -> int -> Yojson.Safe.t
(** Bounded, read-only workspace queries for verified interface declarations,
    imports and [implements] sites beneath the supplied roots.
    Rename returns null unless the complete scan and every rewritten parse are
    safe. Open-document overlays take precedence over disk. *)
