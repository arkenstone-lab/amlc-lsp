# Third-party notices

## AMLC

The default LSP links against the unmodified `amlc.vm` library from the separate
AMLC dependency. OPAM declares that dependency; Nix builds the official source
at commit `db1080cae60e4ffbbfa31b3f94dfbd0a974573e9` without patches. The LSP
package does not install a private AMLC executable or `rehovot-check` helper.
Native linking can include AMLC code in the LSP binary, so its notice is retained.

The explicitly selected legacy regression environment applies
`amlc-editor-interface.patch`; this is not the default package build. AMLC and
that derived patch are subject to the following BSD 3-Clause notice.

```text
BSD 3-Clause License

Copyright (c) 2023-2026, Octra Labs <dev@octra.org>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

AMLC's inclusion does not imply endorsement by Octra Labs or its contributors.

## Octra Lite Node compiler components

`rehovot-check` reuses compiler components from Octra Labs' Lite Node commit
`9e7ee19af38ba020497566ac73c268f42b20b9a4`: the language model, lexer, parser,
scope resolver, type checker, form checker, verifier, AML core/checking modules,
and runtime limits. These components are covered by the Octra Labs BSD
3-Clause notice reproduced above; the helper is not an independently authored
replacement for that compiler.

The local `rehovot-form-types.patch` modifies the reused checking code.
`scripts/prepare-form-check` extracts the form-checking portion and the runtime
call-depth limit from their original modules. The CLI, import graph, and editor
query integration are maintained in this repository. Reusing or modifying
Octra Labs code does not transfer its copyright to this project's authors.

These components belong to the legacy comparison tools, not the default
library-backed LSP package. The separate Nix helper output and explicitly
opted-in standalone helper installer include this notice too. Their inclusion
does not imply endorsement by Octra Labs or its contributors.
