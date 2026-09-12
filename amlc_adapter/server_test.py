"""Real LSP requests against the official-library server."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time


def main():
    server = str(Path(sys.argv[1]).resolve())
    env = dict(os.environ, AMLC="/must-not-run-amlc",
               REHOVOT_CHECK="/must-not-run-rehovot")
    # Native Windows resolves OCaml package DLLs through PATH. On POSIX, an
    # empty PATH additionally proves that the official adapter spawns no tool.
    if os.name != "nt":
        env["PATH"] = ""
    with tempfile.TemporaryDirectory(prefix="amlc-official-lsp-") as directory:
        root = Path(directory)
        worker_request = root / "worker-request.json"
        worker_response = root / "worker-response.bin"
        worker_request.write_text(json.dumps({
            "uri": (root / "worker.aml").as_uri(),
            "text": "program Worker { fn run(): int { return 1 } }",
        }))
        subprocess.run(
            [server, "--amlc-lsp-analysis-worker", str(worker_request), str(worker_response)],
            env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert 0 < worker_response.stat().st_size < 4_100_000
        worker_request.unlink()
        worker_response.unlink()
        process = subprocess.Popen([server], env=env, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        messages = queue.Queue()
        document_versions = {}

        def read():
            try:
                while True:
                    headers = {}
                    while True:
                        line = process.stdout.readline()
                        if not line:
                            raise EOFError("server closed stdout")
                        if line == b"\r\n":
                            break
                        key, value = line.decode().split(":", 1)
                        headers[key.lower()] = value.strip()
                    messages.put(json.loads(process.stdout.read(int(headers["content-length"]))))
            except Exception as error:
                messages.put(error)

        threading.Thread(target=read, daemon=True).start()

        def send(method, params=None, request_id=None):
            if method in {"textDocument/didOpen", "textDocument/didChange"}:
                document = params["textDocument"]
                document_versions[document["uri"]] = document["version"]
            elif method == "textDocument/didClose":
                document_versions.pop(params["textDocument"]["uri"], None)
            value = {"jsonrpc": "2.0", "method": method}
            if params is not None:
                value["params"] = params
            if request_id is not None:
                value["id"] = request_id
            payload = json.dumps(value).encode()
            process.stdin.write(f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload)
            process.stdin.flush()

        def receive(predicate):
            deadline = time.monotonic() + 20
            while True:
                message = messages.get(timeout=max(0, deadline - time.monotonic()))
                if isinstance(message, Exception):
                    raise message
                if predicate(message):
                    return message

        def response(request_id):
            return receive(lambda m: m.get("id") == request_id)

        def diagnostics(uri):
            version = document_versions.get(uri)
            return receive(lambda m: m.get("method") == "textDocument/publishDiagnostics"
                           and m["params"]["uri"] == uri
                           and (version is None or m["params"].get("version") == version)
                           )["params"]["diagnostics"]

        def utf16_column(text, offset):
            return len(text[:offset].encode("utf-16-le")) // 2

        def open_document(name, source, path=None):
            # The parent directory deliberately does not exist. Analysis of an
            # unsaved buffer must not write temporary compiler input beside it.
            uri = (path or root / "unsaved" / name).as_uri()
            send("textDocument/didOpen", {"textDocument": {
                "uri": uri, "languageId": "aml", "version": 1, "text": source}})
            return uri, diagnostics(uri)

        try:
            send("initialize", {"rootUri": root.as_uri(), "capabilities": {
                "workspace": {"workspaceEdit": {"documentChanges": True}}
            }}, 1)
            initialized = response(1)["result"]
            caps = initialized["capabilities"]
            assert "completionProvider" in caps, caps
            assert caps["completionProvider"]["triggerCharacters"] == ["."], caps
            assert caps["documentSymbolProvider"] is True, caps
            assert caps["definitionProvider"] is True, caps
            assert caps["hoverProvider"] is True, caps
            assert caps["signatureHelpProvider"]["triggerCharacters"] == ["(", ",", "["], caps
            assert caps["documentFormattingProvider"] is True, caps
            assert caps["semanticTokensProvider"]["full"] is True, caps
            assert caps['referencesProvider'] is True
            assert caps['renameProvider']['prepareProvider'] is True
            assert caps['codeActionProvider'] is True
            send("initialized", {})

            quick_fix_text = 'program Fix { fn run(): int { return (1 + 2 } }'
            quick_fix_uri, quick_fix_diagnostics = open_document('quick-fix.aml', quick_fix_text)
            assert len(quick_fix_diagnostics) == 1, quick_fix_diagnostics
            quick_fix_diagnostic = quick_fix_diagnostics[0]
            assert quick_fix_diagnostic['code'] == 'AMLC101', quick_fix_diagnostic
            send('textDocument/codeAction', {
                'textDocument': {'uri': quick_fix_uri},
                'range': quick_fix_diagnostic['range'],
                'context': {'diagnostics': [quick_fix_diagnostic]},
            }, 2500)
            actions = response(2500)['result']
            assert len(actions) == 1 and actions[0]['kind'] == 'quickfix', actions
            assert actions[0]['edit']['changes'][quick_fix_uri][0]['newText'] == ')', actions
            forged = dict(quick_fix_diagnostic, range={
                'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 0}})
            send('textDocument/codeAction', {
                'textDocument': {'uri': quick_fix_uri}, 'range': forged['range'],
                'context': {'diagnostics': [forged]},
            }, 2501)
            assert response(2501)['result'] == [], 'quick fix trusted a stale or forged diagnostic'

            def semantic_ranges(uri, source, request_id):
                send("textDocument/semanticTokens/full", {"textDocument": {"uri": uri}}, request_id)
                data = response(request_id)["result"]["data"]
                assert len(data) % 5 == 0, data
                line = column = 0
                previous_end = (-1, -1)
                ranges = []
                legend = caps["semanticTokensProvider"]["legend"]["tokenTypes"]
                for offset in range(0, len(data), 5):
                    line_delta, column_delta, width, kind, modifiers = data[offset:offset + 5]
                    assert line_delta >= 0 and column_delta >= 0 and width > 0 and modifiers == 0
                    line += line_delta
                    column = column + column_delta if line_delta == 0 else column_delta
                    assert (line, column) >= previous_end, "overlapping semantic tokens"
                    encoded = source.splitlines()[line].encode("utf-16-le")
                    name = encoded[column * 2:(column + width) * 2].decode("utf-16-le")
                    assert len(name.encode("utf-16-le")) == width * 2
                    ranges.append((line, column, name, legend[kind]))
                    previous_end = (line, column + width)
                return ranges

            semantic_text = ('/* 😀 inc n value */ program Colors {\n'
                             'fn inc(n: int): int { let value = n return value }\n'
                             'fn run(inc: int): int { return inc }\n'
                             'fn call(): int { return inc(1) } }')
            semantic_uri = (root / "semantic.aml").as_uri()
            send("textDocument/didOpen", {"textDocument": {
                "uri": semantic_uri, "languageId": "aml", "version": 1, "text": semantic_text}})
            colored = semantic_ranges(semantic_uri, semantic_text, 2600)
            assert colored == [
                (0, utf16_column(semantic_text.splitlines()[0], semantic_text.index("Colors")), "Colors", "type"),
                (1, 3, "inc", "function"), (1, 7, "n", "parameter"),
                (1, 26, "value", "variable"), (1, 34, "n", "parameter"),
                (1, 43, "value", "variable"),
                (2, 3, "run", "function"), (2, 7, "inc", "parameter"),
                (2, 31, "inc", "parameter"),
                (3, 3, "call", "function"), (3, 24, "inc", "function"),
            ], colored
            invalid_semantic = 'program Colors { fn run(n: int): int { let missing = } }'
            send("textDocument/didChange", {"textDocument": {"uri": semantic_uri, "version": 2},
                 "contentChanges": [{"text": invalid_semantic}]})
            invalid_colors = semantic_ranges(semantic_uri, invalid_semantic, 2601)
            assert all(kind not in ("parameter", "variable") for _, _, _, kind in invalid_colors), invalid_colors
            send("textDocument/didClose", {"textDocument": {"uri": semantic_uri}})
            assert semantic_ranges(semantic_uri, invalid_semantic, 2602) == []

            binder_text = ('/* 😀 n */ program Bindings { pure fn inc(x: int): int { return x + 1 } '
                           'fn run(n: int): int { return (let many n: int = inc(n) in inc(n)) + n } }')
            binder_uri, items = open_document('term-bindings.aml', binder_text)
            assert items == [], items
            outer_position = utf16_column(binder_text, binder_text.index('run(n:') + len('run('))
            function_position = utf16_column(binder_text, binder_text.index('inc(x:'))
            first_call = binder_text.index('inc(n)')
            second_call = binder_text.index('inc(n)', first_call + 1)
            binder_position = utf16_column(binder_text, binder_text.index('many n:') + len('many '))
            for index, (offset, target, width) in enumerate([
                (first_call + 4, outer_position, 1),
                (second_call + 4, binder_position, 1),
                (binder_text.index('many n:') + len('many '), binder_position, 1),
                (binder_text.rindex('+ n') + 2, outer_position, 1),
                (second_call, function_position, 3),
            ]):
                send('textDocument/definition', {'textDocument': {'uri': binder_uri},
                     'position': {'line': 0, 'character': utf16_column(binder_text, offset)}}, 2800 + index)
                targets = response(2800 + index)['result']
                expected = [] if target is None else [{'uri': binder_uri, 'range': {
                    'start': {'line': 0, 'character': target},
                    'end': {'line': 0, 'character': target + width}}}]
                assert targets == expected, (offset, targets)
            send('textDocument/hover', {'textDocument': {'uri': binder_uri}, 'position': {
                 'line': 0, 'character': utf16_column(binder_text, second_call + 4)}}, 2810)
            assert response(2810)['result']['contents']['value'] == 'let n: int'
            invalid_binder = binder_text.replace('inc(n)', 'inc(true)', 1)
            completion_text = 'program P { fn run(n: int): int { return if (let many n: bool = true in n) then n else n } }'
            completion_uri, items = open_document('term-completion.aml', completion_text)
            assert items == [], items
            for index, (marker, detail) in enumerate([('true', 'n: int'), ('in n', 'let n: bool'), ('then n', 'n: int')]):
                offset = completion_text.index(marker) + (len(marker) - 1 if marker != 'true' else 0)
                send('textDocument/completion', {'textDocument': {'uri': completion_uri}, 'position': {
                     'line': 0, 'character': offset}}, 2820 + index)
                names = [item for item in response(2820 + index)['result']['items'] if item['label'] == 'n']
                assert len(names) == 1 and names[0]['detail'] == detail, (marker, names)
            unfinished_body = 'program P { fn run(n: int): bool { return let many n: bool = true in'
            send('textDocument/didChange', {'textDocument': {'uri': completion_uri, 'version': 2},
                 'contentChanges': [{'text': unfinished_body}]})
            send('textDocument/completion', {'textDocument': {'uri': completion_uri}, 'position': {
                 'line': 0, 'character': len(unfinished_body)}}, 2829)
            names = [item for item in response(2829)['result']['items'] if item['label'] == 'n']
            assert len(names) == 1 and names[0]['detail'] == 'let n: bool', names

            send('textDocument/didChange', {'textDocument': {'uri': binder_uri, 'version': 2},
                 'contentChanges': [{'text': invalid_binder}]})
            assert diagnostics(binder_uri), 'invalid term initializer lost compiler diagnostics'
            send('textDocument/definition', {'textDocument': {'uri': binder_uri}, 'position': {
                 'line': 0, 'character': utf16_column(invalid_binder, invalid_binder.index('inc(n)') + 4)}}, 2811)
            assert response(2811)['result'] == [], 'stale expression-local binding survived failed checking'

            form_text = ('/* 😀 value use identity */ program P { form identity [] (many value: int) '
                         '->[many] int marks {} = (let many value: int = value in value) + value '
                         'fn run(identity: int): int { return use identity[](identity) as many result: int in identity(result) } }')
            form_uri, items = open_document('form-bindings.aml', form_text)
            assert items == [], items
            for index, (marker, declaration) in enumerate([
                ('value in', form_text.index('value: int')),
                ('value) +', form_text.index('value: int', form_text.index('let many'))),
                ('value fn', form_text.index('value: int')),
            ]):
                position = {'line': 0, 'character': utf16_column(form_text, form_text.index(marker))}
                send('textDocument/definition', {'textDocument': {'uri': form_uri}, 'position': position}, 3100 + index)
                column = utf16_column(form_text, declaration)
                assert response(3100 + index)['result'] == [{'uri': form_uri, 'range': {
                    'start': {'line': 0, 'character': column}, 'end': {'line': 0, 'character': column + 5}}}]
                send('textDocument/completion', {'textDocument': {'uri': form_uri}, 'position': position}, 3110 + index)
                candidates = [item for item in response(3110 + index)['result']['items'] if item['label'] == 'value']
                assert len(candidates) == 1, candidates
            for index, (use, declaration, hover) in enumerate([
                (form_text.rindex('use identity') + 4, form_text.index('form identity') + 5, 'identity(value: int) -> int'),
                (form_text.index('[](identity)') + 3, form_text.index('identity: int'), 'identity: int'),
                (form_text.index('in identity') + 3, form_text.index('form identity') + 5, 'identity(value: int) -> int'),
            ]):
                position = {'line': 0, 'character': utf16_column(form_text, use)}
                send('textDocument/definition', {'textDocument': {'uri': form_uri}, 'position': position}, 3130 + index)
                column = utf16_column(form_text, declaration)
                assert response(3130 + index)['result'] == [{'uri': form_uri, 'range': {
                    'start': {'line': 0, 'character': column}, 'end': {'line': 0, 'character': column + 8}}}]
                send('textDocument/hover', {'textDocument': {'uri': form_uri}, 'position': position}, 3140 + index)
                assert response(3140 + index)['result']['contents']['value'] == hover
            send('textDocument/definition', {'textDocument': {'uri': form_uri}, 'position': {
                 'line': 0, 'character': utf16_column(form_text, form_text.index('use identity') + 4)}}, 3150)
            assert response(3150)['result'] == [], 'comment became a form use'
            invalid_form = form_text.replace('+ value fn', '+ true fn')
            send('textDocument/didChange', {'textDocument': {'uri': form_uri, 'version': 2},
                 'contentChanges': [{'text': invalid_form}]})
            assert diagnostics(form_uri), 'invalid form lost compiler error'
            send('textDocument/definition', {'textDocument': {'uri': form_uri}, 'position': {
                 'line': 0, 'character': utf16_column(invalid_form, invalid_form.index('value in'))}}, 3120)
            assert response(3120)['result'] == [], 'invalid form retained stale parameter navigation'
            send('textDocument/definition', {'textDocument': {'uri': form_uri}, 'position': {
                 'line': 0, 'character': utf16_column(invalid_form, invalid_form.rindex('use identity') + 4)}}, 3151)
            assert response(3151)['result'] == [], 'invalid form retained stale form-call navigation'

            linked_pure = ('program P { pure fn abs(value: int): int { return value + 1 } '
                           'form relay [] (many seed: int) ->[many] int marks {} = abs(seed) '
                           'fn run(): int { return abs(1) } }')
            linked_uri, items = open_document('linked-pure.aml', linked_pure)
            assert items == [], items
            for index, marker in enumerate(('abs(seed)', 'abs(1)')):
                send('textDocument/definition', {'textDocument': {'uri': linked_uri}, 'position': {
                     'line': 0, 'character': linked_pure.index(marker)}}, 3160 + index)
                column = linked_pure.index('abs(value')
                assert response(3160 + index)['result'] == [{'uri': linked_uri, 'range': {
                    'start': {'line': 0, 'character': column}, 'end': {'line': 0, 'character': column + 3}}}]
            unlinked_pure = linked_pure[:linked_pure.index('form relay')] + linked_pure[linked_pure.index('fn run'):]
            send('textDocument/didChange', {'textDocument': {'uri': linked_uri, 'version': 2},
                 'contentChanges': [{'text': unlinked_pure}]})
            assert diagnostics(linked_uri) == [], 'removing form should retain a valid builtin call'
            send('textDocument/definition', {'textDocument': {'uri': linked_uri}, 'position': {
                 'line': 0, 'character': unlinked_pure.index('abs(1)')}}, 3162)
            assert response(3162)['result'] == [], 'removed form left stale promoted-function navigation'

            enum_text = ('/* 😀 Mode.Ready */ interface I { fn get(value: Mode): Mode } '
                         'program P { enum Mode { Ready } enum Other { Ready } '
                         'struct Box { field: Mode } state { current: Mode } event Changed(value: indexed Mode) '
                         'const Selected: Mode = Mode.Ready '
                         'constructor(seed: Mode) {} fn run(mode: Mode): Mode { let other: Other = Other.Ready return Mode.Ready } }')
            enum_uri, items = open_document('enum-navigation.aml', enum_text)
            assert items == [], items
            for index, (use, declaration, name, hover) in enumerate([
                (enum_text.rindex('Mode.Ready'), enum_text.index('enum Mode') + 5, 'Mode', 'enum Mode'),
                (enum_text.rindex('Mode.Ready') + 5, enum_text.index('{ Ready') + 2, 'Ready', 'Mode.Ready'),
                (enum_text.index('Other.Ready') + 6, enum_text.index('{ Ready', enum_text.index('enum Other')) + 2, 'Ready', 'Other.Ready'),
                (enum_text.index('seed: Mode') + 6, enum_text.index('enum Mode') + 5, 'Mode', 'enum Mode'),
                (enum_text.index('mode: Mode') + 6, enum_text.index('enum Mode') + 5, 'Mode', 'enum Mode'),
                (enum_text.index('): Mode') + 3, enum_text.index('enum Mode') + 5, 'Mode', 'enum Mode'),
                (enum_text.index('other: Other') + 7, enum_text.index('enum Other') + 5, 'Other', 'enum Other'),
                (enum_text.index('value: Mode') + 7, enum_text.index('enum Mode') + 5, 'Mode', 'enum Mode'),
                (enum_text.index('field: Mode') + 7, enum_text.index('enum Mode') + 5, 'Mode', 'enum Mode'),
                (enum_text.index('current: Mode') + 9, enum_text.index('enum Mode') + 5, 'Mode', 'enum Mode'),
                (enum_text.index('indexed Mode') + 8, enum_text.index('enum Mode') + 5, 'Mode', 'enum Mode'),
                (enum_text.index('Selected: Mode') + 10, enum_text.index('enum Mode') + 5, 'Mode', 'enum Mode'),
            ]):
                position = {'line': 0, 'character': utf16_column(enum_text, use)}
                send('textDocument/definition', {'textDocument': {'uri': enum_uri}, 'position': position}, 3300 + index)
                column = utf16_column(enum_text, declaration)
                assert response(3300 + index)['result'] == [{'uri': enum_uri, 'range': {
                    'start': {'line': 0, 'character': column}, 'end': {'line': 0, 'character': column + len(name)}}}]
                send('textDocument/hover', {'textDocument': {'uri': enum_uri}, 'position': position}, 3350 + index)
                assert response(3350 + index)['result']['contents']['value'] == hover
            send('textDocument/documentSymbol', {'textDocument': {'uri': enum_uri}}, 3320)
            outline = response(3320)['result']
            assert {(item['name'], item['kind']) for item in outline if item['name'] in ('Mode', 'Other', 'Ready')} == {
                ('Mode', 10), ('Other', 10), ('Ready', 22)}, outline
            send('textDocument/completion', {'textDocument': {'uri': enum_uri}, 'position': {
                 'line': 0, 'character': utf16_column(enum_text, enum_text.index('return'))}}, 3321)
            items = response(3321)['result']['items']
            assert any(item['label'] == 'Mode' and item['kind'] == 13 for item in items), items
            assert not any(item['label'] == 'Ready' for item in items), 'variant leaked into unqualified completion'
            invalid_enum = enum_text.replace('return Mode.Ready', 'return Mode.Missing')
            send('textDocument/didChange', {'textDocument': {'uri': enum_uri, 'version': 2},
                 'contentChanges': [{'text': invalid_enum}]})
            assert diagnostics(enum_uri), 'missing enum variant lost compiler error'
            send('textDocument/definition', {'textDocument': {'uri': enum_uri}, 'position': {
                 'line': 0, 'character': utf16_column(invalid_enum, invalid_enum.rindex('Mode.Missing'))}}, 3322)
            assert response(3322)['result'] == [], 'invalid enum retained stale qualified navigation'
            send('textDocument/definition', {'textDocument': {'uri': enum_uri}, 'position': {
                 'line': 0, 'character': utf16_column(invalid_enum, invalid_enum.index('mode: Mode') + 6)}}, 3323)
            assert response(3323)['result'] == [], 'invalid enum retained stale type-annotation navigation'
            send('textDocument/definition', {'textDocument': {'uri': enum_uri}, 'position': {
                 'line': 0, 'character': utf16_column(invalid_enum, invalid_enum.index('current: Mode') + 9)}}, 3324)
            assert response(3324)['result'] == [], 'invalid source retained declaration-type navigation'

            struct_text = ('/* 😀 Box */ interface I { fn get(value: Box): Box } program P { '
                           'struct Box { n: int } struct Holder { box: Box } '
                           'state { boxes: map[int]Box holder: Holder } fn run(): int { return self.boxes[0].n } }')
            struct_uri, items = open_document('struct-navigation.aml', struct_text)
            assert items == [], items
            for index, marker in enumerate(('value: ', '): ', 'box: ', 'map[int]')):
                position = {'line': 0, 'character': utf16_column(struct_text, struct_text.index(marker) + len(marker))}
                send('textDocument/definition', {'textDocument': {'uri': struct_uri}, 'position': position}, 3400 + index)
                column = utf16_column(struct_text, struct_text.index('struct Box') + 7)
                assert response(3400 + index)['result'] == [{'uri': struct_uri, 'range': {
                    'start': {'line': 0, 'character': column}, 'end': {'line': 0, 'character': column + 3}}}]
                send('textDocument/hover', {'textDocument': {'uri': struct_uri}, 'position': position}, 3410 + index)
                assert response(3410 + index)['result']['contents']['value'] == 'struct Box'
            send('textDocument/documentSymbol', {'textDocument': {'uri': struct_uri}}, 3420)
            assert {item['name'] for item in response(3420)['result'] if item['kind'] == 23} == {'Box', 'Holder'}
            send('textDocument/completion', {'textDocument': {'uri': struct_uri}, 'position': {
                 'line': 0, 'character': utf16_column(struct_text, struct_text.index('return'))}}, 3421)
            assert any(item['label'] == 'Box' and item['kind'] == 22 for item in response(3421)['result']['items'])
            invalid_struct = struct_text.replace('self.boxes[0].n', 'self.boxes[0].missing')
            send('textDocument/didChange', {'textDocument': {'uri': struct_uri, 'version': 2},
                 'contentChanges': [{'text': invalid_struct}]})
            assert diagnostics(struct_uri), 'invalid struct access lost its diagnostic'
            send('textDocument/definition', {'textDocument': {'uri': struct_uri}, 'position': {
                 'line': 0, 'character': utf16_column(invalid_struct, invalid_struct.index('map[int]') + 8)}}, 3422)
            assert response(3422)['result'] == [], 'invalid struct retained type references'

            state_text = ('/* 😀 self.total */ program P { struct Box { total: int } '
                          'state { total: int boxes: map[int]Box } fn run(total: int): int { '
                          'self.total += total self.boxes[self.total].total = total return self.total + total } }')
            state_uri, items = open_document('state-navigation.aml', state_text)
            assert items == [], items
            for index, (marker, target, label) in enumerate((
                ('self.total +=', 'state { total', 'field total: int'),
                ('self.boxes[', 'int boxes', 'field boxes: map[int]Box'),
                ('self.boxes[self.total', 'state { total', 'field total: int'),
                ('return self.total', 'state { total', 'field total: int'),
                ('+= total', 'run(total', 'total: int'),
            )):
                name = 'boxes' if marker == 'self.boxes[' else 'total'
                offset = state_text.index(marker) + marker.rindex(name)
                query = {'textDocument': {'uri': state_uri}, 'position': {
                    'line': 0, 'character': utf16_column(state_text, offset)}}
                column = utf16_column(state_text, state_text.index(target) + target.rindex(name))
                send('textDocument/definition', query, 3500 + index)
                assert response(3500 + index)['result'] == [{'uri': state_uri, 'range': {
                    'start': {'line': 0, 'character': column},
                    'end': {'line': 0, 'character': column + len(name)}}}]
                send('textDocument/hover', query, 3510 + index)
                assert response(3510 + index)['result']['contents']['value'] == label
            nested_column = utf16_column(state_text, state_text.index('].total') + 2)
            send('textDocument/definition', {'textDocument': {'uri': state_uri}, 'position': {
                 'line': 0, 'character': nested_column}}, 3520)
            assert response(3520)['result'] == [], 'nested struct field resolved to root state'
            properties = [(line, column, name) for line, column, name, kind in
                          semantic_ranges(state_uri, state_text, 3521) if kind == 'property']
            assert len(properties) == 6 and (0, nested_column, 'total') not in properties, properties
            send('textDocument/completion', {'textDocument': {'uri': state_uri}, 'position': {
                 'line': 0, 'character': utf16_column(state_text, state_text.index('return'))}}, 3522)
            completions = response(3522)['result']['items']
            assert not any(item['label'] == 'boxes' for item in completions)
            assert [item['detail'] for item in completions if item['label'] == 'total'] == ['total: int']
            send('textDocument/documentSymbol', {'textDocument': {'uri': state_uri}}, 3524)
            fields = [item['name'] for item in response(3524)['result'] if item['kind'] == 8]
            assert fields == ['total', 'boxes'], fields
            invalid_state = state_text.replace('].total', '].missing')
            send('textDocument/didChange', {'textDocument': {'uri': state_uri, 'version': 2},
                 'contentChanges': [{'text': invalid_state}]})
            assert diagnostics(state_uri)
            send('textDocument/definition', {'textDocument': {'uri': state_uri}, 'position': {
                 'line': 0, 'character': utf16_column(invalid_state, invalid_state.index('self.total +=') + 5)}}, 3523)
            assert response(3523)['result'] == [], 'invalid document retained state uses'

            reference_text = ('/* 😀 value */ program P { state { value: int } '
                              'fn inc(value: int): int { return value } '
                              'fn run(value: int): int { let saved = value let value = inc(value) '
                              'self.value = value return value + saved } }')
            reference_uri, items = open_document('references.aml', reference_text)
            assert items == [], items
            for index, (name, declaration, uses) in enumerate((
                ('value', 'state { value', ['self.value']),
                ('value', 'inc(value', ['return value }']),
                ('value', 'run(value', ['saved = value', '= inc(value']),
                ('value', 'let value', ['self.value = value', 'return value +']),
                ('inc', 'fn inc', ['= inc']),
            )):
                def location(marker):
                    column = utf16_column(reference_text, reference_text.index(marker) + marker.rindex(name))
                    return {'uri': reference_uri, 'range': {'start': {'line': 0, 'character': column},
                            'end': {'line': 0, 'character': column + len(name)}}}
                query = {'textDocument': {'uri': reference_uri}, 'position': location(uses[0])['range']['start']}
                for include in (False, True):
                    query['context'] = {'includeDeclaration': include}
                    request_id = 3600 + index * 2 + int(include)
                    send('textDocument/references', query, request_id)
                    expected = [location(marker) for marker in ([declaration] if include else []) + uses]
                    assert response(request_id)['result'] == expected, (name, declaration, include)
            send('textDocument/prepareRename', query, 3620)
            assert response(3620)['result']['placeholder'] == 'inc'
            send('textDocument/rename', dict(query, newName='renamed'), 3621)
            edits = response(3621)['result']['changes'][reference_uri]
            assert len(edits) == 2 and all(edit['newText'] == 'renamed' for edit in edits)
            send('textDocument/rename', dict(query, newName='value'), 3624)
            assert response(3624)['result'] is None, 'rename allowed a colliding symbol name'
            send('textDocument/rename', dict(query, newName='not-valid'), 3625)
            assert response(3625)['result'] is None, 'rename allowed an invalid identifier'
            send('textDocument/rename', dict(query, newName='123'), 3626)
            assert response(3626)['result'] is None, 'rename allowed an identifier starting with a digit'
            send('textDocument/rename', dict(query, newName='return'), 3636)
            assert response(3636)['result'] is None, 'rename allowed a reserved word'

            partial_text = ('program Partial { struct Box { total: int } '
                            'state { total: int box: Box } '
                            'fn run(): int { return self.box.total + self.total } }')
            partial_uri, partial_diagnostics = open_document('partial-rename.aml', partial_text)
            assert partial_diagnostics == [], partial_diagnostics
            partial_query = {'textDocument': {'uri': partial_uri}, 'position': {
                'line': 0, 'character': partial_text.rindex('self.total') + len('self.') + 1}}
            send('textDocument/prepareRename', partial_query, 3627)
            assert response(3627)['result'] is None, 'prepareRename trusted a partial occurrence index'
            send('textDocument/rename', dict(partial_query, newName='updated'), 3628)
            assert response(3628)['result'] is None, 'rename trusted a partial occurrence index'

            workspace_scope = root / 'workspace-scope'
            workspace_scope.mkdir()
            library_path = workspace_scope / 'library.aml'
            consumer_path = workspace_scope / 'consumer.aml'
            unopened_path = workspace_scope / 'unopened.aml'
            library_text = 'interface I { fn helper(n: int): int }'
            consumer_text = ('import I from "./library.aml"\n'
                             'program Consumer implements I { fn helper(n: int): int { return n } }')
            unopened_text = ('import I from "./library.aml"\n'
                             'program Unopened implements I { fn helper(n: int): int { return n } }')
            library_path.write_text(library_text)
            consumer_path.write_text(consumer_text)
            unopened_path.write_text(unopened_text)
            outside_text = ('import I from "./workspace-scope/library.aml"\n'
                            'program Outside implements I { fn helper(n: int): int { return n } }')
            outside_uri, outside_diagnostics = open_document(
                'outside-overlay.aml', outside_text, root / 'outside-overlay.aml')
            assert outside_diagnostics == [], outside_diagnostics
            send('workspace/didChangeWorkspaceFolders', {'event': {
                'added': [{'uri': workspace_scope.as_uri(), 'name': 'workspace-scope'}],
                'removed': [{'uri': root.as_uri(), 'name': 'test-root'}],
            }})
            # A workspace link is outside the scan scope. Its presence must not
            # make otherwise verified workspace rename incomplete.
            if os.name != "nt":
                (workspace_scope / 'ignored-link.aml').symlink_to(unopened_path)
            workspace_uri, workspace_diagnostics = open_document(
                'consumer.aml', consumer_text, consumer_path)
            assert workspace_diagnostics == [], workspace_diagnostics
            helper_call = consumer_text.index('implements I') + len('implements ')
            workspace_query = {'textDocument': {'uri': workspace_uri}, 'position': {
                'line': 1,
                'character': utf16_column(consumer_text.splitlines()[1],
                                          helper_call - consumer_text.index('\n') - 1),
            }, 'context': {'includeDeclaration': True}}
            send('textDocument/references', workspace_query, 3630)
            workspace_references = response(3630)['result']
            assert len(workspace_references) == 5, workspace_references
            assert {item['uri'] for item in workspace_references} == {
                Path(os.path.realpath(library_path)).as_uri(), workspace_uri,
                Path(os.path.realpath(unopened_path)).as_uri()}, workspace_references
            assert outside_uri not in {item['uri'] for item in workspace_references}, \
                'workspace references included an open document outside every root'
            send('textDocument/prepareRename', workspace_query, 3631)
            assert response(3631)['result']['placeholder'] == 'I'
            send('textDocument/rename', dict(workspace_query, newName='Renamed'), 3632)
            workspace_edit = response(3632)['result']
            assert len(workspace_edit['documentChanges']) == 3, workspace_edit
            changed = {item['textDocument']['uri']: item for item in workspace_edit['documentChanges']}
            assert changed[workspace_uri]['textDocument']['version'] == 1
            assert changed[Path(os.path.realpath(library_path)).as_uri()]['textDocument']['version'] is None
            assert changed[Path(os.path.realpath(unopened_path)).as_uri()]['textDocument']['version'] is None
            send('textDocument/rename', dict(workspace_query, newName='Consumer'), 3633)
            assert response(3633)['result'] is None, 'workspace rename allowed a colliding name'
            (workspace_scope / 'broken.aml').write_text('program Broken {')
            send('textDocument/rename', dict(workspace_query, newName='Renamed'), 3634)
            assert response(3634)['result'] is None, 'incomplete workspace scan allowed rename'
            # Query immediately after an edit: references must await current analysis,
            # then reject even declaration-only matches when checking fails.
            invalid_references = reference_text.replace('return value + saved', 'return missing + saved')
            send('textDocument/didChange', {'textDocument': {'uri': reference_uri, 'version': 2},
                 'contentChanges': [{'text': invalid_references}]})
            send('textDocument/references', query, 3622)
            assert response(3622)['result'] == [], 'invalid edit retained references'
            send('textDocument/prepareRename', query, 3629)
            assert response(3629)['result'] is None, 'prepareRename accepted a document with diagnostics'
            send('textDocument/rename', dict(query, newName='renamed'), 3635)
            assert response(3635)['result'] is None, 'rename accepted a document with diagnostics'
            send('textDocument/didChange', {'textDocument': {'uri': reference_uri, 'version': 3},
                 'contentChanges': [{'text': reference_text}]})
            send('textDocument/references', query, 3623)
            assert response(3623)['result'] == [location('fn inc'), location('= inc')]
            send('workspace/didChangeWorkspaceFolders', {'event': {
                'added': [{'uri': root.as_uri(), 'name': 'test-root'}],
                'removed': [{'uri': workspace_scope.as_uri(), 'name': 'workspace-scope'}],
            }})

            ctor_text = ('/* 😀 constructor */ program P { state { total: int } '
                         'constructor(seed: int) { let value = seed self.total = inc(value) } '
                         'fn inc(n: int): int { return n + 1 } fn run(): int { return 0 } }')
            ctor_uri, items = open_document('constructor.aml', ctor_text)
            assert items == [], items
            for index, (use, declaration, width) in enumerate([
                (ctor_text.index('= seed') + 2, ctor_text.index('constructor(seed') + len('constructor('), 4),
                (ctor_text.index('inc(value)') + 4, ctor_text.index('value ='), 5),
                (ctor_text.index('inc(value)'), ctor_text.index('inc(n:'), 3),
            ]):
                send('textDocument/definition', {'textDocument': {'uri': ctor_uri}, 'position': {
                     'line': 0, 'character': utf16_column(ctor_text, use)}}, 3000 + index)
                column = utf16_column(ctor_text, declaration)
                assert response(3000 + index)['result'] == [{'uri': ctor_uri, 'range': {
                    'start': {'line': 0, 'character': column}, 'end': {'line': 0, 'character': column + width}}}]
            for index, marker in enumerate(('self.total', 'return 0')):
                send('textDocument/completion', {'textDocument': {'uri': ctor_uri}, 'position': {
                     'line': 0, 'character': utf16_column(ctor_text, ctor_text.index(marker))}}, 3010 + index)
                items = response(3010 + index)['result']['items']
                locals_named_value = [item for item in items if item['label'] == 'value' and item['kind'] == 6]
                assert len(locals_named_value) == (1 if index == 0 else 0), (index, items)
                if locals_named_value:
                    assert locals_named_value[0]['detail'] == 'let value'
                assert not any(item['label'] == 'constructor' and item['kind'] == 3 for item in items)
            send('textDocument/documentSymbol', {'textDocument': {'uri': ctor_uri}}, 3020)
            constructors = [item for item in response(3020)['result'] if item['name'] == 'constructor']
            assert len(constructors) == 1 and constructors[0]['kind'] == 9, constructors
            send('textDocument/hover', {'textDocument': {'uri': ctor_uri}, 'position': {
                 'line': 0, 'character': utf16_column(ctor_text, ctor_text.index('constructor(seed'))}}, 3021)
            assert response(3021)['result']['contents']['value'] == 'constructor(seed: int) -> void'

            tuple_text = '/* 😀 value */ program Tuple { fn run(value: int): int { let (value, other) = (value, value) return value + other } }'
            tuple_uri, items = open_document('tuple-bindings.aml', tuple_text)
            assert items == [], items
            for index, (use, declaration, width) in enumerate([
                (tuple_text.index('= (value') + 3, tuple_text.index('value: int'), 5),
                (tuple_text.index('return value') + 7, tuple_text.index('(value, other)') + 1, 5),
                (tuple_text.rindex('other'), tuple_text.index('other)'), 5),
            ]):
                send('textDocument/definition', {'textDocument': {'uri': tuple_uri}, 'position': {
                     'line': 0, 'character': utf16_column(tuple_text, use)}}, 2900 + index)
                column = utf16_column(tuple_text, declaration)
                assert response(2900 + index)['result'] == [{'uri': tuple_uri, 'range': {
                    'start': {'line': 0, 'character': column}, 'end': {'line': 0, 'character': column + width}}}]
            for index, (marker, detail, has_other) in enumerate([
                ('= (value', 'value: int', False), ('return value', 'let value', True),
            ]):
                send('textDocument/completion', {'textDocument': {'uri': tuple_uri}, 'position': {
                     'line': 0, 'character': utf16_column(tuple_text, tuple_text.index(marker))}}, 2905 + index)
                items = response(2905 + index)['result']['items']
                values = [item for item in items if item['label'] == 'value']
                assert len(values) == 1 and values[0]['detail'] == detail, values
                assert any(item['label'] == 'other' for item in items) == has_other
            invalid_tuple = tuple_text.replace('(value, value)', '(value, value, value)')
            send('textDocument/didChange', {'textDocument': {'uri': tuple_uri, 'version': 2},
                 'contentChanges': [{'text': invalid_tuple}]})
            assert diagnostics(tuple_uri), 'tuple arity mismatch must retain compiler diagnostics'
            send('textDocument/definition', {'textDocument': {'uri': tuple_uri}, 'position': {
                 'line': 0, 'character': utf16_column(invalid_tuple, invalid_tuple.rindex('other'))}}, 2909)
            assert response(2909)['result'] == [], 'stale tuple navigation survived failed checking'

            immediate_text = "program P { fn inc(n: int): int { return n } fn run(): int { return inc("
            immediate_uri = (root / "unsaved" / "immediate-signature.aml").as_uri()
            send("textDocument/didOpen", {"textDocument": {
                "uri": immediate_uri, "languageId": "aml", "version": 1, "text": immediate_text}})
            send("textDocument/signatureHelp", {"textDocument": {"uri": immediate_uri},
                 "position": {"line": 0, "character": len(immediate_text)}}, 2400)
            immediate_help = response(2400)["result"]
            assert immediate_help is not None, "signature request raced the initial analysis"
            assert immediate_help["signatures"][0]["label"] == "inc(n: int) -> int"
            immediate_text = "program P { state { total: int } fn run(): int { return self."
            send("textDocument/didChange", {"textDocument": {"uri": immediate_uri, "version": 2},
                 "contentChanges": [{"text": immediate_text}]})
            send("textDocument/completion", {"textDocument": {"uri": immediate_uri},
                 "position": {"line": 0, "character": len(immediate_text)}}, 2401)
            immediate_items = response(2401)["result"]["items"]
            assert len(immediate_items) == 1 and immediate_items[0]["label"] == "total", immediate_items

            format_text = "/* 😀 */ program P {\r\nfn run(): int {\r\nreturn 1\r\n}\r\n}\r\n"
            format_uri, items = open_document("formatting.aml", format_text)
            assert items == [], items
            for index, (spaces, unit) in enumerate(((True, "    "), (False, "\t"))):
                send("textDocument/formatting", {"textDocument": {"uri": format_uri},
                     "options": {"tabSize": 4, "insertSpaces": spaces}}, 2500 + index)
                edits = response(2500 + index)["result"]
                assert len(edits) == 3, edits
                lines = format_text.split("\n")
                for edit in edits:
                    start, end = edit["range"]["start"], edit["range"]["end"]
                    assert start["line"] == end["line"] and start["character"] == 0
                    assert edit["newText"].strip() == "", edit
                    line = start["line"]
                    lines[line] = edit["newText"] + lines[line][end["character"]:]
                assert lines[1] == unit + "fn run(): int {\r"
                assert lines[2] == unit * 2 + "return 1\r"
                assert lines[3] == unit + "}\r"
            formatted = "\n".join(lines)
            send("textDocument/didChange", {"textDocument": {"uri": format_uri, "version": 2},
                 "contentChanges": [{"text": formatted}]})
            assert diagnostics(format_uri) == []
            send("textDocument/formatting", {"textDocument": {"uri": format_uri},
                 "options": {"tabSize": 4, "insertSpaces": False}}, 2502)
            assert response(2502)["result"] == [], "formatting is not idempotent"
            send("textDocument/didChange", {"textDocument": {"uri": format_uri, "version": 3},
                 "contentChanges": [{"text": "program P { fn run(): int { return ("}]})
            send("textDocument/formatting", {"textDocument": {"uri": format_uri},
                 "options": {"tabSize": 4, "insertSpaces": True}}, 2503)
            assert response(2503)["result"] == [], "stale formatting survived an invalid edit"
            term_format_text = "program P {\n /* }\n    still { comment\n */\nterm unit\n}\n"
            term_format_uri, items = open_document("term-formatting.aml", term_format_text)
            assert items == [], items
            send("textDocument/formatting", {"textDocument": {"uri": term_format_uri},
                 "options": {"tabSize": 4, "insertSpaces": True}}, 2510)
            assert response(2510)["result"] == [{"range": {
                "start": {"line": 4, "character": 0}, "end": {"line": 4, "character": 0}},
                "newText": "    "}], "term formatter edited comment contents or used their braces"

            source = "program Example { fn inc(n: int): int { return n + 1 } }"
            uri, items = open_document("valid.aml", source)
            assert items == [], items
            position = {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 30}}
            send("textDocument/completion", position, 2)
            completion = response(2)["result"]["items"]
            assert any(item["label"] == "inc" for item in completion), completion
            send("textDocument/definition", position, 3)
            assert response(3)["result"] == []
            send("textDocument/documentSymbol", {"textDocument": {"uri": uri}}, 10)
            symbols = response(10)["result"]
            assert {s["name"] for s in symbols} == {"Example", "inc"}, symbols
            for symbol in symbols:
                span = symbol["selectionRange"]
                assert span["start"]["line"] == span["end"]["line"] == 0, span
                assert source[span["start"]["character"]:span["end"]["character"]] == symbol["name"]

            calls = ('// 한글 return inc(0)\nprogram P { fn inc(n: int): int { return n + 1 }\n'
                     'fn run(n: int): int { return inc(n) } }')
            call_uri, items = open_document("calls.aml", calls)
            assert items == [], items
            query = {"textDocument": {"uri": call_uri},
                     "position": {"line": 2, "character": calls.splitlines()[2].index("inc(")}}
            send("textDocument/definition", query, 11)
            target = response(11)["result"]
            column = calls.splitlines()[1].index("inc(")
            assert target == [{"uri": call_uri, "range": {
                "start": {"line": 1, "character": column},
                "end": {"line": 1, "character": column + 3}}}], target
            send("textDocument/declaration", query, 12)
            assert response(12)["result"] == target
            send("textDocument/hover", query, 20)
            hover = response(20)["result"]
            assert hover["contents"] == {"kind": "plaintext", "value": "inc(n: int) -> int"}, hover
            assert hover["range"] == {"start": query["position"], "end": {
                "line": 2, "character": query["position"]["character"] + 3}}, hover
            query["position"] = {"line": 0, "character": len("// 한글 return ")}
            send("textDocument/definition", query, 13)
            assert response(13)["result"] == [], "comment must not resolve by name"
            send("textDocument/hover", query, 21)
            assert response(21)["result"] is None, "comment must not receive symbol hover"
            send("textDocument/references", query, 14)
            assert response(14)["result"] == [], "comment must not resolve to references by name"
            shadow = 'program P { fn inc(): int { return 1 } fn run(inc: int): int { return inc } }'
            send("textDocument/didChange", {"textDocument": {"uri": call_uri, "version": 2},
                 "contentChanges": [{"text": shadow}]})
            assert diagnostics(call_uri) == []
            query["position"] = {"line": 0, "character": shadow.rindex("inc")}
            send("textDocument/definition", query, 15)
            parameter_column = shadow.index("inc: int")
            assert response(15)["result"] == [{"uri": call_uri, "range": {
                "start": {"line": 0, "character": parameter_column},
                "end": {"line": 0, "character": parameter_column + 3}}}], "parameter must not resolve to function"
            send("textDocument/hover", query, 22)
            assert response(22)["result"]["contents"]["value"] == "inc: int", "parameter must not receive function hover"

            local_source = ('// 한글\nprogram P { fn run(): int { let secret = 1 let secret = 2 return secret }\n'
                            'fn other(): int { return 0 } }')
            local_uri, items = open_document("locals.aml", local_source)
            assert items == [], items
            local_line = local_source.splitlines()[1]
            local_query = {"textDocument": {"uri": local_uri},
                           "position": {"line": 1, "character": local_line.rindex("secret")}}
            send("textDocument/definition", local_query, 16)
            local_target = response(16)["result"]
            start = local_line.index("let secret = 2") + len("let ")
            assert local_target == [{"uri": local_uri, "range": {
                "start": {"line": 1, "character": start},
                "end": {"line": 1, "character": start + len("secret")}}}], local_target
            send("textDocument/hover", local_query, 23)
            assert response(23)["result"]["contents"]["value"] == "let secret", "do not fabricate local type"
            local_query["position"] = {"line": 2, "character": 26}
            send("textDocument/completion", local_query, 17)
            assert all(item["label"] != "secret" for item in response(17)["result"]["items"])
            send("textDocument/documentSymbol", {"textDocument": {"uri": local_uri}}, 18)
            assert all(item["name"] != "secret" for item in response(18)["result"])
            send("textDocument/didChange", {"textDocument": {"uri": local_uri, "version": 2},
                 "contentChanges": [{"text": local_source.replace("return secret", "return missing")}]})
            assert diagnostics(local_uri)
            local_query["position"] = {"line": 1, "character": local_line.rindex("secret")}
            send("textDocument/definition", local_query, 19)
            assert response(19)["result"] == [], "failed checks must discard local navigation"
            send("textDocument/hover", local_query, 24)
            assert response(24)["result"] is None, "failed checks must discard local hover"

            scoped = ('/* 😀 */ program P { fn secret(): int { return 0 } '
                      'fn run(): int { let secret: int = 1 let secret = secret + 1 return secret } '
                      'fn other(): int { return 0 } }')
            scoped_uri, items = open_document("scoped-completion.aml", scoped)
            assert items == [], items
            checks = [
                (scoped.index("let secret:"), 3, "secret() -> int"),
                (scoped.index("secret + 1"), 6, "let secret: int"),
                (scoped.index("return secret") + len("return "), 6, "let secret"),
                (scoped.rindex("return 0"), 3, "secret() -> int"),
            ]
            for index, (offset, kind, detail) in enumerate(checks):
                send("textDocument/completion", {"textDocument": {"uri": scoped_uri},
                     "position": {"line": 0, "character": utf16_column(scoped, offset)}}, 40 + index)
                matches = [item for item in response(40 + index)["result"]["items"]
                           if item["label"] == "secret"]
                assert len(matches) == 1 and matches[0]["kind"] == kind and matches[0]["detail"] == detail, matches

            parameter_lines = [
                "/* 😀 n: int */ program P {",
                "fn run(n: int, pair: (int, int)): int { let n = n + 1 return n }",
                "fn other(n: bool): bool { return n }",
                "}",
            ]
            parameter_uri, items = open_document("parameters.aml", "\n".join(parameter_lines))
            assert items == [], items
            for index, (line, fragment, detail, has_pair) in enumerate([
                (1, "let n", "n: int", True),
                (1, "n + 1", "n: int", True),
                (1, "return n", "let n", True),
                (2, "return n", "n: bool", False),
            ]):
                send("textDocument/completion", {"textDocument": {"uri": parameter_uri},
                     "position": {"line": line, "character": parameter_lines[line].index(fragment)}}, 50 + index)
                completion = response(50 + index)["result"]["items"]
                matches = [item for item in completion if item["label"] == "n"]
                assert len(matches) == 1 and matches[0]["kind"] == 6 and matches[0]["detail"] == detail, matches
                assert any(item["label"] == "pair" for item in completion) == has_pair, completion
            parameter_query = {"textDocument": {"uri": parameter_uri},
                               "position": {"line": 2, "character": parameter_lines[2].rindex("n")}}
            send("textDocument/definition", parameter_query, 54)
            start = parameter_lines[2].index("n: bool")
            assert response(54)["result"] == [{"uri": parameter_uri, "range": {
                "start": {"line": 2, "character": start},
                "end": {"line": 2, "character": start + 1}}}]
            send("textDocument/documentSymbol", {"textDocument": {"uri": parameter_uri}}, 55)
            assert {item["name"] for item in response(55)["result"]} == {"P", "run", "other"}
            parameter_query["position"] = {"line": 0, "character": utf16_column(parameter_lines[0], parameter_lines[0].index("n:"))}
            send("textDocument/hover", parameter_query, 56)
            assert response(56)["result"] is None, "comment must not resolve to a parameter"

            compatible = ("/* 😀 */ program P { fn run(value: int, epoch: int, epoch_time: int, balance: int): int "
                          "{ return value } }")
            compatible_uri, items = open_document("parameter-keywords.aml", compatible)
            assert items == [], items
            compatible_query = {"textDocument": {"uri": compatible_uri},
                                "position": {"line": 0, "character": utf16_column(compatible, compatible.rindex("value"))}}
            send("textDocument/completion", compatible_query, 57)
            completion = response(57)["result"]["items"]
            for name in ("value", "epoch", "epoch_time", "balance"):
                matches = [item for item in completion if item["label"] == name]
                assert len(matches) == 1 and matches[0]["kind"] == 6 and matches[0]["detail"] == name + ": int", matches
            send("textDocument/definition", compatible_query, 58)
            start = utf16_column(compatible, compatible.index("value: int"))
            assert response(58)["result"] == [{"uri": compatible_uri, "range": {
                "start": {"line": 0, "character": start},
                "end": {"line": 0, "character": start + len("value")}}}]
            compatible_query["position"] = {"line": 0, "character": 0}
            send("textDocument/completion", compatible_query, 59)
            assert all(item["kind"] != 6 for item in response(59)["result"]["items"]), "parameters leaked outside their body"

            loop_lines = [
                "/* 😀 */ program Loops { state { values: list[int] }",
                "fn run(i: int): int {",
                "  for i in 0..2 {",
                "    let marker = i",
                "    for i in 0..1 { return i }",
                "    return i",
                "  }",
                "  return i",
                "}",
                "fn each(): int { for entry in self.values { return entry } return 0 }",
                "}",
            ]
            loop_uri, items = open_document("loops.aml", "\n".join(loop_lines))
            assert items == [], items
            for index, (line, target_line, target_text) in enumerate([
                (4, 4, "i in"), (5, 2, "i in"), (7, 1, "i: int"), (9, 9, "entry in"),
            ]):
                name = "entry" if line == 9 else "i"
                column = loop_lines[line].index("return " + name) + len("return ")
                loop_query = {"textDocument": {"uri": loop_uri},
                              "position": {"line": line, "character": column}}
                send("textDocument/definition", loop_query, 60 + index)
                start = loop_lines[target_line].index(target_text)
                assert response(60 + index)["result"] == [{"uri": loop_uri, "range": {
                    "start": {"line": target_line, "character": start},
                    "end": {"line": target_line, "character": start + len(name)}}}]
                send("textDocument/completion", loop_query, 64 + index)
                completion = response(64 + index)["result"]["items"]
                matches = [item for item in completion if item["label"] == name]
                assert len(matches) == 1 and matches[0]["kind"] == 6 and matches[0]["detail"] == name + ": int", matches
                assert any(item["label"] == "marker" for item in completion) == (line in (4, 5)), completion
                send("textDocument/hover", loop_query, 69 + index)
                assert response(69 + index)["result"]["contents"]["value"] == name + ": int"
            send("textDocument/documentSymbol", {"textDocument": {"uri": loop_uri}}, 68)
            assert all(item["name"] not in ("i", "entry", "marker") for item in response(68)["result"])

            fib_lines = [
                "/* 😀 */ program Fib { public fn fib(n: int): int {",
                "let a = 0 let b = 1 let i = 0",
                "while i < n {",
                "let t = a + b",
                "a = b b = t i = i + 1",
                "}",
                "return a",
                "} }",
            ]
            fib_uri, items = open_document("fibonacci.aml", "\n".join(fib_lines))
            assert items == [], items
            for index, (line, names) in enumerate([
                (2, {"n", "a", "b", "i"}),
                (4, {"n", "a", "b", "i", "t"}),
                (6, {"n", "a", "b", "i"}),
            ]):
                query = {"textDocument": {"uri": fib_uri}, "position": {"line": line, "character": 0}}
                send("textDocument/completion", query, 2200 + index)
                completion = response(2200 + index)["result"]["items"]
                assert {item["label"] for item in completion if item["kind"] == 6} == names, completion
            send("textDocument/definition", {"textDocument": {"uri": fib_uri},
                 "position": {"line": 6, "character": 7}}, 2203)
            assert response(2203)["result"] == [{"uri": fib_uri, "range": {
                "start": {"line": 1, "character": 4}, "end": {"line": 1, "character": 5}}}]

            shadow_lines = ["program P { fn run(n: int): int {",
                            "while n > 0 { let n = 2 return n }", "return n", "} }"]
            shadow_uri, items = open_document("while-shadow.aml", "\n".join(shadow_lines))
            assert items == [], items
            for index, line in enumerate((1, 2)):
                query = {"textDocument": {"uri": shadow_uri}, "position": {
                    "line": line, "character": shadow_lines[line].index("return n") + len("return ")}}
                send("textDocument/definition", query, 2204 + index)
                targets = response(2204 + index)["result"]
                if line == 1:
                    start = shadow_lines[line].index("n =")
                    assert targets == [{"uri": shadow_uri, "range": {
                        "start": {"line": line, "character": start},
                        "end": {"line": line, "character": start + 1}}}], targets
                else:
                    assert targets == [], "post-while use selected an ambiguous binding"
                    send("textDocument/completion", query, 2206)
                    assert not any(item["label"] == "n" for item in response(2206)["result"]["items"])

            branch_lines = ["/* 😀 */ program P { fn run(n: int): int {",
                            "if n > 0 { let x = 1 return x }",
                            "else if n < 0 { let x = 2 return x }",
                            "else { let x = 3 return x }", "return n", "} }"]
            branch_uri, items = open_document("branches.aml", "\n".join(branch_lines))
            assert items == [], items
            for index, line in enumerate((1, 2, 3, 4)):
                name = "n" if line == 4 else "x"
                query = {"textDocument": {"uri": branch_uri}, "position": {
                    "line": line, "character": branch_lines[line].index("return " + name) + len("return ")}}
                send("textDocument/completion", query, 2210 + index)
                completion = response(2210 + index)["result"]["items"]
                assert {item["label"] for item in completion if item["kind"] == 6} == (
                    {"n"} if line == 4 else {"n", "x"}), completion
                send("textDocument/definition", query, 2214 + index)
                target_line = 0 if line == 4 else line
                start = utf16_column(branch_lines[target_line], branch_lines[target_line].index(
                    "n: int" if line == 4 else "x ="))
                assert response(2214 + index)["result"] == [{"uri": branch_uri, "range": {
                    "start": {"line": target_line, "character": start},
                    "end": {"line": target_line, "character": start + 1}}}]

            match_lines = ["program P { enum Mode { A, B } fn run(mode: Mode, n: int): int {",
                           "match mode {", "Mode.A => { let x = 1 return x }",
                           "Mode.B => return n", "}", "return n", "} }"]
            match_uri, items = open_document("match-arms.aml", "\n".join(match_lines))
            assert items == [], items
            for index, line in enumerate((2, 3, 5)):
                query = {"textDocument": {"uri": match_uri}, "position": {
                    "line": line, "character": match_lines[line].index("return ") + len("return ")}}
                send("textDocument/completion", query, 2220 + index)
                completion = response(2220 + index)["result"]["items"]
                assert {item["label"] for item in completion if item["kind"] == 6} == (
                    {"mode", "n", "x"} if line == 2 else {"mode", "n"}), completion
                send("textDocument/definition", query, 2223 + index)
                target_line = 2 if line == 2 else 0
                start = match_lines[target_line].index("x =" if line == 2 else "n: int")
                assert response(2223 + index)["result"] == [{"uri": match_uri, "range": {
                    "start": {"line": target_line, "character": start},
                    "end": {"line": target_line, "character": start + 1}}}]

            for index, body in enumerate((
                "if n > 0 { return n } else { let n = 2 return n }",
                "match mode { Mode.A => { let n = 2 return n } Mode.B => return n }",
            )):
                text = ("program P { enum Mode { A, B } fn run(mode: Mode, n: int): int { "
                        + body + " return n } }")
                uri, items = open_document("branch-shadow-" + str(index) + ".aml", text)
                assert items == [], items
                query = {"textDocument": {"uri": uri}, "position": {
                    "line": 0, "character": text.rindex("return n") + len("return ")}}
                send("textDocument/definition", query, 2230 + index)
                assert response(2230 + index)["result"] == [], "ambiguous post-branch binding was indexed"
                send("textDocument/completion", query, 2232 + index)
                assert not any(item["label"] == "n" for item in response(2232 + index)["result"]["items"])
                # The controlling expression is emitted before branch locals.
                query["position"]["character"] = text.index(body) + (3 if index == 0 else 6)
                send("textDocument/completion", query, 2234 + index)
                assert any(item["label"] == "n" and item["detail"] == "n: int"
                           for item in response(2234 + index)["result"]["items"])

            expression_lines = ["/* 😀 n */ program P { state { n: int }",
                                "fn helper(n: int): int { return n }",
                                "fn run(n: int): int {",
                                "let n = n + self.n + helper(n) /* n */",
                                "n += n", "assert n > 0", "return n + n", "} }"]
            expression_uri, items = open_document("expression-uses.aml", "\n".join(expression_lines))
            assert items == [], items
            for index, (line, column, target_line, target_column) in enumerate((
                (3, 8, 2, 7), (3, expression_lines[3].index("helper(n)") + 7, 2, 7),
                (4, 0, 3, 4), (4, 5, 3, 4), (5, 7, 3, 4), (6, 7, 3, 4), (6, 11, 3, 4),
            )):
                query = {"textDocument": {"uri": expression_uri}, "position": {"line": line, "character": column}}
                send("textDocument/definition", query, 2240 + index)
                assert response(2240 + index)["result"] == [{"uri": expression_uri, "range": {
                    "start": {"line": target_line, "character": target_column},
                    "end": {"line": target_line, "character": target_column + 1}}}]
                send("textDocument/hover", query, 2250 + index)
                assert response(2250 + index)["result"]["contents"]["value"] == (
                    "n: int" if target_line == 2 else "let n")
            for index, column in enumerate((expression_lines[3].index("self.n") + 5,
                                            expression_lines[3].index("/* n") + 3)):
                send("textDocument/definition", {"textDocument": {"uri": expression_uri},
                     "position": {"line": 3, "character": column}}, 2260 + index)
                locations = response(2260 + index)["result"]
                if index == 0:
                    target = utf16_column(expression_lines[0], expression_lines[0].index("state { n") + 8)
                    assert locations == [{"uri": expression_uri, "range": {
                        "start": {"line": 0, "character": target},
                        "end": {"line": 0, "character": target + 1}}}], locations
                else:
                    assert locations == [], "comment was mistaken for a use"

            call_lines = ["/* 😀 inc(n) */ program P { fn inc(n: int): int { return n + 1 }",
                          "fn run(n: int): int {", "let next = inc(n)",
                          "n = inc(inc(n))", "if inc(n) > 0 { return inc(n) + inc(1) }",
                          "return next", "} }"]
            call_uri, items = open_document("expression-calls.aml", "\n".join(call_lines))
            assert items == [], items
            target = utf16_column(call_lines[0], call_lines[0].index("fn inc") + 3)
            index = 0
            for line in (2, 3, 4):
                start = 0
                while True:
                    column = call_lines[line].find("inc(", start)
                    if column < 0:
                        break
                    query = {"textDocument": {"uri": call_uri}, "position": {"line": line, "character": column}}
                    send("textDocument/definition", query, 2270 + index)
                    assert response(2270 + index)["result"] == [{"uri": call_uri, "range": {
                        "start": {"line": 0, "character": target},
                        "end": {"line": 0, "character": target + 3}}}]
                    send("textDocument/hover", query, 2280 + index)
                    assert "inc(n: int)" in response(2280 + index)["result"]["contents"]["value"]
                    index += 1
                    start = column + 4
            assert index == 6

            local_call_lines = ["program P { fn inc(n: int): int { return n + 1 }",
                                "fn run(): int { let n = 1", "let next = inc(n)",
                                "if next > 0 { let n = 2 return inc(n) }",
                                "return inc(next)", "} }"]
            local_call_uri, items = open_document("local-argument-calls.aml", "\n".join(local_call_lines))
            assert items == [], items
            for index, line in enumerate((2, 3, 4)):
                query = {"textDocument": {"uri": local_call_uri}, "position": {
                    "line": line, "character": local_call_lines[line].index("inc(")}}
                send("textDocument/definition", query, 2290 + index)
                assert response(2290 + index)["result"] == [{"uri": local_call_uri, "range": {
                    "start": {"line": 0, "character": 15},
                    "end": {"line": 0, "character": 18}}}]

            signature_prefix = ("/* 😀 */ program P { fn choose(text: string, n: int): int { return n } "
                                "fn inc(n: int): int { return n } fn run(): int { return ")
            for index, (suffix, label, parameter) in enumerate((
                ("choose(", "choose(text: string, n: int) -> int", 0),
                ('choose("a,b", ', "choose(text: string, n: int) -> int", 1),
                ('choose("a,b", inc(', "inc(n: int) -> int", 0),
                ('choose("a,b", inc(1) + ', "choose(text: string, n: int) -> int", 1),
                ('choose("a,b", unknown(', None, 0),
                ('"choose(', None, 0), ("// choose(", None, 0),
            )):
                text = signature_prefix + suffix
                signature_uri, items = open_document("signature-" + str(index) + ".aml", text)
                assert items, "unfinished call lost its diagnostic"
                send("textDocument/signatureHelp", {"textDocument": {"uri": signature_uri},
                     "position": {"line": 0, "character": utf16_column(text, len(text))}}, 2300 + index)
                help = response(2300 + index)["result"]
                if label is None:
                    assert help is None, help
                else:
                    assert help["signatures"][0]["label"] == label, help
                    assert help["activeParameter"] == parameter, help
                    assert help["signatures"][0]["parameters"][parameter]["label"] in label

            form_signature_prefix = ('/* 😀 */ program P { form add [many left: int, many right: int] '
                                     '(many value: int) ->[many] int marks {} = left + right + value '
                                     'form consume [] (once value: int) ->[many] int marks {} = value '
                                     'fn run(): int { return ')
            for index, (suffix, label, parameter) in enumerate((
                ('add(1, 2, ', 'add(left: int, right: int, value: int) -> int', 2),
                ('use add[', 'add(left: int, right: int, value: int) -> int', 0),
                ('use add[1, ', 'add(left: int, right: int, value: int) -> int', 1),
                ('use add[1, 2] /* 😀 , */ (', 'add(left: int, right: int, value: int) -> int', 2),
                ('use add[1, 2](unknown(', None, 0),
                ('use consume[](', 'consume(value: int) -> int', 0),
                ('consume(', None, 0),
            )):
                text = form_signature_prefix + suffix
                form_signature_uri, items = open_document('form-signature-' + str(index) + '.aml', text)
                assert items, 'unfinished form call lost its diagnostic'
                send('textDocument/signatureHelp', {'textDocument': {'uri': form_signature_uri}, 'position': {
                     'line': 0, 'character': utf16_column(text, len(text))}}, 3200 + index)
                help = response(3200 + index)['result']
                if label is None:
                    assert help is None, help
                else:
                    assert help['signatures'][0]['label'] == label and help['activeParameter'] == parameter, help
            changed_form_signature = ('program P { form add [many left: int] (many value: bool) '
                                      '->[many] int marks {} = if value then left else 0 '
                                      'fn run(): int { return use add[1](')
            send('textDocument/didChange', {'textDocument': {'uri': form_signature_uri, 'version': 2},
                 'contentChanges': [{'text': changed_form_signature}]})
            send('textDocument/signatureHelp', {'textDocument': {'uri': form_signature_uri}, 'position': {
                 'line': 0, 'character': len(changed_form_signature)}}, 3210)
            help = response(3210)['result']
            assert help['signatures'][0]['label'] == 'add(left: int, value: bool) -> int', help
            assert help['activeParameter'] == 1, help

            changed_signature = signature_prefix.replace("text: string", "text: bool") + "choose("
            send("textDocument/didChange", {"textDocument": {"uri": signature_uri, "version": 2},
                 "contentChanges": [{"text": changed_signature}]})
            assert diagnostics(signature_uri)
            send("textDocument/signatureHelp", {"textDocument": {"uri": signature_uri},
                 "position": {"line": 0, "character": utf16_column(changed_signature, len(changed_signature))}}, 2310)
            assert response(2310)["result"]["signatures"][0]["label"] == "choose(text: bool, n: int) -> int"

            recovery_prefix = "/* 😀 */ program P { fn run(seed: int): int { let secret = seed "
            for index, suffix in enumerate(("return secr", "return (", "let unfinished =", "return secr } }")):
                recovering = recovery_prefix + suffix
                recovery_uri, items = open_document(f"recover{index}.aml", recovering)
                assert items, "completion recovery must not suppress errors"
                offset = len(recovering) if not suffix.endswith("} }") else recovering.index("secr", len(recovery_prefix)) + 4
                recovery_query = {"textDocument": {"uri": recovery_uri},
                                  "position": {"line": 0, "character": utf16_column(recovering, offset)}}
                send("textDocument/completion", recovery_query, 2000 + index)
                result = response(2000 + index)["result"]
                labels = {item["label"] for item in result["items"]}
                assert result["isIncomplete"] and {"seed", "secret"} <= labels and "unfinished" not in labels, result
                # Query the original declaration too: recovered metadata must
                # not accidentally enable navigation through a guessed tree.
                recovery_query["position"]["character"] = utf16_column(recovering, recovering.index("secret ="))
                send("textDocument/definition", recovery_query, 2010 + index)
                assert response(2010 + index)["result"] == []
                send("textDocument/hover", recovery_query, 2020 + index)
                assert response(2020 + index)["result"] is None
                send("textDocument/diagnostic", {"textDocument": {"uri": recovery_uri}}, 2030 + index)
                assert response(2030 + index)["result"]["items"] == items

            separated = recovery_prefix + "let unfinished = } fn other(): int { return 0 } }"
            separated_uri, items = open_document("recovery-scopes.aml", separated)
            assert items
            for index, fragment in enumerate(("unfinished =", "return 0")):
                send("textDocument/completion", {"textDocument": {"uri": separated_uri},
                     "position": {"line": 0, "character": utf16_column(separated, separated.index(fragment))}}, 2040 + index)
                labels = {item["label"] for item in response(2040 + index)["result"]["items"]}
                assert ("secret" in labels) == (index == 0), labels
                assert "other" in labels and "unfinished" not in labels, labels
            loop_recovery = "program P { fn run(i: string): int { for i in 0..2 { let secret = 1 return ("
            loop_recovery_uri, items = open_document("recovery-loop.aml", loop_recovery)
            assert items
            send("textDocument/completion", {"textDocument": {"uri": loop_recovery_uri},
                 "position": {"line": 0, "character": len(loop_recovery)}}, 2050)
            matches = [item for item in response(2050)["result"]["items"] if item["label"] == "i"]
            assert len(matches) == 1 and matches[0]["detail"] == "i: int", "synthetic loop closing restored the outer parameter"

            member_schema = ("/* 😀 */ program P { struct Contact { active: bool } "
                             "struct Account { count: int contact: Contact } enum Mode { Ready, Busy } "
                             "state { account: Account total: int } ")
            def member_query(uri, text, offset):
                prefix_lines = text[:offset].split("\n")
                return {"textDocument": {"uri": uri}, "position": {
                    "line": len(prefix_lines) - 1,
                    "character": utf16_column(prefix_lines[-1], len(prefix_lines[-1]))}}

            state_items = {("account", "Account", 5), ("total", "int", 5)}
            for index, (expression, expected) in enumerate([
                ("self.", state_items),
                ("self.account.", {("count", "int", 5), ("contact", "Contact", 5)}),
                ("self.account.contact.", {("active", "bool", 5)}),
                ("Mode.", {("Ready", "Mode", 20), ("Busy", "Mode", 20)}),
                ("person.", set()), ("self.missing.", set()), ("self.total.", set()),
                ("self.   ac", state_items), ("self.\nac", state_items),
            ]):
                member_source = member_schema + f"fn run(person: Account): int {{ return {expression} }} }}"
                member_uri, items = open_document(f"members{index}.aml", member_source)
                assert items, "unfinished member fixture must retain its original error"
                offset = member_source.index("return ") + len("return ") + len(expression)
                send("textDocument/completion", member_query(member_uri, member_source, offset), 2100 + index)
                result = response(2100 + index)["result"]
                assert {(item["label"], item["detail"], item["kind"]) for item in result["items"]} == expected, result
                if index == 0:
                    renamed = member_source.replace("total: int", "updated: int")
                    send("textDocument/didChange", {"textDocument": {"uri": member_uri, "version": 2},
                         "contentChanges": [{"text": renamed}]})
                    assert diagnostics(member_uri)
                    offset = renamed.index("return self.") + len("return self.")
                    send("textDocument/completion", member_query(member_uri, renamed, offset), 2120)
                    labels = {item["label"] for item in response(2120)["result"]["items"]}
                    assert labels == {"account", "updated"}, "member cache retained an old field"
            for index, decoy in enumerate((
                "// self.\n" + member_schema + "fn run(): int { return 0 } }",
                member_schema + 'fn run(): string { return "self." } }',
            )):
                decoy_uri, items = open_document(f"member-decoy{index}.aml", decoy)
                assert items == [], items
                send("textDocument/completion", member_query(decoy_uri, decoy, decoy.index("self.") + len("self.")), 2130 + index)
                assert response(2130 + index)["result"]["items"] == [], "member completion leaked into a comment or string"
            length_source = "program P { state { entries: list[int] } fn size(): int { return self.entries. } }"
            length_uri, items = open_document("member-length.aml", length_source)
            assert items
            send("textDocument/completion", member_query(length_uri, length_source,
                 length_source.index("self.entries.") + len("self.entries.")), 2140)
            result = response(2140)["result"]["items"]
            assert len(result) == 1 and result[0]["label"] == "length" and result[0]["detail"] == "int", result
            indexed_schema = ("/* 😀 */ program P { struct Account { count: int } "
                              "state { accounts: map[int]Account nested: map[int]map[int]Account keys: map[int]int } ")
            for index, expression in enumerate((
                "self.accounts[0].", "self.accounts[self.keys[0]].",
                "self.nested[0][1].", "self.accounts[(self.keys[0] + 1)].",
            )):
                text = indexed_schema + f"fn run(): int {{ return {expression} }} }}"
                uri, items = open_document(f"indexed-member{index}.aml", text)
                assert items
                offset = text.index("return ") + len("return ") + len(expression)
                send("textDocument/completion", member_query(uri, text, offset), 2150 + index)
                result = response(2150 + index)["result"]["items"]
                assert len(result) == 1 and result[0]["label"] == "count" and result[0]["detail"] == "int", result
            unknown_index = indexed_schema + "fn run(): int { return unknown[self.accounts[0]]. } }"
            unknown_uri, items = open_document("unknown-indexed-member.aml", unknown_index)
            assert items
            offset = unknown_index.index("unknown[self.accounts[0]].") + len("unknown[self.accounts[0]].")
            send("textDocument/completion", member_query(unknown_uri, unknown_index, offset), 2160)
            assert response(2160)["result"]["items"] == [], "key expression type leaked into the outer receiver"

            method_schema = 'program Methods { state { entries: list[int] } '
            expected_methods = {('push', 'push(value: int)', 2), ('delete', 'delete(index: int)', 2),
                                ('len', 'len()', 2), ('pop', 'pop()', 2)}
            for index, body in enumerate(('/* 😀 */ self.entries.', 'if true { self.entries. }',
                                          'return self.entries.', 'let value = self.entries.')):
                method_text = method_schema + 'fn run(): int { ' + body + ' } }'
                method_uri, items = open_document(f'list-method-{index}.aml', method_text)
                assert items, 'unfinished method must retain compiler diagnostics'
                offset = method_text.index('self.entries.') + len('self.entries.')
                send('textDocument/completion', member_query(method_uri, method_text, offset), 2700 + index)
                result = response(2700 + index)['result']['items']
                expected = expected_methods if index < 2 else {('length', 'int', 5)}
                assert {(item['label'], item['detail'], item['kind']) for item in result} == expected, result
                if index == 0:
                    statement_uri, statement_text = method_uri, method_text
            bool_method = statement_text.replace('list[int]', 'list[bool]')
            send('textDocument/didChange', {'textDocument': {'uri': statement_uri, 'version': 2},
                 'contentChanges': [{'text': bool_method}]})
            offset = bool_method.index('self.entries.') + len('self.entries.')
            send('textDocument/completion', member_query(statement_uri, bool_method, offset), 2709)
            updated_methods = response(2709)['result']['items']
            assert any(item['label'] == 'push' and item['detail'] == 'push(value: bool)'
                       for item in updated_methods), updated_methods
            changed_method = statement_text.replace('list[int]', 'map[int]int')
            send('textDocument/didChange', {'textDocument': {'uri': statement_uri, 'version': 3},
                 'contentChanges': [{'text': changed_method}]})
            offset = changed_method.index('self.entries.') + len('self.entries.')
            send('textDocument/completion', member_query(statement_uri, changed_method, offset), 2710)
            assert all(item['kind'] != 2 for item in response(2710)['result']['items'])

            # Multibyte text must precede the queried token on the same line;
            # a Unicode comment on an earlier line cannot catch column errors.
            unicode_source = ('/* 한글 😀 */ program P { fn inc(n: int): int { return n } '
                              'fn run(): int { /* 🧪 */ return inc(1) } }')
            unicode_uri, items = open_document("unicode.aml", unicode_source)
            assert items == [], items
            declaration_column = utf16_column(unicode_source, unicode_source.index("inc("))
            call_column = utf16_column(unicode_source, unicode_source.rindex("inc("))
            unicode_query = {"textDocument": {"uri": unicode_uri},
                             "position": {"line": 0, "character": call_column}}
            send("textDocument/definition", unicode_query, 25)
            unicode_definition = response(25)["result"]
            assert unicode_definition == [{"uri": unicode_uri, "range": {
                "start": {"line": 0, "character": declaration_column},
                "end": {"line": 0, "character": declaration_column + 3}}}], unicode_definition
            send("textDocument/hover", unicode_query, 26)
            assert response(26)["result"]["range"] == {
                "start": unicode_query["position"],
                "end": {"line": 0, "character": call_column + 3}}

            # Exercise the transport's incremental UTF-16 edit conversion as
            # well as the compiler's byte-offset diagnostic conversion.
            argument_column = call_column + len("inc(")
            edit_range = {"start": {"line": 0, "character": argument_column},
                          "end": {"line": 0, "character": argument_column + 1}}
            send("textDocument/didChange", {"textDocument": {"uri": unicode_uri, "version": 2},
                 "contentChanges": [{"range": edit_range, "text": "@"}]})
            items = diagnostics(unicode_uri)
            error_point = {"line": 0, "character": argument_column}
            assert len(items) == 1 and items[0]["range"] == {
                "start": error_point, "end": error_point}, items
            send("textDocument/didChange", {"textDocument": {"uri": unicode_uri, "version": 3},
                 "contentChanges": [{"range": edit_range, "text": "1"}]})
            assert diagnostics(unicode_uri) == []

            # Send a burst without waiting between versions, then query the
            # final buffer. This checks cache invalidation, not deterministic
            # cancellation of an already-running compiler worker.
            for version in range(4, 14):
                updated = unicode_source.replace("inc", f"step{version}")
                send("textDocument/didChange", {"textDocument": {"uri": unicode_uri, "version": version},
                     "contentChanges": [{"text": updated}]})
            send("textDocument/diagnostic", {"textDocument": {"uri": unicode_uri}}, 27)
            assert response(27)["result"]["items"] == []
            unicode_query["position"]["character"] = utf16_column(updated, updated.rindex("step13("))
            # Hover may be empty while the final asynchronous check is pending.
            # It must never return an earlier version's symbol at this position.
            deadline = time.monotonic() + 20
            request_id = 100
            while True:
                send("textDocument/hover", unicode_query, request_id)
                hover = response(request_id)["result"]
                if hover is not None:
                    assert hover["contents"]["value"] == "step13(n: int) -> int", hover
                    break
                assert time.monotonic() < deadline, "final buffer analysis did not become available"
                request_id += 1
                time.sleep(0.02)
            send("textDocument/completion", unicode_query, 29)
            labels = {item["label"] for item in response(29)["result"]["items"]}
            assert "step13" in labels and "inc" not in labels, labels
            assert not any(f"step{version}" in labels for version in range(4, 13)), labels

            bad = "// 한글\nprogram Example { fn inc(): int { return @ } }"
            bad_uri, items = open_document("bad.aml", bad)
            assert len(items) == 1 and items[0]["code"] == "AMLC000", items
            point = {"line": 1, "character": bad.splitlines()[1].index("@")}
            assert items[0]["range"] == {"start": point, "end": point}, items
            send("textDocument/diagnostic", {"textDocument": {"uri": bad_uri}}, 4)
            assert response(4)["result"]["items"] == items

            send("textDocument/didChange", {"textDocument": {"uri": bad_uri, "version": 2},
                 "contentChanges": [{"text": source}]})
            assert diagnostics(bad_uri) == []

            _, items = open_document("term.aml", "program Demo { term unit }")
            assert items == [], items
            _, items = open_document("signed.aml",
                "program Unsafe { public fn transfer(amount: int): int { return amount } }")
            assert items == [], items
            _, items = open_document("imports.aml",
                'import inc from "./missing.aml"\nprogram P { fn run(): int { return inc(1) } }')
            assert any(item["code"] == "AMLC000" and item["severity"] == 1 for item in items), items
            interface = 'interface I { fn inc(n: int): int }'
            dependency_uri, _ = open_document("types.aml", interface)
            imported_uri, items = open_document("linked.aml",
                'import I from "./types.aml"\nprogram P { fn run(): int { return 1 } }')
            assert items == [], items
            send("textDocument/didChange", {"textDocument": {"uri": dependency_uri, "version": 2},
                 "contentChanges": [{"text": "interface Other { fn inc(n: int): int }"}]})
            assert any("imported interface is absent" in d["message"] for d in diagnostics(imported_uri))
            send("textDocument/didChange", {"textDocument": {"uri": dependency_uri, "version": 3},
                 "contentChanges": [{"text": interface}]})
            assert diagnostics(imported_uri) == []
            send("textDocument/didClose", {"textDocument": {"uri": dependency_uri}})
            assert any("source is absent" in d["message"] for d in diagnostics(imported_uri))
            _, items = open_document("unlocated.aml",
                "program P { fn run(): int { return unknown_value } }")
            assert any("did not supply a source location" in item["message"] for item in items), items
            assert not (root / "unsaved").exists()

            project = root / "disk-project"
            project.mkdir()
            types = project / "types.aml"
            types.write_text(interface)
            disk_uri, items = open_document("disk.aml",
                'import I from "./types.aml"\nprogram P { fn run(): int { return 1 } }',
                project / "main.aml")
            assert items == [], items
            # Watch the dependent document directly: worker notifications can
            # arrive before the overlay's own diagnostics.
            overlay_uri = types.as_uri()
            send("textDocument/didOpen", {"textDocument": {
                "uri": overlay_uri, "languageId": "aml", "version": 1, "text": "invalid overlay"}})
            assert diagnostics(disk_uri), "invalid open buffer must not fall back to valid disk source"
            send("textDocument/didClose", {"textDocument": {"uri": overlay_uri}})
            assert diagnostics(disk_uri) == [], "closing overlay must restore disk source"
            outside = root / "outside.aml"
            outside.write_text(interface)
            (project / "huge.aml").write_text(" " * 1_000_001)
            rejected = ["../outside.aml", "./huge.aml"]
            if os.name != "nt":
                (project / "escape.aml").symlink_to(outside)
                os.mkfifo(project / "pipe.aml")
                rejected.extend(("./escape.aml", "./pipe.aml"))
            for index, target in enumerate(rejected):
                _, items = open_document(f"boundary{index}.aml",
                    f'import I from "{target}"\nprogram P {{ fn run(): int {{ return 1 }} }}',
                    project / f"boundary{index}.aml")
                assert any("source is absent" in d["message"] for d in items), (target, items)

            send("shutdown", request_id=5)
            assert response(5)["result"] is None
            send("exit")
            assert process.wait(timeout=5) == 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            stderr = process.stderr.read().decode()
            if stderr:
                print(stderr, file=sys.stderr)
    path_note = "empty PATH" if os.name != "nt" else "native Windows runtime PATH"
    print(f"Official AMLC LSP: diagnostics, declaration ranges, import overlays/bounds, and capability limits passed ({path_note}).")


if __name__ == "__main__":
    main()
