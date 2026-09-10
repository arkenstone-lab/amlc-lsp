# Official AMLC adapter

This library adapts the separately installed `amlc` package. It calls the public
`amlc.vm` library without downloading, patching, copying, or spawning a private
compiler. It is not a helper executable.

The default launcher uses the real LSP transport and bounded diagnostic workers
on POSIX systems. Because OCaml 4.14 does not provide `fork` on native Windows,
the server launches itself as a bounded, one-shot official-library worker after
each protocol frame. It never enables the external-compiler legacy analyzer.
Plain Dune, OPAM and Nix builds all select this official-library implementation.
Only the explicit Dune `legacy` profile retains the old launcher for comparisons
(use the Nix `legacy` shell to provide its old checkers). Release packaging and
registry publication remain separate from this implementation.

With unmodified `amlc` installed in the active OCaml environment:

```sh
dune build @amlc_adapter/runtest @amlc_adapter/official-lsp-smoke
dune exec amlc-lsp
```

To test the actual install layout without changing the active switch, choose
an empty, disposable prefix:

```sh
dune build -p amlc-lsp @install
dune install --prefix "$PWD/_build/official-install" amlc-lsp
python3 amlc_adapter/install_test.py "$PWD/_build/official-install"
```

This installs the library-backed server and adapter notes, without private
compiler/helper executables. It does not install AMLC itself: for this Dune-only
test, the separately installed `amlc` package must already be available. The
root OPAM metadata applies that dependency policy when installing this checkout.
The normal development and release profiles select the same launcher. No custom
profile flag or option ordering is required to avoid the old implementation.

An install smoke test is not a portable-release test. The audited macOS ARM64
build links GMP from its build environment. A standalone editor download must
separately verify native library availability on a clean target system; do not
ship this development binary as a self-contained editor release asset.

The currently audited upstream package (`0.1.0~preview`, commit `db1080ca`)
requires OCaml 4.14.2 in its OPAM definition. It is not currently registered
in the public OPAM repository; install its official source into an isolated
switch before running these tests. Alternatively, the default Nix shell now
provides unmodified AMLC; its `legacy` shell supplies the patched test baseline.

The adapter exposes parsed program/function/form metadata and lexer-verified
declaration name ranges. It preserves compiler-provided locations as UTF-8 byte
offsets; errors without reliable ranges remain unlocated. Its optional resolver
uses upstream's direct interface imports, not function imports or recursive
module linking. Without a resolver, imported documents return `Needs_imports`.

To test it in an editor, use the absolute path to
`_build/default/amlc_adapter/server.exe`. It supports push diagnostics, declaration
and keyword completion, document symbols, folding, and selection ranges. It does
not invoke `amlc` or `rehovot-check` subprocesses, even if overrides are set. It
uses the library selected at build time, not an executable subsequently found on
PATH.

The launcher resolves imports beneath the main document's directory, with open
buffers taking precedence over disk. Reads are limited to 32 imports, 1 MB per
source, and 8 MB total; non-regular files and paths outside that directory are
rejected. Import changes invalidate dependent diagnostics. Missing or rejected
sources produce compiler errors, not a silently successful check.

Definition/declaration lookup supports declaration names and verified, same-file
function calls inside initializers, nested arguments, assignments, conditions
and returned expressions. The
adapter combines statement locations, lexer tokens, and upstream call dispatch;
it does not treat comments, same-named variables, or builtins as function uses.
Dispatch probes use declared parameter types after the original document has
passed checking, so locally inferred call arguments do not prevent navigation.
They are cached per function name within one analysis. Failed checking
discards call mappings, and document changes invalidate cached results.

Hover uses those same verified positions and shows compiler-provided parameter
and return types. Untyped local bindings display their name without a fabricated
inferred type. A same-named comment or unindexed variable does not receive a
function's hover text.

