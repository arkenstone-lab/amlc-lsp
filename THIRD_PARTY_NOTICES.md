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

## Native release archives

The platform archives used by the Zed extension contain code linked from OCaml
4.14.2 and Zarith 1.14. Both projects use the LGPL with an explicit exception
that permits an executable linked with an unmodified, publicly distributed
version to be distributed under terms of the executable author's choice. Their
complete license texts and exceptions are available in the corresponding
sources:

- OCaml 4.14.2: <https://github.com/ocaml/ocaml/blob/4.14.2/LICENSE>
- Zarith 1.14: <https://github.com/ocaml/Zarith/blob/release-1.14/LICENSE>

Each native archive also carries a dynamically linked GMP 6.3.0 shared library
under the LGPLv3-or-later/GPLv2 dual license. The macOS and Linux libraries are
built from the unmodified upstream source archive. The Windows library is from
the official MSYS2 `mingw-w64-x86_64-gmp` 6.3.0-2 package, whose source archive
contains the upstream source, packaging recipe, and applied patches. Every
native archive includes its exact corresponding source archive in `source/`.
The executable resolves GMP beside itself so that the library remains
replaceable. Upstream GMP source and release signatures are also published at
<https://gmplib.org/download/gmp/>.

The native executable includes the following permissively licensed OCaml
libraries. Their required notices are reproduced here.

### Yojson 3.0.0 (BSD 3-Clause)

```text
Copyright (c) 2010-2012, Martin Jambon
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
* Neither the name of  nor the names of its contributors may be used to endorse
  or promote products derived from this software without specific prior
  written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### ocaml-base64 3.5.2 (ISC)

```text
Copyright (c) 2006-2009 Citrix Systems Inc.
Copyright (c) 2010 Thomas Gazagnaire <thomas@gazagnaire.com>

Permission to use, copy, modify, and distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
```

### Digestif 1.3.0 (MIT)

```text
Copyright (c) 2014 oklm-wsh

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

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
