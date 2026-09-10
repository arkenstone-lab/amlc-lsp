"""Exercise the real checker, including buffers that do not compile yet."""
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time


def overlay_options(directory, overlays):
    if overlays is None:
        return []
    path = directory / "overlays.json"
    path.write_text(json.dumps({str((directory / name).resolve()): text
                                for name, text in overlays.items()}))
    return ["--overlays=json", str(path)]


def complete(checker, directory, source, overlays=None):
    offset = len(source.split("|", 1)[0].encode())
    path = directory / "main.aml"
    path.write_text(source.replace("|", "", 1))
    result = subprocess.run(
        [checker, "check", str(path), "--completion=json", str(offset)]
        + overlay_options(directory, overlays),
        check=True, capture_output=True, text=True, timeout=10,
    )
    return {item["label"]: item for item in json.loads(result.stdout)["items"]}


def benchmark():
    # Includes checker startup and JSON decoding, but not the LSP transport.
    with tempfile.TemporaryDirectory(prefix="amlc-completion-bench-") as tmp:
        for count in (100, 1000, 5000):
            source = ('program P { fn f(): int {\n'
                      + 'let value = 1\n' * count + '|return value\n} }')
            samples = []
            for _ in range(5):
                start = time.perf_counter()
                items = complete(sys.argv[1], Path(tmp), source)
                samples.append((time.perf_counter() - start) * 1000)
                assert items["value"]["detail"] == "int", items
            print(f"{count:5d} bindings: median {statistics.median(samples):.1f} ms, "
                  f"max {max(samples):.1f} ms", flush=True)


def definition(checker, directory, source, overlays=None, *, command="--definition=json", roots=None, replacement=None):
    path = directory / "main.aml"
    path.write_text(source.replace("|", "", 1))
    result = subprocess.run(
        [checker, "check", str(path), command,
         str(len(source.split("|", 1)[0].encode()))]
        + (["--workspace-roots=json", json.dumps([str(root.resolve()) for root in roots])]
           if roots is not None else [])
        + (["--new-name", replacement] if replacement is not None else [])
        + overlay_options(directory, overlays),
        check=True, capture_output=True, text=True, timeout=10,
    )
    return json.loads(result.stdout)