Parameters and local `let`/`for` declarations also support
lookup from checked expression uses: initializers, return operands, call arguments,
assignments, conditions, assertions and storage keys/values. An exact ordered
match between AST variable roles and original lexer tokens supplies ranges;
comments, field names and call names are not local-variable uses.
Constructor bodies use the same parameter/local scope and function-call indexing.
Forms in callable documents also index typed capture/argument parameters and
expression-local bindings, with body-only completion and shadow restoration.
Checked explicit `use` and permitted direct form calls also resolve to their
same-file declaration, including calls inside forms and constructors. Original
compiler checks determine whether direct calls are permitted; same-named variables
and comments are not form references. The separate term syntax remains unindexed
for parameters/calls, and the overall reference index is still incomplete.
Pure-function calls inside forms use the term checker's resolution. Where form
linking promotes a pure function ahead of a same-named builtin, ordinary-call
navigation also uses the official linked call set; removing the form invalidates
that resolution with the rest of the document analysis.
The constructor appears in the outline with its parameter signature, but is not
offered as an ordinary callable function in completion.
Bindings are tracked in statement order. Flat tuple destructuring verifies each
name against the parser's ordered binding list; initializer uses retain the old
environment and subsequent uses/completion select the new bindings. Loop exits
restore shadowed outer bindings. Tuple locals display their names without guessed
inferred types. Unmatched declaration locations still block misleading lookup.
`if`/`else if` and `match` bodies have separate completion ranges, including
single-statement match arms. Their local declarations do not become candidates
in sibling branches or after the statement. Names shadowed by any branch block
outer-binding navigation from the first body onward: upstream emits `else`
before `then` and retains branch locals, unlike its scope stage.
`while` bodies are indexed in statement order. Body declarations remain inside
the body for completion. If they shadow an outer binding, that outer binding is
suppressed from the while condition onward: upstream emits the condition after
the body and retains its locals, so restoring the outer declaration would give
misleading navigation. Unshadowed parameters and locals remain available.
Range and state-list `for` loops restore locals in both stages and are indexed,
including nested loops. Iterators use the official integer or list-element type.
Local completion is bounded by the next token after initialization, shadowing
and the enclosing block's closing brace, using the official parser's boundaries. The
previous binding remains available inside a replacement initializer. Visible
parameters and locals take precedence over same-named globals/keywords and never
leak into another function. Disjoint visibility intervals let an outer binding
resume after a loop that temporarily shadows it. Parameter names are verified within the official
parser's header range, including tuple types and `where` refinements; completion
starts at the function body. Scoped symbols remain excluded from outlines.
Term-expression `let`, `split`, `orbit` and `use` preserve outer-variable
navigation in inputs and free body uses. Their own typed declarations and bound
uses support definition/declaration lookup, hover and semantic highlighting,
including nested same-named bindings and scope restoration after the expression.
They are excluded from document outlines. Cursor completion uses their parsed
body ranges, hides same-named outer bindings only within those ranges and restores
them after the expression. Incomplete bodies immediately after `in` or `=>` can
retain declared binder types through bounded parser-only recovery; original
diagnostics remain. At recovered EOF, the innermost matching scope wins.
Function calls inside these expressions and typed equality
are mapped through the same checked dispatch. Unmatched token roles remain
unindexed rather than being assigned to a same-named enclosing declaration.
Only declarations with a complete verified occurrence set can drive rename.

References returns verified occurrences of the selected declaration in the same
checked document and honors `includeDeclaration`. Same-file rename uses the same
occurrence set and rejects invalid or reserved identifiers, collisions and any
same-spelled identifier omitted from all compiler occurrences. Both reuse the
bounded analysis queue, including cancellation and document-version invalidation.
Comments and same-named declarations in other scopes are excluded. Invalid or
not-yet-checked documents return no matches or edits.

For interface symbols, a bounded workspace index connects the declaration with
matching `import` and `implements` tokens in open and unopened `.aml` files.
Workspace rename requires a complete scan, unchanged source hashes, successful
checks after rewriting, paths beneath a workspace root and client support for
versioned `documentChanges`. An incomplete scan may return its verified reference
subset but cannot produce rename edits. Official AMLC imports interfaces rather
than public functions, so function references and rename remain same-file.

Full semantic-token requests color verified declaration/use ranges as types,
functions, parameters or variables. They reuse the versioned worker cache and
bounded request queue. Unindexed names, invalid scoped bindings, comments and
lexical tokens remain under the editor's grammar highlighting; no name-search
fallback invents semantic roles. This does not imply a complete reference index.

Signature help uses lexer-verified call contexts and dispatch-filtered function
and form declarations. Direct form calls require the official form checker's
direct-call classification. Explicit `use form[captures](argument)` keeps capture
and argument positions separate, including unfinished lists and comments between
them; forms requiring explicit use do not gain direct-call signatures.
It handles unfinished calls, nested calls, grouping and collection
delimiters without counting commas inside strings/comments. Signatures include
parameter types and the active parameter; they guide editing without suppressing
diagnostics or asserting that the current arguments typecheck. Unknown/builtin
calls do not borrow a same-named user signature. Results follow the same bounded,
document-versioned worker cache as other analysis.
Completion, signature, formatting, semantic-token, hover, navigation, outline and
explicit diagnostic requests missing analysis wait asynchronously for up to two
seconds, with at most 64 queued requests. They expedite a pending
check without blocking the transport or restarting an active worker. Cancellation,
document/version changes, dialect changes and shutdown clear affected requests.
At the deadline or queue limit, normal incomplete/empty fallback responses remain
possible. Dot completion is advertised; `(`, `,` and `[` trigger signature help.
The six feature caches share a 64-snapshot recency order. Updating a full cache
evicts only the oldest unused snapshot, not all documents; later requests can
rebuild an evicted snapshot through the same bounded queue.

