open Amlc_analysis

let require condition message = if not condition then failwith message

let index_of source needle =
  let width = String.length needle in
  let rec find index =
    if index + width > String.length source then failwith ("missing " ^ needle) else
    if String.sub source index width = needle then index else find (index + 1) in
  find 0

let check_ranges source analysis =
  List.iter (fun declaration -> List.iter (fun { first; last } ->
    require (String.sub source first (last - first) = declaration.name)
      ("use range: " ^ declaration.name)) declaration.uses) analysis.declarations;
  List.iter (fun declaration -> match declaration.selection with
    | Some { first; last } -> require (String.sub source first (last - first) = declaration.name)
        ("declaration range: " ^ declaration.name)
    | None -> failwith ("missing declaration range: " ^ declaration.name)) analysis.declarations

let () =
  let location = Amlc_analysis__Compiler_location.offset in
  let location_source = "// 한글😀\r\n  return true\r\n" in
  let second_line = String.index location_source '\n' + 1 in
  require (location ~source:location_source "line 2 column 3: type mismatch"
    = Some (second_line + 2)) "compiler message byte location";
  require (location ~source:location_source "line 2: type mismatch"
    = Some second_line) "compiler line-only location";
  require (location ~source:location_source "line 1 column 14: type mismatch"
    = Some 13) "UTF-8 location following an emoji";
  require (location ~origin:"[current document]_" ~source:location_source
    "source = [current document]_ line 2 column 3: type mismatch"
    = Some (second_line + 2)) "exact main source header";
  List.iter (fun message -> require (location ~source:location_source message = None)
    ("reject compiler location: " ^ message))
    ["line 0 column 1: error"; "line 2 column 0: error";
     "line 9 column 1: error"; "line 2 column 999: error";
     "line 999999999999999999999999 column 1: error";
     "line 1 column 5: error"; "line -1 column 1: error";
     "line 2 column 3 error"; "error mentions line 2 column 3: error";
     "source = dependency.aml line 2 column 3: error"; "error without location"];
  List.iter (fun message -> require
    (location ~origin:"[current document]_" ~source:location_source message = None)
    "do not map foreign source headers")
    ["source = dependency.aml line 2 column 3: error";
     "source = [current document] line 2 column 3: error";
     "line 2 column 3: error"];

  let valid = analyze "program Demo { term unit }" in
  require (valid.status = Checked && valid.diagnostics = []) "valid term";
  require (List.exists (fun d -> d.name = "Demo") valid.declarations) "program name";
  check_ranges "program Demo { term unit }" valid;

  let invalid = analyze ~syntax:Term "program Broken { term @ }" in
  (match invalid.diagnostics with
   | [{ span = Some { first = 22; last = 23 }; _ }] -> ()
   | _ -> failwith "structured term error range");

  let form_source =
    "program Demo { form identity [] (many value: int) ->[many] int marks {} = value term identity(1) }" in
  let forms = analyze form_source in
  require (forms.diagnostics = []) "valid form";
  check_ranges form_source forms;
  require (List.exists (fun d -> d.name = "identity" && d.parameters = ["value"])
    forms.declarations) "form metadata";
  let identity = List.find (fun d -> d.kind = "form" && d.name = "identity") forms.declarations in
  require (List.length identity.uses = 1) "direct term call";
  let term_value = List.find (fun d -> d.kind = "parameter" && d.name = "value") forms.declarations in
  require (term_value.return_type = Some "int" && term_value.visibility = []
    && List.length term_value.uses = 1) "term parameter declaration and body use";
  let term_shadow_source = "program P { form identity [] (many value: int) ->[many] int marks {} = let many value: int = value in value term identity(1) }" in
  let term_shadow = analyze term_shadow_source in
  require (term_shadow.diagnostics = []) "term parameter shadow fixture";
  check_ranges term_shadow_source term_shadow;
  let shadowed = List.find (fun d -> d.kind = "parameter" && d.name = "value") term_shadow.declarations in
  require (List.length shadowed.uses = 1) "shadowed term parameter keeps the initializer use";
  let shadowed_use = List.hd shadowed.uses in
  require (shadowed_use.first > String.rindex term_shadow_source '='
    && shadowed_use.first < index_of term_shadow_source " in ")
    "the shadowed body use is not a parameter use";
  let term_add_source = "program P { form add [many left: int] (many right: int) ->[many] int marks {} = /* left */ left + right term add(1, 2) }" in
  let term_add = analyze term_add_source in
  require (term_add.diagnostics = []) "two-parameter term fixture";
  check_ranges term_add_source term_add;
  List.iter (fun name ->
    let parameter = List.find (fun d -> d.kind = "parameter" && d.name = name) term_add.declarations in
    require (parameter.return_type = Some "int" && List.length parameter.uses = 1)
      ("term parameter use: " ^ name)) ["left"; "right"];
  require (not (List.exists (fun d -> List.exists (fun span -> span.first = index_of term_add_source "/* left */" + 3) d.uses)
    term_add.declarations)) "a commented term name is not a parameter use";
  let added = List.find (fun d -> d.kind = "form" && d.name = "add") term_add.declarations in
  require (List.length added.uses = 1) "direct term call with two arguments";
  let term_call_source =
    "program P { form identity [] (many item: int) ->[many] int marks {} = item form relay [] (many value: int) ->[many] int marks {} = identity(value) + value term relay(1) }" in
  let term_call = analyze term_call_source in
  require (term_call.diagnostics = []) "a term form calls another form";
  check_ranges term_call_source term_call;
  let relay_value = List.find (fun d -> d.kind = "parameter" && d.name = "value")
    term_call.declarations in
  let call_value = index_of term_call_source "identity(value)" + String.length "identity(" in
  let following_value = index_of term_call_source ") + value" + String.length ") + " in
  require (List.map (fun span -> span.first) relay_value.uses = [call_value; following_value])
    "inlined form calls retain the caller parameter's source uses";
  List.iter (fun name ->
    let form = List.find (fun d -> d.kind = "form" && d.name = name) term_call.declarations in
    require (List.length form.uses = 1) ("nested term call target: " ^ name))
    ["identity"; "relay"];
  let invalid_term = analyze "program P { form identity [] (many value: int) ->[many] int marks {} = value + true term identity(1) }" in
  require (invalid_term.diagnostics <> []) "invalid term preserves the compiler error";
  require (List.for_all (fun d -> d.kind <> "parameter") invalid_term.declarations)
    "failed term check publishes no parameter symbols";
  require (List.for_all (fun d -> d.kind <> "form" || d.uses = []) invalid_term.declarations)
    "failed term check publishes no call uses";

  let callable_form_source = "/* 😀 value */ program P { form identity [] (many value: int) ->[many] int marks {} = (let many value: int = value in value) + value fn run(value: int): int { return value } }" in
  let callable_forms = analyze ~syntax:Callable callable_form_source in
  require (callable_forms.diagnostics = []) ("callable form binding fixture: " ^
    String.concat "; " (List.map (fun d -> d.message) callable_forms.diagnostics));
  check_ranges callable_form_source callable_forms;
  let form_parameter = List.find (fun d -> d.kind = "parameter" && List.length d.uses = 2)
    callable_forms.declarations in
  require (form_parameter.name = "value" && form_parameter.return_type = Some "int")
    "typed form parameter and restored outer uses";
  let form_local = List.find (fun d -> d.kind = "local") callable_forms.declarations in
  require (List.length form_local.uses = 1) "form body term binder is indexed";
  let inner_use = List.hd form_local.uses in
  require (not (List.exists (fun scope -> scope.first <= inner_use.first && inner_use.first < scope.last)
    form_parameter.visibility)) "form parameter completion is hidden inside shadowing body";
  require (List.length (List.filter (fun d -> d.kind = "parameter" && List.length d.uses = 1)
    callable_forms.declarations) = 1) "ordinary function parameter stays isolated from form";
  let invalid_form = analyze ~syntax:Callable
    "program P { form identity [] (many value: int) ->[many] int marks {} = value + true fn run(): int { return 0 } }" in
  require (invalid_form.diagnostics <> []) "invalid form preserves compiler error";
  require (List.for_all (fun d -> d.kind <> "parameter" || (d.selection = None && d.uses = []))
    invalid_form.declarations) "invalid form cannot retain parameter navigation";
  List.iter (fun header ->
    let source = "program P { " ^ header ^ " ->[many] int marks {} = left + right }" in
    let analysis = analyze ~syntax:Callable source in
    require (analysis.diagnostics = []) ("form header fixture: " ^ header);
    check_ranges source analysis;
    require (List.length (List.filter (fun d -> d.kind = "parameter" &&
      d.return_type = Some "int" && List.length d.uses = 1) analysis.declarations) = 2)
      "capture and public main parameters retain exact uses") [
      "form add [many left: int] (many right: int)";
      "public main(many left: int, many right: int)";
    ];

  let source = "program Example { fn inc(n: int): int { return n + 1 } }" in
  let parsed = analyze source in
  require (parsed.status = Checked && parsed.diagnostics = []) "valid callable";
  require (List.exists (fun d -> d.name = "inc" && d.parameters = ["n"]
    && d.parameter_types = ["int"] && d.return_type = Some "int") parsed.declarations) "function metadata";
  check_ranges source parsed;
  let decoys = "// 한글 fn inc\ninterface I { fn inc(n: int): int }\nprogram Example { fn inc(n: int): int { return n + 1 } }" in
  let located = analyze decoys in
  require (located.diagnostics = []) "interface and comment decoys";
  check_ranges decoys located;
  require (List.exists (fun d -> d.name = "inc" &&
    Option.fold ~none:false ~some:(fun span -> span.first > String.index decoys '}') d.selection)
    located.declarations) "ignore interface method with same name";

  let calls = "// 한글 return inc(0)\nprogram P { fn inc(n: int): int { return n + 1 } fn run(n: int): int { if n > 0 { return inc(n) } return inc(1) } }" in
  let linked = analyze calls in
  require (linked.diagnostics = []) "valid returned calls";
  let inc = List.find (fun d -> d.name = "inc") linked.declarations in
  require (List.length inc.uses = 2) "returned calls in nested blocks";
  List.iter (fun span -> require (String.sub calls span.first (span.last - span.first) = "inc")
    "call name range") inc.uses;
  let shadow = analyze "program P { fn inc(): int { return 1 } fn run(inc: int): int { return inc } }" in
  require (shadow.diagnostics = []) "valid same-named parameter";
  require (List.for_all (fun d -> d.kind <> "function" || d.uses = []) shadow.declarations)
    "variable is not a function use";
  require (List.exists (fun d -> d.kind = "parameter" && d.name = "inc" && List.length d.uses = 1)
    shadow.declarations) "returned parameter resolves to its own declaration";
  let builtin = analyze "program P { fn len(s: string): int { return 42 } fn run(): int { return len(\"hi\") } }" in
  require (builtin.diagnostics = []) "same-named builtin fixture";
  require (List.for_all (fun d -> d.uses = []) builtin.declarations) "builtin is not a user-function use";
  let expression_calls_source = "/* 😀 inc(n) */ program P { fn inc(n: int): int { return n + 1 } fn run(n: int): int { let next = inc(n) n = inc(inc(n)) if inc(n) > 0 { return inc(n) + inc(1) } return next } }" in
  let expression_calls = analyze expression_calls_source in
  require (expression_calls.diagnostics = []) "calls throughout expressions fixture";
  check_ranges expression_calls_source expression_calls;
  require (List.exists (fun d -> d.kind = "function" && d.name = "inc"
    && List.length d.uses = 6) expression_calls.declarations)
    "initializer, nested argument, assignment, condition and return calls are indexed";
  let builtin_expression = analyze "program P { fn len(s: string): int { return 42 } fn run(s: string): int { let size = len(s) return len(s) + size } }" in
  require (builtin_expression.diagnostics = []) "builtin calls inside expressions fixture";
  require (List.for_all (fun d -> d.kind <> "function" || d.uses = []) builtin_expression.declarations)
    "builtin calls must not navigate to same-named functions in any expression";
  let local_calls_source = "program P { fn inc(n: int): int { return n + 1 } fn run(): int { let n = 1 let next = inc(n) if next > 0 { let n = 2 return inc(n) } return inc(next) } }" in
  let local_calls = analyze local_calls_source in
  require (local_calls.diagnostics = []) "local argument call fixture";
  check_ranges local_calls_source local_calls;
  require (List.exists (fun d -> d.kind = "function" && d.name = "inc"
    && List.length d.uses = 3) local_calls.declarations)
    "local and branch-local argument types do not suppress function navigation";
  let signature_prefix = "program P { fn choose(text: string, n: int): int { return n } fn inc(n: int): int { return n } fn run(): int { return " in
  List.iter (fun (suffix, expected) ->
    let source = signature_prefix ^ suffix in
    let analysis = analyze source in
    require (analysis.diagnostics <> []) "unfinished signature fixture preserves diagnostic";
    let at_cursor = List.filter (fun site -> site.signature_start <= String.length source
      && String.length source <= site.signature_end) analysis.signatures in
    let actual = List.map (fun site -> site.signature_name, site.parameter) at_cursor in
    require (actual = expected) ("signature context: " ^ suffix)) [
      "choose(", ["choose", 0];
      "choose(\"a,b\", ", ["choose", 1];
      "choose([1, 2], ", ["choose", 1];
      "choose(/* , ( */ ", ["choose", 0];
      "choose(\"a,b\", inc(", ["inc", 0];
      "choose(\"a,b\", inc(1) + ", ["choose", 1];
      "choose(\"a,b\", unknown(", [];
      "\"choose(", [];
      "// choose(", [];
    ];
  require ((analyze "program P { fn inc(n: int): int { return n } }").signatures = [])
    "function parameter lists are not call sites";
  let builtin_signature = analyze "program P { fn len(s: string): int { return 42 } fn run(): int { return len(" in
  require (builtin_signature.signatures = []) "builtin call must not borrow user signature";
  let form_signature_prefix = "program P { form add [many left: int, many right: int] (many value: int) ->[many] int marks {} = left + right + value form consume [] (once value: int) ->[many] int marks {} = value fn inc(n: int): int { return n } fn run(): int { return " in
  List.iter (fun (suffix, expected) ->
    let source = form_signature_prefix ^ suffix in
    let analysis = analyze source in
    require (analysis.diagnostics <> []) "unfinished form call retains diagnostic";
    let actual = analysis.signatures |> List.filter (fun site ->
      site.signature_start <= String.length source && String.length source <= site.signature_end)
      |> List.map (fun site -> site.signature_name, site.parameter) in
    require (actual = expected) ("form signature context: " ^ suffix)) [
      "add(", ["add", 0]; "add(1, 2, ", ["add", 2];
      "use add[", ["add", 0]; "use add[1, ", ["add", 1];
      "use add[inc(1), ", ["add", 1]; "use add[inc(", ["inc", 0];
      "use add[[1, 2], ", ["add", 1]; "use add[1, 2] /* gap */ (", ["add", 2];
      "use add[1, 2](unknown(", []; "use add[1, 2](1) as ", [];
      "use add[/* , ] ( */ ", ["add", 0]; "use add[\"unterminated", [];
      "use consume[", []; "use consume[](", ["consume", 0];
      "consume(", []; "use inc[](", [];
    ];
  require ((analyze ~syntax:Callable "program P { public main(many value: int) ->[many] int marks {} = value }").signatures = [])
    "public main parameters are not a form call";
  let format_source = "program P {\n fn run(): string {\n let text = \"first\n  second\"\n /* {\n    still } */\n return text\n }\n}\n" in
  let inline_format = analyze "program P {\nfn run(): int {\n/* } */ return 1\n}\n}\n" in
  require (inline_format.diagnostics = []) ("inline comment format fixture: " ^
    String.concat "; " (List.map (fun d -> d.message) inline_format.diagnostics));
  require (inline_format.formatting = Some [0, 0, 0; 1, 0, 1; 2, 0, 2; 3, 0, 1; 4, 0, 0])
    "inline comment indentation layout";
  let format_analysis = analyze format_source in
  require (format_analysis.diagnostics = []) "multiline formatting fixture";
  let layout = Option.get format_analysis.formatting in
  require (not (List.exists (fun (line, _, _) -> List.mem line [2; 3; 4; 5]) layout))
    "multiline string/comment lines are protected";
  let formatted_lines = Array.of_list (String.split_on_char '\n' format_source) in
  List.iter (fun (line, width, depth) ->
    let text = formatted_lines.(line) in
    formatted_lines.(line) <- String.make (depth * 2) ' ' ^ String.sub text width (String.length text - width)) layout;
  let formatted = String.concat "\n" (Array.to_list formatted_lines) in
  require (formatted_lines.(1) = "  fn run(): string {" && formatted_lines.(6) = "    return text")
    "comment braces do not affect code indentation";
  let tokens text =
    let stream = Octra_vm.Oct_lex.make_stream text in
    let rec next found = match Octra_vm.Oct_lex.peek_token stream with
      | Octra_vm.Oct_lang.TkEOF -> List.rev found
      | token -> Octra_vm.Oct_lex.eat stream; next (token :: found) in
    next [] in
  require (tokens format_source = tokens formatted) "formatting preserves the official token stream";
  require ((analyze formatted).diagnostics = []) "formatted source passes official AMLC";
  require ((analyze "program P { fn run(): int { return (").formatting = None)
    "incomplete recovered source is not eligible for formatting";
  let term_format_source = "program P {\r\n /* }\r\n    nested { comment\r\n */\r\nform identity [] (many value: int) ->[many] int marks {} = value\r\nterm identity(1)\r\n}\r\n" in
  let term_format = analyze ~syntax:Term term_format_source in
  require (term_format.diagnostics = []) "term formatting fixture";
  let term_layout = Option.get term_format.formatting in
  require (not (List.exists (fun (line, _, _) -> List.mem line [1; 2; 3]) term_layout))
    "term comment gaps are not treated as code indentation";
  let term_lines = Array.of_list (String.split_on_char '\n' term_format_source) in
  List.iter (fun (line, width, depth) ->
    let text = term_lines.(line) in
    term_lines.(line) <- String.make (2 * depth) ' ' ^ String.sub text width (String.length text - width)) term_layout;
  let term_formatted = String.concat "\n" (Array.to_list term_lines) in
  require (term_lines.(5) = "  term identity(1)\r") "term indentation preserves CRLF";
  let term_tokens text = match Octra_vm.C_lex.scan text with
    | Ok tokens -> Array.map (fun (item : Octra_vm.C_lex.item) -> item.tok) tokens
    | Error _ -> failwith "term formatting lexer failure" in
  require (term_tokens term_format_source = term_tokens term_formatted)
    "term formatting preserves official tokens";
  require ((analyze ~syntax:Term term_formatted).diagnostics = []) "formatted term source passes checking";
  require ((analyze ~syntax:Term "program P { term @ }").formatting = None)
    "invalid term source is not formatted";
  let rejected = analyze "program P { fn inc(n: int): int { return n } fn run(): int { return inc(true) } }" in
  require (rejected.diagnostics <> []) "invalid call fixture";
  require (List.for_all (fun d -> d.uses = []) rejected.declarations) "no uses from failed checking";

  let locals_source = "program P { fn run(): int { let value = 1 let value = 2 return value } fn other(value: int): int { return value } }" in
  let locals = analyze locals_source in
  require (locals.diagnostics = []) "scoped local fixture";
  let bindings = List.filter (fun d -> d.kind = "local") locals.declarations in
  (match bindings with
   | [outer; inner] ->
       require (outer.name = "value" && inner.name = "value") "distinct shadowed bindings";
       (match outer.visibility, inner.visibility, inner.selection with
        | [first], [last], Some selected ->
            require (first.first < selected.first && selected.last < first.last)
              "old binding remains visible in replacement initializer";
            require (first.last = last.first && last.last < String.length locals_source)
              "visibility closes on shadowing and function end"
        | _ -> failwith "missing local completion bounds");
       (match outer.uses, inner.uses, inner.selection with
        | [], [inner_use], Some inner_decl ->
            require (inner_decl.first < inner_use.first) "latest local binding"
        | _ -> failwith "only latest binding receives the return use")
   | _ -> failwith "local binding count");
  check_ranges locals_source locals;
  let loop = analyze "program P { fn run(): int { let i = 7 for i in 0..2 { return i } return i } }" in
  require (loop.diagnostics = []) "loop shadow fixture";
  require (List.exists (fun d -> d.kind = "iterator" && List.length d.uses = 1) loop.declarations)
    "loop return resolves to iterator";
  require (List.exists (fun d -> d.kind = "local" && List.length d.uses = 1
    && List.length d.visibility = 2) loop.declarations) "outer local restored after loop";
  let nested = analyze "program P { fn run(i: int): int { for i in 0..2 { let i = 3 for i in 0..1 { return i } return i } return i } }" in
  require (nested.diagnostics = []) "nested loop and let shadow fixture";
  require (List.exists (fun d -> d.kind = "parameter" && List.length d.visibility = 2 && List.length d.uses = 1)
    nested.declarations) "parameter resumes after nested loop scopes";
  require (List.exists (fun d -> d.kind = "local" && List.length d.visibility = 2 && List.length d.uses = 1)
    nested.declarations) "body local resumes after inner loop";
  let mixed = analyze "program P { fn run(n: int): int { for i in 0..2 { if n > 0 { return i } } return n } }" in
  require (mixed.diagnostics = []) "mixed loop and branch fixture";
  require (List.exists (fun d -> d.kind = "iterator" && List.length d.uses = 1) mixed.declarations)
    "branch return inside a loop resolves to its iterator";
  require (List.exists (fun d -> d.kind = "parameter" && List.length d.uses = 2) mixed.declarations)
    "unshadowed parameter survives a branch and loop";
  let branches_source = "program P { fn run(n: int): int { if n > 0 { let x = 1 return x } else if n < 0 { let x = 2 return x } else { let x = 3 return x } return n } }" in
  let branches = analyze branches_source in
  require (branches.diagnostics = []) "else-if fixture";
  check_ranges branches_source branches;
  let locals = List.filter (fun d -> d.kind = "local") branches.declarations in
  require (List.length locals = 3 && List.for_all (fun d -> List.length d.uses = 1) locals)
    "each branch resolves its own declaration";
  let branch_shadow = analyze "program P { fn run(n: int): int { if n > 0 { return n } else { let n = 2 return n } return n } }" in
  require (branch_shadow.diagnostics = []) "branch shadow fixture";
  require (List.exists (fun d -> d.kind = "parameter" && List.length d.uses = 3) branch_shadow.declarations)
    "outer parameter resumes after a shadowing branch";
  require (List.exists (fun d -> d.kind = "local" && List.length d.uses = 1) branch_shadow.declarations)
    "branch-local navigation stays in its own body";
  let fibonacci_source = "program Fib { public fn fib(n: int): int { let a = 0 let b = 1 let i = 0 while i < n { let t = a + b a = b b = t i = i + 1 } return a } }" in
  let fibonacci = analyze fibonacci_source in
  require (fibonacci.diagnostics = []) "official Fibonacci while fixture";
  check_ranges fibonacci_source fibonacci;
  List.iter (fun name -> require (List.exists (fun d -> d.name = name
    && List.mem d.kind ["local"; "parameter"]) fibonacci.declarations)
    ("while retains binding: " ^ name)) ["n"; "a"; "b"; "i"; "t"];
  let a = List.find (fun d -> d.name = "a") fibonacci.declarations in
  let t = List.find (fun d -> d.name = "t") fibonacci.declarations in
  require (List.length a.uses = 3) "initializer, assignment and return uses are indexed";
  require (List.for_all (fun span -> span.last < (List.hd (List.rev a.uses)).first) t.visibility)
    "while-local completion does not leak after the body";
  let shadow_while = analyze "program P { fn run(n: int): int { while n > 0 { let n = 2 return n } return n } }" in
  require (shadow_while.diagnostics = []) "while shadow fixture";
  require (List.exists (fun d -> d.kind = "local" && List.length d.uses = 1) shadow_while.declarations)
    "body return resolves to while-local binding";
  require (List.exists (fun d -> d.kind = "parameter" && List.length d.uses = 2) shadow_while.declarations)
    "outer parameter resumes after the while body";
  let match_source = "program P { enum Mode { A, B } fn run(mode: Mode, n: int): int { match mode { Mode.A => { let x = 1 return x } Mode.B => return n } return n } }" in
  let matched = analyze match_source in
  require (matched.diagnostics = []) "block and single-statement match fixture";
  check_ranges match_source matched;
  require (List.exists (fun d -> d.name = "n" && List.length d.uses = 2) matched.declarations)
    "unshadowed parameter survives match arms";
  require (List.exists (fun d -> d.name = "x" && List.length d.uses = 1) matched.declarations)
    "match arm return resolves to arm-local declaration";
  let match_shadow = analyze "program P { enum Mode { A, B } fn run(mode: Mode, n: int): int { match mode { Mode.A => { let n = 1 return n } Mode.B => return n } return n } }" in
  require (match_shadow.diagnostics = []) "match shadow fixture";
  require (List.exists (fun d -> d.kind = "parameter" && d.name = "n" && List.length d.uses = 2) match_shadow.declarations)
    "outer parameter remains visible in sibling arms and after the match";
  require (List.exists (fun d -> d.kind = "local" && List.length d.uses = 1) match_shadow.declarations)
    "match-local navigation stays in its own arm";
  let immutable_loop = analyze "program P { public pure fn run(): int { for i in 0..1 { i = 0 } return 0 } }" in
  require (List.length immutable_loop.diagnostics = 1) "pure loop index assignment is rejected";
  require (match List.hd immutable_loop.diagnostics with
    | { message; span = Some _ } -> String.starts_with ~prefix:"line 1 column " message
    | _ -> false) "pure loop diagnostic has a compiler location";
  let restored_branch = analyze "program P { fn run(n: int): int { for i in 0..2 { if i > 0 { let n = 2 return n } } return n } }" in
  require (restored_branch.diagnostics = []) "branch inside restoring loop fixture";
  require (List.exists (fun d -> d.kind = "parameter" && d.name = "n"
    && List.length d.uses = 1 && List.length d.visibility = 2) restored_branch.declarations)
    "for exit restores an outer name shadowed by its nested branch";
  let expression_source = "/* 😀 n */ program P { state { n: int } fn helper(n: int): int { return n } fn run(n: int): int { let n = n + self.n + helper(n) /* n */ n += n return n + n } }" in
  let expressions = analyze expression_source in
  require (expressions.diagnostics = []) "expression references fixture";
  check_ranges expression_source expressions;
  let local = List.find (fun d -> d.kind = "local" && d.name = "n") expressions.declarations in
  require (List.length local.uses = 4) "assignment target/RHS and repeated return operands";
  require (List.exists (fun d -> d.kind = "parameter" && List.length d.uses = 2) expressions.declarations)
    "replacement initializer and call argument resolve to the preceding parameter";
  require (List.for_all (fun d -> d.kind = "field" || List.for_all (fun span ->
    span.first = 0 || expression_source.[span.first - 1] <> '.') d.uses) expressions.declarations)
    "storage field name is not a local-variable reference";
  let storage_source = "program P { state { slots: map[int]int } fn run(n: int): int { assert n > 0 self.slots[n] = n return self.slots[n] } }" in
  let storage_uses = analyze storage_source in
  require (storage_uses.diagnostics = []) "assertion and storage expression fixture";
  check_ranges storage_source storage_uses;
  require (List.exists (fun d -> d.kind = "parameter" && List.length d.uses = 4) storage_uses.declarations)
    "assertion, storage keys and stored value reference the parameter";
  let term_binding = analyze "program P { fn run(n: int): int { return let many n: int = 1 in n } }" in
  require (term_binding.diagnostics = []) "expression-local term binder fixture";
  require (List.for_all (fun d -> d.kind <> "parameter" || d.uses = []) term_binding.declarations)
    "term-local names must not resolve to callable parameters";
  require (List.exists (fun d -> d.kind = "local" && d.name = "n"
    && d.return_type = Some "int" && Option.is_some d.selection && List.length d.uses = 1)
    term_binding.declarations) "term-local declaration and use are linked";
  let nested_text = "program P { fn run(n: int): int { return let many n: int = n in let many n: int = n in n } }" in
  let nested = analyze nested_text in
  require (nested.diagnostics = []) "nested term bindings check";
  check_ranges nested_text nested;
  let locals = List.filter (fun d -> d.kind = "local") nested.declarations in
  require (List.length locals = 2 && List.for_all (fun d -> List.length d.uses = 1) locals)
    "nested binders have separate uses";
  (match locals with
   | [outer; inner] ->
       let outer_use = List.hd outer.uses and inner_use = List.hd inner.uses in
       let inner_declaration = Option.get inner.selection in
       require (inner_declaration.first < outer_use.first && outer_use.first < inner_use.first)
         "inner initializer refers to outer term binder"
   | _ -> assert false);
  List.iter (fun (expression, expected_uses, expected_calls) ->
    let source = "program P { form identity [] (many value: int) ->[many] int marks {} = value pure fn inc(x: int): int { return x + 1 } fn run(n: int): int { return "
      ^ expression ^ " } }" in
    let analysis = analyze source in
    require (analysis.diagnostics = []) ("term expression fixture: " ^ expression ^ ": "
      ^ String.concat "; " (List.map (fun d -> d.message) analysis.diagnostics));
    check_ranges source analysis;
    let parameter = List.find (fun d -> d.kind = "parameter" && d.name = "n") analysis.declarations in
    let callee = List.find (fun d -> d.kind = "function" && d.name = "inc") analysis.declarations in
    require (List.for_all (fun d -> d.kind <> "local" ||
      (d.return_type = Some "int" && List.length d.uses = 1)) analysis.declarations)
      ("term-local bindings retain distinct typed uses: " ^ expression);
    require (List.for_all (fun d -> d.kind <> "local" || List.for_all (fun use ->
      List.exists (fun scope -> scope.first <= use.first && use.last <= scope.last) d.visibility) d.uses)
      analysis.declarations) ("term-local uses lie inside completion scope: " ^ expression);
    require (List.length parameter.uses = expected_uses) ("outer term uses: " ^ expression);
    require (List.length callee.uses = expected_calls) ("term function calls: " ^ expression)) [
      "let many n: int = inc(n) in inc(n)", 1, 2;
      "let many x: int = n in x + n", 2, 0;
      "let many x: int = n in /* body\n comment */ x + n", 2, 0;
      "(let many n: int = n in n) + n", 2, 0;
      "let many n: int = n in let many n: int = n in n", 1, 0;
      "split (n, n) as many n: int, many other: int in inc(n) + other", 2, 1;
      "orbit[2] from inc(n) with many n: int => inc(n)", 1, 2;
      "orbit[2, n] from n with many n: int => n", 2, 0;
      "if equal[int](inc(n), n) then n else n", 4, 1;
      "use identity[](n) as many n: int in n", 1, 0;
    ];
  let form_calls_source = "/* 😀 use identity[](1) */ program P { form identity [] (many value: int) ->[many] int marks {} = value form relay [] (many seed: int) ->[many] int marks {} = use identity[](seed) as many result: int in result constructor() { let value = use identity[](1) as many result: int in result } fn run(identity: int): int { return use relay[](identity) as many identity: int in use identity[](identity) as many result: int in result } }" in
  let form_calls = analyze form_calls_source in
  require (form_calls.diagnostics = []) ("explicit form use fixture: " ^
    String.concat "; " (List.map (fun d -> d.message) form_calls.diagnostics));
  check_ranges form_calls_source form_calls;
  List.iter (fun (name, count) ->
    let target = List.find (fun d -> d.kind = "form" && d.name = name) form_calls.declarations in
    require (List.length target.uses = count) ("explicit form use count: " ^ name);
    List.iter (fun use -> require (String.sub form_calls_source (use.first - 4) 4 = "use ")
      "same-named arguments and binders are not form targets") target.uses)
    ["identity", 3; "relay", 1];
  let direct_form_calls_source = "program P { form abs [] (many value: int) ->[many] int marks {} = value + 1 form relay [] (many seed: int) ->[many] int marks {} = abs(seed) fn run(abs: int): int { return abs(abs) } }" in
  let direct_form_calls = analyze direct_form_calls_source in
  require (direct_form_calls.diagnostics = []) "direct form calls including a builtin name";
  check_ranges direct_form_calls_source direct_form_calls;
  require (List.exists (fun d -> d.kind = "form" && d.name = "abs" && List.length d.uses = 2)
    direct_form_calls.declarations) "direct form calls in form and function bodies are indexed";
  require (List.exists (fun d -> d.kind = "parameter" && d.name = "abs" && List.length d.uses = 1)
    direct_form_calls.declarations) "same-named direct form argument remains a parameter use";
  let pure_form_calls_source = "program P { pure fn abs(value: int): int { return value + 1 } form relay [] (many seed: int) ->[many] int marks {} = abs(seed) fn run(): int { return abs(1) } }" in
  let pure_form_calls = analyze pure_form_calls_source in
  require (pure_form_calls.diagnostics = []) "pure function called from form fixture";
  check_ranges pure_form_calls_source pure_form_calls;
  let pure_abs = List.find (fun d -> d.kind = "function" && d.name = "abs") pure_form_calls.declarations in
  require (List.length pure_abs.uses = 2)
    "form linking promotes the pure function for both form and ordinary calls";
  let builtin_abs = analyze "program P { pure fn abs(value: int): int { return value + 1 } fn run(): int { return abs(1) } }" in
  require (builtin_abs.diagnostics = []) "ordinary builtin abs fixture";
  require (List.for_all (fun d -> d.kind <> "function" || d.uses = []) builtin_abs.declarations)
    "without form linking, builtin abs does not navigate to a same-named pure function";
  let absent_form = analyze "program P { pure fn identity(value: int): int { return value } fn run(): int { return use identity[](1) as many value: int in value } }" in
  require (absent_form.diagnostics <> []) "explicit use requires a real form, not a pure function";
  require (List.for_all (fun d -> d.uses = []) absent_form.declarations)
    "failed form check never exposes call mappings";
  List.iter (fun expression ->
    let source = "program P { fn run(n: int): bool { return " ^ expression in
    let recovered = analyze source in
    require (recovered.diagnostics <> []) "unfinished term body retains diagnostics";
    require (List.exists (fun d -> d.kind = "local" && d.name = "n" && d.return_type = Some "bool"
      && d.selection = None && List.exists (fun scope -> scope.first <= String.length source
        && scope.last = String.length source) d.visibility) recovered.declarations)
      "unfinished term body retains typed completion at EOF")
    ["let many n: bool = true in"; "orbit[2] from true with many n: bool =>"];
  let rejected_term_call = analyze "program P { fn inc(x: int): int { return x + 1 } fn run(n: int): int { return let many n: int = inc(n) in n } }" in
  require (rejected_term_call.diagnostics <> [] &&
    List.for_all (fun d -> d.uses = []) rejected_term_call.declarations)
    "term traversal must not permit non-pure calls rejected by official AMLC";
  let tuple = analyze "program P { fn run(): int { let value = 1 let (value, other) = (2, 3) return value } }" in
  require (tuple.diagnostics = []) "tuple shadow fixture";
  let tuple_locals = List.filter (fun d -> d.kind = "local" && d.name = "value") tuple.declarations in
  (match tuple_locals with
   | [old; current] -> require (old.uses = [] && List.length current.uses = 1)
       "tuple binding owns the shadowed use"
   | _ -> failwith "missing tuple binding declarations");
  let tuple_source = "/* 😀 value */ program P { fn run(value: int): int { let (value, other) = (value, value) return value + other } }" in
  let constructor_source = "/* 😀 constructor(seed) */ program P { state { total: int } constructor(seed: int) { let (value, extra) = (seed, 1) self.total = inc(value + extra) } fn inc(n: int): int { return n + 1 } fn run(seed: int): int { return seed } }" in
  let constructor = analyze constructor_source in
  require (constructor.diagnostics = []) "constructor scope fixture";
  check_ranges constructor_source constructor;
  require (List.exists (fun d -> d.kind = "constructor" && d.parameters = ["seed"]
    && d.parameter_types = ["int"]) constructor.declarations) "constructor declaration metadata";
  require (List.length (List.filter (fun d -> d.kind = "parameter" && d.name = "seed"
    && List.length d.uses = 1 && d.visibility <> []) constructor.declarations) = 2)
    "constructor and function parameters have independent scopes";
  require (List.length (List.filter (fun d -> d.kind = "local" && List.length d.uses = 1)
    constructor.declarations) = 2) "constructor tuple-local uses";
  require (List.exists (fun d -> d.kind = "function" && d.name = "inc" && List.length d.uses = 1)
    constructor.declarations) "function call inside constructor";
  let tuple_parameters = analyze tuple_source in
  require (tuple_parameters.diagnostics = []) "tuple initializer scope fixture";
  check_ranges tuple_source tuple_parameters;
  require (List.exists (fun d -> d.kind = "parameter" && List.length d.uses = 2) tuple_parameters.declarations)
    "tuple initializer uses the incoming parameter";
  require (List.length (List.filter (fun d -> d.kind = "local" && List.length d.uses = 1
    && d.return_type = None && d.visibility <> []) tuple_parameters.declarations) = 2)
    "both tuple bindings have verified uses and completion scopes without guessed types";
  let tuple_loop = analyze "program P { fn run(value: int): int { for i in 0..2 { let (value, other) = (i, value) return value + other } return value } }" in
  require (tuple_loop.diagnostics = []) "tuple loop scope fixture";
  require (List.exists (fun d -> d.kind = "parameter" && List.length d.uses = 2
    && List.length d.visibility = 2) tuple_loop.declarations) "tuple shadow restores after for loop";

  let parameters_source = "/* 😀 value: int */ program P { fn run(value: int where value > 0, pair: (int, int)): int { return value } }" in
  let parameters = analyze parameters_source in
  require (parameters.diagnostics = []) "refined and tuple parameter fixture";
  check_ranges parameters_source parameters;
  let value = List.find (fun d -> d.kind = "parameter" && d.name = "value") parameters.declarations in
  let pair = List.find (fun d -> d.kind = "parameter" && d.name = "pair") parameters.declarations in
  require (value.return_type = Some "int" && pair.return_type = Some "(int, int)")
    "parameter types preserve official tuple structure";
  require (List.length value.uses = 1 && pair.uses = []) "refinement is not a returned-variable use";
  (match value.selection, value.visibility, pair.selection with
   | Some selected, [visible], Some tuple_name ->
       require (selected.first > String.index parameters_source '{' && selected.last < tuple_name.first
         && tuple_name.last < visible.first) "parameter bounds ignore comment and refinement decoys"
   | _ -> failwith "missing parameter bounds");
  let parameter_tuple = analyze "program P { fn run(value: int): int { let (value, other) = (2, 3) return value } }" in
  require (parameter_tuple.diagnostics = []) "tuple shadows parameter fixture";
  require (List.for_all (fun d -> d.kind <> "parameter" || d.uses = []) parameter_tuple.declarations)
    "tuple shadowing blocks parameter navigation";

  let incomplete = analyze ~syntax:Callable "program Example { fn inc(" in
  require (incomplete.diagnostics <> []) "incomplete source must not pass";
  require (List.for_all (fun d -> d.selection = None && d.uses = []) incomplete.declarations)
    "recovery must not fabricate navigation ranges";
  let prefix = "program P { fn run(seed: int): int { let secret = seed " in
  List.iter (fun suffix ->
    let source = prefix ^ suffix in
    let recovered = analyze ~syntax:Callable source in
    require (recovered.diagnostics <> []) "recovery must preserve the original error";
    require (List.exists (fun d -> d.kind = "local" && d.name = "secret" &&
      List.exists (fun span -> span.first <= String.length source && span.last = String.length source) d.visibility)
      recovered.declarations) ("local completion at incomplete EOF: " ^ suffix ^ " / " ^
        String.concat ", " (List.map (fun d -> d.name ^ ":" ^ String.concat ";"
          (List.map (fun span -> Printf.sprintf "%d-%d" span.first span.last) d.visibility)) recovered.declarations));
    require (List.for_all (fun d -> d.selection = None && d.uses = []) recovered.declarations)
      "recovered candidates cannot drive navigation";
    require (not (List.exists (fun d -> d.name = "unfinished") recovered.declarations))
      "incomplete initializer must not create a declaration")
    ["return secr"; "return ("; "let unfinished ="];
  let unresolved_local = analyze (prefix ^ "return missing } }") in
  require (unresolved_local.diagnostics <> [] && List.exists (fun d -> d.name = "secret"
    && d.selection = None && d.uses = []) unresolved_local.declarations)
    "parsed but unchecked locals remain completion-only";
  let lexical = analyze ~syntax:Callable (prefix ^ "let text = \"unterminated") in
  require (lexical.declarations = []) "do not recover inside an unclosed string";
  let excessive = analyze ~syntax:Callable (prefix ^ "return " ^ String.make 129 '(') in
  require (excessive.diagnostics <> [] && excessive.declarations = []) "bounded recovery nesting";
  let reads = ref 0 in
  let recovering_import = analyze ~resolve:(fun _ -> incr reads; None)
    ("import I from \"./missing.aml\"\n" ^ prefix ^ "return (") in
  require (recovering_import.diagnostics <> [] && !reads = 0)
    "synthetic recovery must not compile or resolve imports";
  let later = List.init 12 (fun index -> Printf.sprintf "fn later%d(): int { return 0 }" index)
    |> String.concat " " in
  let early_error = analyze (prefix ^ "let unfinished = } " ^ later ^ " }") in
  require (early_error.diagnostics <> [] && List.exists (fun d -> d.name = "secret") early_error.declarations
    && List.exists (fun d -> d.name = "later11") early_error.declarations)
    "later functions must not exhaust recovery candidates before the error";
  let schema = "program P { struct Contact { active: bool } struct Account { count: int contact: Contact } enum Mode { Ready, Busy } state { account: Account total: int } " in
  let member_source = schema ^ "fn run(): int { return self.account.count } }" in
  let member_analysis = analyze member_source in
  require (member_analysis.diagnostics = []) "official storage member fixture";
  require (List.exists (fun site -> List.mem ("account", "Account", 5) site.items) member_analysis.members)
    "self state fields";
  require (List.exists (fun site -> List.mem ("count", "int", 5) site.items
    && List.mem ("contact", "Contact", 5) site.items) member_analysis.members) "struct storage fields";
  let partial_member = analyze (schema ^ "fn run(): bool { return self.account.contact. } }") in
  require (partial_member.diagnostics <> [] && List.exists (fun site -> site.items = ["active", "bool", 5]) partial_member.members)
    "nested members survive an unfinished field name";
  let enum_member = analyze (schema ^ "fn mode(): Mode { return Mode.Ready } }") in
  require (enum_member.diagnostics = [] && List.exists (fun site -> List.mem ("Ready", "Mode", 20) site.items) enum_member.members)
    "enum member completion";
  let enum_source = "/* 😀 Mode.Ready */ program P { enum Mode { Ready, Busy } enum Other { Ready } fn run(mode: Mode): Mode { let other = Other.Ready match mode { Mode.Ready => return Mode.Ready Mode.Busy => return Mode.Busy } } }" in
  let enum_analysis = analyze enum_source in
  require (enum_analysis.diagnostics = []) ("enum navigation fixture: " ^
    String.concat "; " (List.map (fun d -> d.message) enum_analysis.diagnostics));
  check_ranges enum_source enum_analysis;
  let mode = List.find (fun d -> d.kind = "enum" && d.name = "Mode") enum_analysis.declarations in
  require (List.length mode.uses = 6) "qualified enum receivers and callable type annotations, excluding comments";
  List.iter (fun (owner, name, count) ->
    let variant = List.find (fun d -> d.kind = "enumMember" && d.name = name && d.return_type = Some owner)
      enum_analysis.declarations in
    require (List.length variant.uses = count) ("enum variant owner: " ^ owner ^ "." ^ name))
    ["Mode", "Ready", 2; "Mode", "Busy", 2; "Other", "Ready", 1];
  let invalid_enum = analyze "program P { enum Mode { Ready } fn run(): Mode { return Mode.Missing } }" in
  require (invalid_enum.diagnostics <> []) "unknown variant retains compiler error";
  require (List.for_all (fun d -> d.uses = []) invalid_enum.declarations)
    "failed enum check must not expose uses";
  let reserved_enum_source = "program P { enum Mode { value } fn run(): Mode { return Mode /* gap */ . value } }" in
  let reserved_enum = analyze reserved_enum_source in
  require (reserved_enum.diagnostics = []) "keyword-like variant and spaced qualifier fixture";
  check_ranges reserved_enum_source reserved_enum;
  require (List.exists (fun d -> d.kind = "enumMember" && d.name = "value" && List.length d.uses = 1)
    reserved_enum.declarations) "variant names use the official identifier rules";
  let deferred_enum = analyze ("import I from \"./missing.aml\"\n" ^ enum_source) in
  require (deferred_enum.status = Needs_imports ["./missing.aml"] &&
    List.for_all (fun d -> d.uses = []) deferred_enum.declarations)
    "unresolved imports must not publish enum use mappings";
  let enum_types_source = "/* 😀 Mode */ program P { enum Mode { Ready } constructor(seed: Mode) {} fn run(Mode: int where Mode > 0, pair: (Mode, Mode)): Mode { let value: Mode = Mode.Ready return value } }" in
  let enum_types = analyze enum_types_source in
  require (enum_types.diagnostics = []) ("enum type annotations fixture: " ^
    String.concat "; " (List.map (fun d -> d.message) enum_types.diagnostics));
  check_ranges enum_types_source enum_types;
  let mode = List.find (fun d -> d.kind = "enum" && d.name = "Mode") enum_types.declarations in
  require (List.length mode.uses = 6)
    "constructor, tuple parameters, return and local types exclude variable names and refinements";
  let type_source = "/* 😀 */ map[Mode]list[(Mode, option[Other])] where Mode > 0" in
  let type_stream = Octra_vm.Oct_lex.make_stream type_source in
  let _, type_uses = Amlc_analysis__Type_uses.parse type_stream in
  require (List.map (fun (name, _, _) -> name) type_uses = ["Mode"; "Mode"; "Other"])
    "nested type leaves preserve parser order";
  List.iter (fun (name, first, last) -> require (String.sub type_source first (last - first) = name)
    "named type uses retain original byte ranges") type_uses;
  require (Octra_vm.Oct_lex.peek_token type_stream = Octra_vm.Oct_lang.TkWhere)
    "type indexing must not consume the following refinement";
  let namespaces_source = "program P { enum Mode { Ready } fn Mode(): int { return 1 } fn run(Mode: Mode): Mode { let n = Mode() return Mode } }" in
  let namespaces = analyze namespaces_source in
  require (namespaces.diagnostics = []) "same-named enum, callable and parameter fixture";
  check_ranges namespaces_source namespaces;
  List.iter (fun (kind, count) ->
    let symbol = List.find (fun d -> d.kind = kind && d.name = "Mode") namespaces.declarations in
    require (List.length symbol.uses = count) ("separate type/call/variable namespace: " ^ kind))
    ["enum", 2; "function", 1; "parameter", 1];
  let declaration_types_source = "/* 😀 Mode */ interface I { fn mode(Mode: Mode): Mode } program P { enum Mode { Ready } struct Box { Mode: Mode next: list[Mode] } state { current: Mode history: map[int]Mode } event Changed(Mode: indexed Mode) const Selected: Mode = Mode.Ready fn run(): Mode { return self.current } }" in
  let declaration_types = analyze declaration_types_source in
  require (declaration_types.diagnostics = []) ("declaration type sites fixture: " ^
    String.concat "; " (List.map (fun d -> d.message) declaration_types.diagnostics));
  check_ranges declaration_types_source declaration_types;
  let mode = List.find (fun d -> d.kind = "enum" && d.name = "Mode") declaration_types.declarations in
  require (List.length mode.uses = 10)
    "interface, struct, state, event and constant types exclude declaration names";
  let indexed_types_source = "program P { enum indexed { Ready } struct Box { indexed: indexed } event Changed(value: indexed indexed) fn run(): indexed { return indexed.Ready } }" in
  let indexed_types = analyze indexed_types_source in
  require (indexed_types.diagnostics = []) "indexed modifier and same-named enum fixture";
  check_ranges indexed_types_source indexed_types;
  require (List.exists (fun d -> d.kind = "enum" && d.name = "indexed" && List.length d.uses = 4)
    indexed_types.declarations) "event modifier and struct field name are not enum type uses";
  let effect_label_source = "program P { enum total { Ready } state { total: int } form expect [] (many value: int) ->[many] int marks {read[7]:total} = read[7](value) public view fn check(value: int): int { return use expect[](value) as many out: int in out } }" in
  let effect_label = analyze effect_label_source in
  require (effect_label.diagnostics = []) "same-named form effect label fixture";
  require (List.exists (fun d -> d.kind = "enum" && d.name = "total" && d.uses = []) effect_label.declarations)
    "form effect labels are not type annotations";
  let equal_text = "return equal[map[Mode]Mode](equal/* Mode */[Mode](left, right), other)" in
  let mode_type = Octra_vm.Oct_lang.TStruct "Mode" in
  let equal_expr = Octra_vm.Oct_lang.EEqual (Octra_vm.Oct_lang.TMap (mode_type, mode_type),
    Octra_vm.Oct_lang.EEqual (mode_type, Octra_vm.Oct_lang.EVar "left", Octra_vm.Oct_lang.EVar "right"),
    Octra_vm.Oct_lang.EVar "other") in
  let equal_uses = Amlc_analysis__Type_uses.expressions equal_text 0 (String.length equal_text) equal_expr in
  require (List.map (fun (name, first, last) -> name, String.sub equal_text first (last - first)) equal_uses
    = ["Mode", "Mode"; "Mode", "Mode"; "Mode", "Mode"])
    "equal types follow the official type parser and skip comments";
  let _, inner_mode, _ = List.nth equal_uses 2 in
  require (inner_mode > index_of equal_text "/* Mode */")
    "the commented Mode is not the inner equal type";
  require (Amlc_analysis__Type_uses.expressions equal_text 0 (String.length equal_text)
    (Octra_vm.Oct_lang.EEqual (Octra_vm.Oct_lang.TInt, Octra_vm.Oct_lang.EVar "left", Octra_vm.Oct_lang.EVar "right")) = [])
    "an equal type that disagrees with the expression publishes nothing";
  let checked_equal_source = "program P { enum Mode { Ready } fn run(left: int, right: int): bool { return equal/* Mode */[int](left, right) } }" in
  let checked_equal = analyze checked_equal_source in
  require (checked_equal.diagnostics = []) ("checked equal fixture: " ^
    String.concat "; " (List.map (fun d -> d.message) checked_equal.diagnostics));
  check_ranges checked_equal_source checked_equal;
  require (List.exists (fun d -> d.kind = "enum" && d.name = "Mode" && d.uses = []) checked_equal.declarations)
    "a primitive equal type does not consume a commented name";
  let invalid_equal = analyze "program P { enum Mode { Ready } fn run(): bool { return equal[Mode](1, 2) } }" in
  require (invalid_equal.diagnostics <> [] && List.for_all (fun d -> d.uses = []) invalid_equal.declarations)
    "failed equal check clears type uses";
  let struct_source = "/* 😀 Box */ interface I { fn get(value: Box): Box } program P { struct Box { n: int } struct Holder { box: Box } state { boxes: map[int]Box holder: Holder } fn run(): int { return self.boxes[0].n } }" in
  let structs = analyze struct_source in
  require (structs.diagnostics = []) ("struct type references fixture: " ^
    String.concat "; " (List.map (fun d -> d.message) structs.diagnostics));
  check_ranges struct_source structs;
  List.iter (fun (name, count) ->
    let symbol = List.find (fun d -> d.kind = "struct" && d.name = name) structs.declarations in
    require (List.length symbol.uses = count) ("struct type reference count: " ^ name)) ["Box", 4; "Holder", 1];
  let struct_namespaces = analyze "program P { struct Box { n: int } state { boxes: map[int]Box } fn Box(): int { return 1 } fn run(Box: int): int { return Box() + Box } }" in
  require (struct_namespaces.diagnostics = []) "same-named struct/function/parameter fixture";
  List.iter (fun kind -> require (List.exists (fun d -> d.kind = kind && d.name = "Box" && List.length d.uses = 1)
    struct_namespaces.declarations) ("struct namespace isolation: " ^ kind)) ["struct"; "function"; "parameter"];
  let state_source = "/* 😀 self.total */ program P { struct Box { total: int } state { total: int boxes: map[int]Box entries: list[int] } constructor() { self.total = 0 } fn run(total: int): int { self.total += total self.entries.push(self.total) self.boxes[self.total].total = total return self.total + total } }" in
  let state_analysis = analyze state_source in
  require (state_analysis.diagnostics = []) ("state field reference fixture: " ^
    String.concat "; " (List.map (fun d -> d.message) state_analysis.diagnostics));
  check_ranges state_source state_analysis;
  List.iter (fun (name, count) ->
    require (List.exists (fun d -> d.kind = "field" && d.name = name && List.length d.uses = count)
      state_analysis.declarations) ("root state uses: " ^ name)) ["total", 5; "boxes", 1; "entries", 1];
  require (List.exists (fun d -> d.kind = "parameter" && d.name = "total" && List.length d.uses = 3)
    state_analysis.declarations) "state fields do not absorb same-named parameter uses";
  let state_keyword_source = "program P { state { value: int } fn run(): int { return self /* gap */ . value } }" in
  let state_keyword = analyze state_keyword_source in
  require (state_keyword.diagnostics = []) "keyword-like state field fixture";
  check_ranges state_keyword_source state_keyword;
  require (List.exists (fun d -> d.kind = "field" && d.name = "value" && List.length d.uses = 1)
    state_keyword.declarations) "state field names use official identifier rules";
  let totals = List.filter (fun d -> d.kind = "field" && d.name = "total") state_analysis.declarations in
  require (List.length totals = 2) "state and struct totals stay separate symbols";
  let struct_total = List.find (fun d -> match d.selection with
    | Some span -> span.first < index_of state_source "state {" | _ -> false) totals in
  let state_total = List.find (fun d -> match d.selection with
    | Some span -> span.first > index_of state_source "state {" | _ -> false) totals in
  require (List.length struct_total.uses = 1 && state_source.[(List.hd struct_total.uses).first - 1] = '.')
    "nested total resolves to the struct field";
  require (List.length state_total.uses = 5) "nested total is not a root state use";
  let nested_fields_source = "program P { struct Contact { active: int } struct Account { contact: Contact count: int } state { account: Account accounts: map[int]Account nested: map[int]map[int]Account keys: map[int]int entries: list[int] } fn run(): int { return self.account.contact.active + self.accounts[self.keys[0]].count + self.nested[0][1].count + self.entries.length } }" in
  let nested_fields = analyze nested_fields_source in
  require (nested_fields.diagnostics = []) ("nested struct field fixture: " ^
    String.concat "; " (List.map (fun d -> d.message) nested_fields.diagnostics));
  check_ranges nested_fields_source nested_fields;
  let field_at source marker name =
    let first = index_of source marker + String.length marker in
    require (String.sub source first (String.length name) = name) marker;
    List.find (fun d -> d.kind = "field" && d.name = name && match d.selection with
      | Some span -> span.first = first | None -> false) in
  require (List.length (field_at nested_fields_source "struct Contact { " "active" nested_fields.declarations).uses = 1)
    "two-owner path indexes the leaf";
  require (List.length (field_at nested_fields_source "struct Account { " "contact" nested_fields.declarations).uses = 1)
    "two-owner path indexes the intermediate field";
  require (List.length (field_at nested_fields_source "contact: Contact " "count" nested_fields.declarations).uses = 2)
    "indexed and nested-map receivers share the struct field";
  require (not (List.exists (fun d -> d.kind = "field" && d.name = "length") nested_fields.declarations))
    "list length is not a struct field";
  let length_source = "program P { struct Account { name: int items: list[int] tags: map[int]int length: int } state { account: Account accounts: map[int]Account } fn run(): int { return self.account.items.length + self.account.tags.length + self.account.name + self.account.length + self.accounts[self.account.items.length].name } }" in
  let length_fields = analyze length_source in
  require (length_fields.diagnostics = []) ("struct length fixture: " ^
    String.concat "; " (List.map (fun d -> d.message) length_fields.diagnostics));
  check_ranges length_source length_fields;
  require (List.length (field_at length_source "struct Account { " "name" length_fields.declarations).uses = 2)
    "a list length keeps the neighboring struct field";
  require (List.length (field_at length_source "name: int " "items" length_fields.declarations).uses = 2)
    "a nested list length indexes the struct field twice";
  require (List.length (field_at length_source "items: list[int] " "tags" length_fields.declarations).uses = 1)
    "a nested map length indexes the struct field";
  let named_length = field_at length_source "tags: map[int]int " "length" length_fields.declarations in
  require (List.length named_length.uses = 1) "a field named length is not the list property";
  let named_length_use = List.hd named_length.uses in
  require (length_source.[named_length_use.first - 1] = '.'
    && String.sub length_source (named_length_use.first - 8) 7 = "account")
    "the length field use is self.account.length";
  let ambiguous_source = "program P { struct A { n: int } struct B { n: int } state { a: A b: B } fn run(): int { return self.a.n + self.b.n } }" in
  let ambiguous = analyze ambiguous_source in
  require (ambiguous.diagnostics = []) "same-named struct fields fixture";
  check_ranges ambiguous_source ambiguous;
  require (List.length (field_at ambiguous_source "struct A { " "n" ambiguous.declarations).uses = 1
    && List.length (field_at ambiguous_source "struct B { " "n" ambiguous.declarations).uses = 1)
    "same-named struct fields keep their own uses";
  let spaced_source = "program P { struct Box { total: int } state { box: Box } fn run(): int { return self /* gap */ . box . total } }" in
  let spaced = analyze spaced_source in
  require (spaced.diagnostics = []) "spaced storage path fixture";
  check_ranges spaced_source spaced;
  require (List.length (field_at spaced_source "struct Box { " "total" spaced.declarations).uses = 1)
    "comments between storage-path tokens stay outside the field use";
  let unsupported_member = analyze (schema ^ "fn run(person: Account): int { return person.count } }") in
  require (unsupported_member.diagnostics <> [] && unsupported_member.members <> []
    && List.for_all (fun site -> site.items = []) unsupported_member.members)
    "local struct member syntax must not be emulated as storage access";
  let lengths = analyze "program P { state { entries: list[int] counts: map[int]int } fn size(): int { return self.entries.length + self.counts.length } }" in
  require (lengths.diagnostics = [] && List.length (List.filter (fun site -> site.items = ["length", "int", 5]) lengths.members) = 2)
    "official list and map length properties";
  let list_schema = "program P { state { entries: list[int] counts: map[int]int } " in
  let methods = ["push", "push(value: int)", 2; "delete", "delete(index: int)", 2;
    "len", "len()", 2; "pop", "pop()", 2] in
  let list_calls = analyze (list_schema ^ "fn run(): int { self.entries.push(1) self.entries.delete(0) self.entries.len() self.entries.pop() return self.entries.length } }") in
  require (list_calls.diagnostics = []) "official list method fixture";
  require (List.length (List.filter (fun site -> site.items = methods) list_calls.members) = 4)
    "statement-only list methods";
  require (List.exists (fun site -> site.items = ["length", "int", 5]) list_calls.members)
    "method and expression receiver caches are distinct";
  List.iter (fun body ->
    let partial = analyze (list_schema ^ "fn run(): int { " ^ body ^ " } fn later(): int { return 1 } }") in
    require (partial.diagnostics <> []) "unfinished method retains diagnostics";
    require (List.exists (fun site -> site.items = methods) partial.members)
      ("unfinished statement method: " ^ body))
    ["self.entries."; "let n = 1 self.entries.pu";
     "if true { self.entries. }"; "while false { self.entries. }";
     "for n in 0..2 { self.entries. }"; "/* 😀 */ self . entries ."];
  List.iter (fun body ->
    let partial = analyze (list_schema ^ "fn run(): int { " ^ body ^ " } }") in
    require (List.for_all (fun site -> not (List.exists (fun (_, _, kind) -> kind = 2) site.items)) partial.members)
      ("methods leaked outside a root-list statement: " ^ body))
    ["return self.entries."; "let n = self.entries."; "self.counts.";
     "self.entries[0]."; "return len(self.entries.)"];
  let indexed_schema = "program P { struct Account { count: int } state { accounts: map[int]Account nested: map[int]map[int]Account keys: map[int]int } " in
  let indexed = analyze (indexed_schema ^ "fn run(): int { return self.accounts[self.keys[0]].count + self.nested[0][1].count } }") in
  require (indexed.diagnostics = []) "official indexed storage fixture";
  require (List.length (List.filter (fun site -> site.items = ["count", "int", 5]) indexed.members) = 2)
    "indexed and multi-key receivers preserve their storage type";
  let indexed_partial = analyze (indexed_schema ^ "fn run(): int { return self.accounts[self.keys[0]]. } }") in
  require (indexed_partial.diagnostics <> [] && List.exists (fun site -> site.items = ["count", "int", 5]) indexed_partial.members)
    "indexed storage completion survives an unfinished member";

  let unresolved = analyze
    "program Example { fn run(): int { return unknown_value } }" in
  require (unresolved.status = Checked && unresolved.diagnostics <> []) "compiler rejection";
  require (List.for_all (fun d -> d.span = Some {
    first = String.length "program Example { fn run(): int { ";
    last = String.length "program Example { fn run(): int { " }) unresolved.diagnostics)
    "compiler string header locates the rejected return statement";
  require (List.exists (fun d -> d.name = "run") unresolved.declarations)
    "parsed metadata survives a checking error";

  let unlocated = analyze
    "interface I { fn f(): int }\ninterface I { fn f(): int }\nprogram P { fn run(): int { return 1 } }" in
  require (unlocated.diagnostics <> [] && List.for_all (fun d -> d.span = None)
    unlocated.diagnostics) "no fabricated range for errors without a header";
  let mismatch_source = "// 한글😀\r\nprogram P {\r\n  fn inc(n: int): int { return n }\r\n  fn run(): int { return inc(true) }\r\n}" in
  let mismatch = analyze mismatch_source in
  let return_offset = index_of mismatch_source "return inc" in
  require (List.exists (fun d -> d.span = Some { first = return_offset; last = return_offset })
    mismatch.diagnostics) "multiline compiler type error location";
  let own_import_error = analyze ~resolve:(fun _ -> Some "interface I { fn f(): int }")
    ("import I from \"./types.aml\"\n" ^ mismatch_source) in
  require (List.exists (fun d -> d.span = Some {
    first = return_offset + String.length "import I from \"./types.aml\"\n";
    last = return_offset + String.length "import I from \"./types.aml\"\n" })
    own_import_error.diagnostics) "compile_multi retains current-document origin";
  let foreign_error = analyze ~resolve:(fun _ -> Some "interface I { fn f(@): int }")
    "import I from \"./types.aml\"\nprogram P { fn run(): int { return 1 } }" in
  require (foreign_error.diagnostics <> [] && List.for_all (fun d -> d.span = None)
    foreign_error.diagnostics) "import parser errors stay unlocated in current document";

  let utf8_source = "// 한글\nprogram Example { fn inc(n: int): int { return @ } }" in
  let utf8 = analyze ~syntax:Callable utf8_source in
  (match utf8.diagnostics with
   | [{ span = Some { first; last }; _ }] ->
       require (first = String.index utf8_source '@' && last = first) "UTF-8 byte point"
   | _ -> failwith "callable lexical location");

  let imported = analyze
    "import inc from \"./missing.aml\"\nprogram Example { fn run(): int { return inc(1) } }" in
  require (imported.status = Needs_imports ["./missing.aml"]) "imports explicitly deferred";
  let imported_source = "import I from \"./types.aml\"\nprogram P { fn run(): int { return 1 } }" in
  let resolved = analyze imported_source ~resolve:(function
    | "./types.aml" -> Some "interface I { fn inc(n: int): int }" | _ -> None) in
  require (resolved.status = Checked && resolved.diagnostics = []) "official interface import";
  let imported_call_source =
    "import I from \"./library.aml\"\nprogram P implements I { fn inc(n: int): int { return n } }" in
  let imported_call = analyze imported_call_source ~resolve:(function
    | "./library.aml" -> Some "interface I { fn inc(n: int): int }"
    | _ -> None) in
  let imported_helper = List.find (fun d -> d.kind = "import" && d.name = "I")
      imported_call.declarations in
  require (Option.is_some imported_helper.selection) "import range";
  require (List.length imported_helper.uses = 1) "verified implements range";
  Option.iter (fun span -> require
    (String.sub imported_call_source span.first (span.last - span.first) = "I")
    "import declaration range") imported_helper.selection;
  List.iter (fun span -> require
    (String.sub imported_call_source span.first (span.last - span.first) = "I")
    "implements range") imported_helper.uses;
  let missing = analyze imported_source ~resolve:(fun _ -> None) in
  require (missing.diagnostics <> []) "missing interface source rejected";
  let wrong = analyze imported_source ~resolve:(fun _ -> Some "program I { fn inc(): int { return 1 } }") in
  require (wrong.diagnostics <> []) "function import is not interface import";

  let boundary = Filename.temp_file "amlc-workspace-boundary-" "" in
  Sys.remove boundary;
  Unix.mkdir boundary 0o700;
  let root = Filename.concat boundary "root" in
  Unix.mkdir root 0o700;
  let outside = Filename.concat boundary "outside.aml" in
  let consumer = Filename.concat root "consumer.aml" in
  let consumer_source =
    "import I from \"../outside.aml\"\nprogram P implements I { fn inc(n: int): int { return n } }" in
  let write path text =
    Out_channel.with_open_bin path (fun channel -> output_string channel text) in
  Fun.protect ~finally:(fun () ->
    List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) [consumer; outside];
    List.iter (fun path -> try Unix.rmdir path with Unix.Unix_error _ -> ()) [root; boundary])
    (fun () ->
      write outside "interface I { fn inc(n: int): int }";
      write consumer consumer_source;
      let result = workspace_references ~overlays:[] ~roots:[root]
        ~path:consumer consumer_source (String.index consumer_source 'I') in
      require (Yojson.Safe.Util.member "complete" result = `Bool false)
        "workspace import outside every root was treated as complete";
      require (Yojson.Safe.Util.member "items" result = `List [])
        "workspace import escaped its root");

  (* This is accepted by standalone AMLC but rejected by the old helper.
     Preserve official semantics, not the old fixture's 'invalid' label. *)
  let signed = "program Unsafe { public fn transfer(amount: int): int { return amount } }" in
  require (Result.is_ok (Octra_vm.Aml_source.compile ~syntax:Octra_vm.Oct_gen.Source signed))
    "upstream signed baseline";
  require ((analyze signed).diagnostics = []) "no Lite Node-only rejection";

  let diagnostic_text analysis =
    String.concat "\n" (List.map (fun diagnostic -> diagnostic.message) analysis.diagnostics) in
  let mentions text analysis =
    let haystack = diagnostic_text analysis in
    let needle = String.length text and limit = String.length haystack in
    let rec scan index =
      index + needle <= limit &&
      (String.sub haystack index needle = text || scan (index + 1)) in
    scan 0 in
  let source_program body = "program P { fn f" ^ body ^ " }" in
  let accept body label =
    let source = source_program body in
    let analysis = analyze source in
    require (analysis.diagnostics = [])
      (label ^ ": " ^ diagnostic_text analysis) in
  let reject body text label =
    let analysis = analyze (source_program body) in
    require (mentions text analysis)
      (label ^ ": " ^ diagnostic_text analysis) in
  accept "(raw: string): address { return to_address(raw) }"
    "to_address accepts one text argument";
  reject "(n: int): address { return to_address(n) }"
    "address input type differs" "to_address rejects a non-text argument";
  reject "(): address { return to_address() }"
    "to_address requires one argument" "to_address requires one argument";
  accept "(value: option[int]): int { return unwrap(value) }"
    "unwrap accepts an option expression";
  accept "(value: option[int]): bool { return is_some(value) }"
    "is_some accepts an option expression";
  accept "(text: string): int { return split(text, \",\") }"
    "split has an integer result in Source mode";
  accept "(): option[int] { return none() }"
    "none() remains an option value";
  let contract_option =
    "contract C { fn f(value: option[int]): int { return unwrap(value) } }" in
  require ((analyze contract_option).diagnostics = [])
    ("contract unwrap follows Source mode: " ^ diagnostic_text (analyze contract_option));
  let many count item =
    String.concat "\n" (List.init count item) in
  let reject_source source text label =
    let analysis = analyze ~resolve:(fun _ -> Some "interface Provided { fn m(): int }\n") source in
    require (mentions text analysis)
      (label ^ ": " ^ diagnostic_text analysis) in
  reject_source
    (many 257 (fun index -> Printf.sprintf "import I%d from \"i%d.aml\"" index index)
      ^ "\nprogram P { fn f(): int { return 1 } }")
    "Program import count exceeds compiler limit" "import count limit";
  reject_source
    ("import " ^ String.concat ", " (List.init 257 (fun index -> Printf.sprintf "N%d" index))
      ^ " from \"names.aml\"\nprogram P { fn f(): int { return 1 } }")
    "Program import name count exceeds compiler limit" "import name limit";
  reject_source
    (many 257 (fun index -> Printf.sprintf "interface I%d { fn m(): int }" index)
      ^ "\n")
    "Program interface count exceeds compiler limit" "interface count limit";
  reject_source
    ("interface Huge {\n"
      ^ many 4097 (fun index -> Printf.sprintf "  fn m%d(): int" index)
      ^ "\n}\n")
    "Program interface method count exceeds compiler limit" "interface method limit";

  let oversized = analyze (String.make 1_000_001 ' ') in
  require (oversized.status = Input_too_large) "input limit";
  require (oversized.declarations = [] && oversized.diagnostics = []) "limit before parsing";
  print_endline "Official AMLC adapter tests passed"