def main():
    with tempfile.TemporaryDirectory(prefix="amlc-completion-") as tmp:
        directory = Path(tmp)
        library = directory / "diagnostic-library.aml"
        saved_library = 'program Library { public fn helper(): int { return 1 } }'
        library.write_text(saved_library)
        importer = '// import ignored from "./absent.aml"\n  import helper from "./diagnostic-library.aml"\nprogram Main {}'

        def diagnostics(source=importer, overlays=None):
            path = directory / "main.aml"
            path.write_text(source)
            result = subprocess.run(
                [sys.argv[1], "check", str(path), "--diagnostics=json"]
                + overlay_options(directory, overlays),
                capture_output=True, text=True, timeout=10,
            )
            assert result.returncode in (0, 1), result.stderr
            return [json.loads(line) for line in result.stdout.splitlines()]

        assert diagnostics() == []
        typed_importer = importer.replace('program Main {}',
            'program Main { fn run(): int { return helper() } }')
        assert diagnostics(typed_importer) == []
        for source in (typed_importer.replace('helper()', 'helper(true)'),
                       typed_importer.replace('run(): int', 'run(): bool'),
                       'program P { fn run(): int { return absent(1) } }'):
            items = diagnostics(source)
            assert items and items[0]['code'] == 'REHOVOT301', items
        typed_library = 'program Library { public fn helper(value: bool): int { return 1 } }'
        items = diagnostics(typed_importer.replace('helper()', 'helper(1)'), {library.name: typed_library})
        assert items and 'argument type differs' in items[0]['message'], items
        assert diagnostics(typed_importer.replace('helper()', 'helper(true)'), {library.name: typed_library}) == []
        items = diagnostics(typed_importer, {library.name: saved_library.replace('return 1', 'return true')})
        assert items[0]['code'] == 'REHOVOT301' and items[0]['start']['line'] == 2, items
        assert library.name in items[0]['message'], items
        stateful_library = 'contract Library { state { total: int } public fn helper(): int { return self.total } }'
        assert diagnostics(typed_importer, {library.name: stateful_library}) == []
        const_importer = 'import answer from "./constants.aml"\nprogram Main { fn run(): int { return answer } }'
        const_library = 'program Constants { const local = 1\nconst answer = local }'
        items = diagnostics(const_importer, {'constants.aml': const_library})
        assert items == [], items
        items = diagnostics(const_importer.replace('return answer', 'let local = false\nreturn answer'),
                            {'constants.aml': const_library})
        assert items == [], items
        items = diagnostics(const_importer, {'constants.aml': const_library.replace('local = 1', 'local = true')})
        assert items and items[0]['code'] == 'REHOVOT301', items
        forms = ('program Forms { form plus [many left: int] (many right: int) '
                 '->[many] int marks {} = left + right }')
        form_importer = ('import plus from "./forms.aml"\n'
                         'program Main { fn run(): int { return plus(1, 2) } }')
        items = diagnostics(form_importer, {'forms.aml': forms})
        assert items == [], items
        for source, dependency in [
            (form_importer.replace('plus(1, 2)', 'plus(true, 2)'), forms),
            (form_importer, forms.replace('left + right', 'true')),
        ]:
            items = diagnostics(source, {'forms.aml': dependency})
            assert items and items[0]['code'] == 'REHOVOT301', items
        using_form = form_importer.replace('plus(1, 2)', 'use plus[1](2) as many value: int in value')
        items = diagnostics(using_form, {'forms.aml': forms})
        assert items == [], items
        items = diagnostics(using_form.replace('value: int', 'value: bool'), {'forms.aml': forms})
        assert items and items[0]['code'] == 'REHOVOT301', items
        private_form = forms.replace('program Forms {',
            'program Forms { private pure fn hidden(n: int): int { return n }').replace('left + right', 'hidden(left) + right')
        items = diagnostics(using_form, {'forms.aml': private_form})
        assert items == [], items
        shadowed = using_form.replace('program Main {',
            'program Main { private pure fn hidden(n: int): bool { return true }')
        items = diagnostics(shadowed, {'forms.aml': private_form})
        assert items == [], items
        items = diagnostics(form_importer.replace('plus(1, 2)', 'hidden(1)'), {'forms.aml': private_form})
        assert items and 'function is undefined name = hidden' in items[0]['message'], items
        other_form = forms.replace('program Forms {',
            'program Forms { private pure fn hidden(n: int): bool { return true }')
        other_form = other_form.replace('plus ', 'other ').replace('left + right', 'if hidden(left) then right else left')
        both_forms = using_form.replace('program Main {',
            'import other from "./other-forms.aml"\nprogram Main {')
        both_forms = both_forms.replace('in value', 'in use other[1](2) as many next: int in value + next')
        items = diagnostics(both_forms, {'forms.aml': private_form, 'other-forms.aml': other_form})
        assert items == [], items
        for text, code in [
            ('program Library {}', 'REHOVOT202'),
            (saved_library.replace('public ', 'private '), 'REHOVOT202'),
            ('\n\n\nprogram Library { fn', 'REHOVOT203'),
            (' ' * 1_000_001, 'REHOVOT204'),
        ]:
            items = diagnostics(overlays={library.name: text})
            assert len(items) == 1 and items[0]['code'] == code, items
            assert items[0]['start'] == {'line': 2, 'column': 3}, items
        assert diagnostics(overlays={library.name: saved_library}) == []
        assert library.read_text() == saved_library
        library.write_text('program Library { fn')
        assert diagnostics()[0]['code'] == 'REHOVOT203'
        assert diagnostics(overlays={library.name: saved_library}) == []
        library.write_text(saved_library)
        new_importer = importer.replace(library.name, 'new-library.aml')
        assert diagnostics(new_importer)[0]['code'] == 'REHOVOT201'
        assert diagnostics(new_importer, {'new-library.aml': saved_library}) == []
        assert not (directory / 'new-library.aml').exists()
        recursive_root = importer.replace(library.name, 'one.aml')
        one = 'import helper from "./two.aml"\n' + saved_library
        graph_sources = {'one.aml': one, 'two.aml': saved_library}
        assert diagnostics(recursive_root, graph_sources) == []
        for leaf, code in [('program Library { fn', 'REHOVOT203'),
                           ('program Library {}', 'REHOVOT202'),
                           ('import helper from "./one.aml"\n' + saved_library, 'REHOVOT206')]:
            items = diagnostics(recursive_root, {**graph_sources, 'two.aml': leaf})
            assert len(items) == 1 and items[0]['code'] == code, items
            assert items[0]['start'] == {'line': 2, 'column': 3}, items
            assert './one.aml' in items[0]['message'] and './two.aml' in items[0]['message'], items
        assert diagnostics(recursive_root, {'one.aml': one})[0]['code'] == 'REHOVOT201'
        repeated = 'import helper from "./two.aml"\n' * 40 + saved_library
        assert diagnostics(recursive_root, {**graph_sources, 'one.aml': repeated}) == []
        diamond = 'import helper from "./left.aml"\nimport helper from "./right.aml"\n' + saved_library
        assert diagnostics(recursive_root, {**graph_sources, 'one.aml': diamond,
                                           'left.aml': one, 'right.aml': one}) == []
        deep = {f'depth-{i}.aml': f'import helper from "./depth-{i+1}.aml"\n' + saved_library
                for i in range(34)}
        deep['depth-34.aml'] = saved_library
        assert diagnostics(importer.replace(library.name, 'depth-0.aml'), deep)[0]['code'] == 'REHOVOT205'
        heavy = {f'heavy-{i}.aml': (f'import helper from "./heavy-{i+1}.aml"\n' if i < 8 else '')
                 + saved_library + ' ' * 950_000 for i in range(9)}
        assert diagnostics(importer.replace(library.name, 'heavy-0.aml'), heavy)[0]['code'] == 'REHOVOT205'

        def metadata(source, overlays=None):
            path = directory / 'main.aml'
            path.write_text(source)
            result = subprocess.run(
                [sys.argv[1], 'check', str(path), '--analysis-metadata=json']
                + overlay_options(directory, overlays),
                check=True, capture_output=True, text=True, timeout=10)
            return json.loads(result.stdout)['dependencies']

        nested_library = f'import helper from "./{library.name}"\nprogram Middle {{}}'
        (directory / 'middle.aml').write_text(nested_library)
        root = 'import helper from "./middle.aml"\nprogram Main { fn'
        graph = metadata(root)
        assert graph == {'paths': sorted([str(library.resolve()), str((directory / 'middle.aml').resolve())]),
                         'complete': True}, graph
        graph = metadata(root, {'middle.aml': 'program Middle {}'})
        assert graph['complete'] and graph['paths'] == [str((directory / 'middle.aml').resolve())], graph
        assert not metadata(root, {'middle.aml': 'import helper from'})['complete']
        assert not metadata(new_importer)['complete']
        cyclic = 'import helper from "./middle.aml"\nprogram Library {}'
        graph = metadata(root, {library.name: cyclic})
        assert graph['complete'] and len(graph['paths']) == 2, graph
        many_imports = '\n'.join(f'import helper from "./limit-{i}.aml"' for i in range(33))
        for text in (saved_library, 'program Library { fn'):
            items = diagnostics(many_imports + '\nprogram Main {}',
                                {f'limit-{i}.aml': text for i in range(33)})
            assert items[-1]['code'] == 'REHOVOT205', items

        def check(source):
            return complete(sys.argv[1], directory, source)
        items = check('program Fib { fn fib(n: int): int {\nlet a = 0\nlet b = 1\n|return a\n} }')
        assert {"n", "a", "b"} <= items.keys(), items
        assert items["a"]["detail"] == "int"
        form = 'program P { form f [many cap: u128] (many arg: u128) ->[many] u128 marks {} = '
        items = check(form + '|arg }')
        assert {'cap', 'arg'} <= items.keys(), items
        items = check(form + 'let many value: bool = true in |arg }')
        assert items['value']['detail'] == 'bool', items
        items = check(form + 'let many value: u128 = |arg in value }')
        assert 'value' not in items and {'cap', 'arg'} <= items.keys(), items
        items = check(form + 'let many arg: bool = true in |arg }')
        assert items['arg']['detail'] == 'bool', items
        items = check(form + 'split (arg, cap) as many left: u128, many right: u128 in |left }')
        assert {'left', 'right', 'cap', 'arg'} <= items.keys(), items
        items = check(form + 'orbit[3] from arg with many current: u128 => |current }')
        assert 'current' in items and items['current']['detail'] == 'u128', items
        items = check(form + 'use f[cap](arg) as many result: u128 in |result }')
        assert 'result' in items and items['result']['detail'] == 'u128', items
        items = check(form + 'if true then (let many inner: u128 = arg in inner) else |arg }')
        assert 'inner' not in items and 'arg' in items, items
        items = check(form + 'arg\nfn other(): int { |return 0 } }')
        assert 'cap' not in items and 'arg' not in items, items
        items = check('program P {\r\n// 한글\r\nfn f(n: int): int {\r\nlet a = 1\r\n|return a\r\n} }\r\n')
        assert {"n", "a"} <= items.keys() and items["a"]["detail"] == "int", items
        items = check('program P { fn f(n: int): int {\nlet x = 1\nwhile n > 0 {\nlet x = true\n|}\nreturn x\n} }')
        assert items["x"]["detail"] == "bool", items
        items = check('program P { fn f(n: int): int {\nwhile n > 0 { let t = 1 }\n|return n\n} }')
        assert "n" in items and "t" not in items, items
        items = check('program P { fn f(n: int): int {\nlet a = 1\nlet unfinished = |')
        assert "a" in items and "unfinished" not in items, items
        items = check('program P { fn f(n: int): int {\nlet a = |n\nreturn a\n} }')
        assert "n" in items and "a" not in items, items
        items = check('program P { fn f(n: int): int {\nfor i in 0..10 {\n|}\nreturn n\n} }')
        assert "i" in items and "n" in items, items
        items = check('program P { fn f(n: int): int { return n }\n|}')
        assert "n" not in items, items
        items = check('program P { fn f(n: int): int {\nlet next = 1\nne|\n} }')
        assert set(items) == {"next"}, items
        items = check('program P { fn f(n: int): int {\n// hidden |n\nreturn n\n} }')
        assert not items, items
        items = check('program P { fn f(n: int): int {\n// hidden n|')
        assert not items, items
        items = check('program P { fn f(n: int): int {\nlet s = "hidden |n"\nreturn n\n} }')
        assert not items, items
        items = check('contract P { state { total: u128 }\nfn f(): u128 { return self.| } }')
        assert set(items) == {"total"}, items
        items = check('contract P { state { total: u128 }\nfn f(): u128 {\nself.|\n} }')
        assert set(items) == {"total"}, items
        items = check('contract P { struct Point { x: int, y: int }\nfn f(p: Point): int { return p.| } }')
        assert set(items) == {"x", "y"}, items
        storage = ('contract P { struct Point { x: int, y: int }\n'
                   'struct Profile { position: Point }\n'
                   'state { profile: Profile, count: int }\n'
                   'fn f(): int {\n')
        local_chain = storage.replace('fn f()', 'fn f(p: Profile)')
        items = check(local_chain + 'return p.position.| } }')
        assert set(items) == {'x', 'y'}, items
        items = check(local_chain + 'let alias = p\nreturn alias.position.x| } }')
        assert set(items) == {'x'} and items['x']['detail'] == 'int', items
        for receiver in ('p.missing', 'p.position.x', 'p..position'):
            assert not check(local_chain + 'return ' + receiver + '.| } }')
        assert not check(local_chain + 'let p = 1\nreturn p.position.| } }')
        # Completion recovery must not silently change language diagnostics.
        assert diagnostics(local_chain + 'return p.position.x } }')
        items = check(storage + 'return self.profile.| } }')
        assert set(items) == {"position"}, items
        items = check(storage + 'return self.profile.position.| } }')
        assert set(items) == {"x", "y"}, items
        items = check(storage + 'return self.profile.position.x| } }')
        assert set(items) == {"x"} and items["x"]["detail"] == "int", items
        items = check(storage + 'self.profile.position.|')
        assert set(items) == {"x", "y"}, items
        indexed_storage = storage.replace('profile: Profile', 'profile: map[string]list[Profile]')
        for receiver in ('self.profile["]"][0]', 'self.profile[key(1)][index(2)]'):
            items = check(indexed_storage + 'return ' + receiver + '.| } }')
            assert set(items) == {'position'}, (receiver, items)
            items = check(indexed_storage + 'return ' + receiver + '.position.| } }')
            assert set(items) == {'x', 'y'}, (receiver, items)
        for receiver in ('self.profile[0]', 'self.profile[0][1][2]'):
            assert not check(indexed_storage + 'return ' + receiver + '.| } }')
        for receiver in ("self.count", "self.missing", "self.profile.missing",
                         "self.profile.position.x", "self..profile", "p.position"):
            items = check(storage + 'return ' + receiver + '.| } }')
            assert not items, (receiver, items)
        factory = ('program P { struct Point { x: int, y: int }\n'
                   'private fn make_point(p: Point): Point { return p }\n'
                   'fn f(seed: Point): int {\n')
        items = check(factory + 'let p = make_point(seed)\nlet alias = p\nreturn alias.| } }')
        assert set(items) == {"x", "y"}, items
        items = check(factory + 'let make_point = 1\nlet p = make_point(seed)\nreturn p.| } }')
        assert not items, items
        items = check(factory + 'let p = unknown(seed)\nreturn p.| } }')
        assert not items, items
        items = check(factory + 'let p: int = make_point(seed)\nreturn p.| } }')
        assert not items, items
        items = check(factory + 'let p = make_point(seed)\nreturn p.|')
        assert set(items) == {"x", "y"}, items
        (directory / "point.aml").write_text(
            'program Points { struct Point { x: int, y: int }\n'
            'public fn make_point(p: Point): Point { return p }\n'
            'private fn hidden(p: Point): Point { return p }\n}')
        imported_factory = ('import Point, make_point from "./point.aml"\n'
                            'program P { fn f(seed: Point): int {\n')
        items = check(imported_factory + 'let p = make_point(seed)\nreturn p.| } }')
        assert set(items) == {"x", "y"}, items
        items = check(imported_factory + 'let p = hidden(seed)\nreturn p.| } }')
        assert not items, items
        items = check('import Point from "./point.aml"\n'
                      'contract P { state { position: Point }\n'
                      'fn f(): int { return self.position.| } }')
        assert set(items) == {"x", "y"}, items
        (directory / "lib.aml").write_text('program Lib {\npublic fn helper(n: int): int { return n }\nprivate fn hidden(): int { return 0 }\n}')
        source = 'import helper from "./lib.aml"\nprogram P { fn f(): int { return hel|per(1) } }'
        items = check(source)
        assert set(items) == {"helper"}, items
        result = subprocess.run(
            [sys.argv[1], "check", str(directory / "main.aml"), "--definition=json",
             str(len(source.split("|", 1)[0].encode()))],
            check=True, capture_output=True, text=True, timeout=10,
        )
        target = json.loads(result.stdout)
        assert Path(target["path"]) == (directory / "lib.aml").resolve(), target
        data = (directory / "lib.aml").read_bytes()
        assert data[target["start"]:target["end"]] == b"helper", target
        items = check('import hidden from "./lib.aml"\nprogram P { fn f(): int { return hid|den() } }')
        assert "hidden" not in items, items
        (directory / "other.aml").write_text(
            'program Other { public fn helper(n: bool): bool { return n }\n'
            'struct Point { wrong: bool } }')
        ambiguous = ('import helper from "./lib.aml"\n'
                     'import helper from "./other.aml"\n'
                     'program P { fn f(): int { return hel|per(1) } }')
        assert "helper" not in check(ambiguous)
        assert definition(sys.argv[1], directory, ambiguous) is None
        repeated = ('import helper from "./lib.aml"\n'
                    'import helper from "././lib.aml"\n'
                    'program P { fn f(): int { return hel|per(1) } }')
        assert "helper" in check(repeated)
        assert definition(sys.argv[1], directory, repeated) is not None
        for body in ('let helper = 1\nreturn hel|per',
                     'while true { let helper = 1\nreturn hel|per }\nreturn 0'):
            source = 'import helper from "./lib.aml"\nprogram P { fn f(): int {\n' + body + '\n} }'
            assert check(source)["helper"]["kind"] == 6
            assert definition(sys.argv[1], directory, source) is None
        source = ('import helper from "./lib.aml"\nprogram P { fn f(): int {\n'
                  'while true { let helper = 1 }\nreturn hel|per(1)\n} }')
        assert check(source)["helper"]["kind"] == 3
        assert definition(sys.argv[1], directory, source) is not None
        source = ('import helper from "./lib.aml"\nprogram P {\n'
                  'fn helper(n: int): int { return n }\nfn f(): int { return hel|per(1) } }')
        assert definition(sys.argv[1], directory, source) is None
        source = ('import Point from "./point.aml"\nimport Point from "./other.aml"\n'
                  'program P { fn f(p: Point): int { return p.| } }')
        assert not check(source)
        source = ('import Point from "./point.aml"\n'
                  'program P { struct Point { wrong: bool }\n'
                  'fn f(p: Point): int { return p.| } }')
        assert not check(source)
        source = ('import helper from "./lib.aml"\nimport helper from "./other.aml"\n'
                  'program P { fn f(): int { let result = helper(1)\nres|\n} }')
        assert "detail" not in check(source)["result"]
        disk = (directory / "lib.aml").read_text()
        edited = '// unsaved 한글\nprogram Lib {\npublic fn fresh(): bool { return true }\n}'
        source = 'import fresh from "./lib.aml"\nprogram P { fn f(): bool { return fre|sh() } }'
        items = complete(sys.argv[1], directory, source, {"lib.aml": edited})
        assert items["fresh"]["detail"] == "bool", items
        target = definition(sys.argv[1], directory, source, {"lib.aml": edited})
        assert edited.encode()[target["start"]:target["end"]] == b"fresh", target
        assert (directory / "lib.aml").read_text() == disk
        assert "fresh" not in check(source)
        for text in ('program Lib {}', 'program Lib { public fn helper('):
            source = 'import helper from "./lib.aml"\nprogram P { fn f(): int { return hel|per(1) } }'
            assert "helper" not in complete(sys.argv[1], directory, source, {"lib.aml": text})
            assert definition(sys.argv[1], directory, source, {"lib.aml": text}) is None
        source = 'import fresh from "./new.aml"\nprogram P { fn f(): bool { return fre|sh() } }'
        assert "fresh" in complete(sys.argv[1], directory, source, {"new.aml": edited})
        assert definition(sys.argv[1], directory, source, {"new.aml": edited}) is not None
        assert not (directory / "new.aml").exists()
        source = ('import Point from "./point.aml"\n'
                  'contract P { state { position: Point }\nfn f(): int { return self.position.| } }')
        items = complete(sys.argv[1], directory, source,
                         {"point.aml": 'program Points { struct Point { updated: bool } }'})
        assert set(items) == {"updated"} and items["updated"]["detail"] == "bool", items
        def refs(source, overlays=None):
            return definition(sys.argv[1], directory, source, overlays, command="--references=json")["items"]
        source = ('import helper from "./lib.aml"\nprogram P { fn f(): int {\n'
                  '// helper(1)\nlet text = "helper(1)"\n'
                  'while true { let helper = 1\nhelper(1) }\nreturn hel|per(1)\n} }')
        other = 'import helper from "./lib.aml"\nprogram Other { fn f(): int { return helper(2) } }'
        unrelated = 'program Other { fn helper(): int { return 0 }\nfn f(): int { return helper() } }'
        found = refs(source, {"consumer.aml": other, "unrelated.aml": unrelated})
        assert len(found) == 5, found
        assert sum(item["role"] == "declaration" for item in found) == 1, found
        assert {Path(item["path"]).name for item in found} == {"main.aml", "lib.aml", "consumer.aml"}
        for item in found:
            text = {"main.aml": source.replace("|", ""), "lib.aml": disk, "consumer.aml": other}[Path(item["path"]).name]
            assert text.encode()[item["start"]:item["end"]] == b"helper", item
        assert not refs('import helper from "./lib.aml"\nprogram P { fn f(helper: int): int { return hel|per } }')
        assert not refs(ambiguous)
        declaration = 'program Lib { public fn hel|per(n: int): int { return n } }'
        # The current source is main.aml, so its direct consumer must import that path.
        found = refs(declaration, {"consumer.aml": other.replace("./lib.aml", "./main.aml")})
        assert len(found) == 3, found
        workspace = directory / "workspace"
        workspace.mkdir()
        (workspace / "consumer.aml").write_text(other.replace("./lib.aml", "../main.aml"))
        (workspace / "unrelated.aml").write_text(unrelated)
        (workspace / "_build").mkdir()
        (workspace / "_build" / "ignored.aml").write_text("broken")
        result = definition(sys.argv[1], directory, declaration, command="--references=json", roots=[workspace])
        assert result["complete"] and len(result["items"]) == 3, result
        assert any(Path(item["path"]).name == "consumer.aml" for item in result["items"])
        result = definition(sys.argv[1], directory, declaration,
                            {"workspace/consumer.aml": "program Empty {}"},
                            command="--references=json", roots=[workspace])
        assert len(result["items"]) == 1, result
        (workspace / "broken.aml").write_text("program Broken {")
        result = definition(sys.argv[1], directory, declaration, command="--references=json", roots=[workspace])
        assert not result["complete"] and len(result["items"]) == 3, result
        limited = directory / "limited"
        limited.mkdir()
        for number in range(257):
            (limited / f"file{number:03d}.aml").write_text("program Empty {}")
        result = definition(sys.argv[1], directory, declaration, command="--references=json", roots=[limited])
        assert not result["complete"], result
        rename_dir = directory / "rename"
        rename_dir.mkdir()
        consumer = 'import helper from "./main.aml"\nprogram C { fn f(): int { return helper(1) } }'
        (rename_dir / "consumer.aml").write_text(consumer)
        def rename(source=declaration, replacement="renamed", overlays=None, roots=None):
            return definition(sys.argv[1], rename_dir, source, overlays, command="--rename=json",
                              roots=[rename_dir] if roots is None else roots, replacement=replacement)
        result = rename()
        assert result["name"] == "helper" and len(result["items"]) == 3, result
        assert (rename_dir / "consumer.aml").read_text() == consumer
        assert rename(replacement="fn") is None
        assert rename(replacement="1invalid") is None
        assert rename(replacement="f") is None
        assert rename(roots=[]) is None
        shadow = consumer.replace('return helper(1)', 'let helper = 1\nreturn helper(1)')
        assert rename(overlays={"consumer.aml": shadow}) is None
        capture = consumer.replace('fn f()', 'fn f(renamed: int)')
        assert rename(overlays={"consumer.aml": capture}) is None
        assert rename(overlays={"consumer.aml": 'program Broken {'}) is None
        assert rename(roots=[limited]) is None
        # A declaration outside the configured roots must never receive edits.
        assert rename(roots=[workspace]) is None
        for excluded in ("_build", "node_modules", ".hidden"):
            target = rename_dir / excluded
            target.mkdir()
            (target / "library.aml").write_text(declaration.replace("|", ""))
            source = ('import helper from "./' + excluded + '/library.aml"\n'
                      'program P { fn f(): int { return hel|per(1) } }')
            assert rename(source, overlays={"consumer.aml": "program Empty {}"}) is None, excluded
        oversized = directory / "oversized"
        oversized.mkdir()
        (oversized / "large.aml").write_text(" " * 1_000_001)
        result = definition(sys.argv[1], directory, declaration, command="--references=json", roots=[oversized])
        assert not result["complete"], result
    print("compiler completion tests passed")


if __name__ == "__main__":
    if "--benchmark" in sys.argv[2:]:
        benchmark()
    else:
        main()