Formatting adjusts only leading indentation in successfully checked callable or
term documents, using each syntax's official lexer and the client's spaces/tabs setting
(tab sizes 1–16). It returns separate line edits, preserving trailing whitespace,
line endings, blank lines and multiline string/comment lines. Invalid/recovered
documents receive no edits. Term comment-prefixed lines are also left untouched:
their lexer represents comments as token gaps. The output must remain within the
server's 1 MB source limit. This is indentation formatting, not expression reflow
or a trailing-whitespace cleanup tool; no compiler subprocess is invoked.

Member completion uses original-source lexer sites and official state/struct/enum
metadata. It covers `self.field`, nested struct storage paths, list/map `length`,
and `Enum.variant`, including unfinished field names. Unknown receivers suppress
unrelated keywords/locals. Comments and strings do not create member sites;
member data follows the same document-version cache invalidation as diagnostics.
Up to 4096 sites are retained per source, with shared completion lists for repeated
paths. Bracketed state keys preserve the receiver, including nested key expressions
and multiple keys; the leaf type follows upstream storage-path resolution.
Root state-list statements offer `push(value)`, `delete(index)`, `len()` and
`pop()`, with the declared element type for `push`. Parser statement locations
distinguish these from expression receivers, which offer `length` instead.
Bounded recovery retains this distinction for unfinished `self` statements;
method suggestions do not make an invalid call typecheck or provide call-value
semantics. Indexing after an already selected struct field is not implemented.

Enum declarations and qualified variants also support same-file navigation and
hover after successful checking, including match patterns and distinct owners
with identically named variants. Their outline kinds distinguish enums from
members; unqualified completion offers the enum type, not its variants. Callable
parameter/return types and local binding annotations also resolve to enum
declarations, including nested named types. The official type parser determines
their boundaries; following refinements and same-named variables/functions do not
become type references. AST-matched state, struct, event, constant and interface
declarations use the same type parser. Event modifiers and form effect labels
are not type references. Expression type sites and cross-file completeness still
need review; this remains a partial reference index.

Struct declarations use the same checked type-reference index for navigation and
hover, including nested struct/state types and interface signatures. They appear
as structs in completion and outlines, not functions. This does not add nested
struct-field reference tracking or local struct-value member semantics.

Root state declarations and checked `self.field` occurrences support navigation,
typed hover and property semantic tokens. Reads, assignments and indexed receivers
resolve to the state declaration, independently of same-named local bindings.
State fields appear in outlines but not unqualified completion. Comments, strings,
nested struct-field suffixes and form effect targets are not state references;
failed checking clears use mappings.

Ordinary
`name.member` is parsed by upstream as an enum access, not local struct-variable
access; the old helper's local-member semantics are not emulated. These candidates
do not supply nested struct-field navigation or reference/rename ranges.

Completion can retain parsed parameters/locals after a checking error. For a
callable parse error, bounded recovery tries at most eight parser inputs: missing
delimiters may be closed and an unfinished statement masked within its real
block. Later functions and byte offsets are preserved. Recovered input is never
compiled and never resolves imports; the original diagnostics stay visible.
Candidates have no navigation/hover ranges and the completion list is marked
incomplete so clients request fresh results while typing. This covers common
unfinished returns and initializers, not arbitrary malformed syntax. Lexer
errors (including unclosed strings/comments), mismatched delimiters and nesting
beyond 128 levels disable recovery.

Quick fixes are limited to compiler-reported missing `)`, `}`, `]`, `,`, `in`,
`then`, `else` and `:` tokens. A candidate insertion is re-analyzed, and the code
action must match a diagnostic from the current document snapshot. Other errors
receive diagnostics without speculative edits.

Unlocated errors use a document-start anchor with an explanatory message, not an
invented precise range. Single-document checks run in the existing cancellable
worker without temporary source files. Workspace scans are synchronous but
bounded by roots, entry count, depth, source count and total bytes; rename is
rejected whenever those bounds prevent a complete result.

Native linking normally includes used library code in the resulting executable.
It avoids a second compiler installation, not third-party licensing obligations.
