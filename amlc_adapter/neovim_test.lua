local server = vim.fn.fnamemodify(assert(arg[1], "missing server"), ":p")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
vim.api.nvim_buf_set_name(0, directory .. "/unsaved.aml")
vim.bo.filetype = "aml"
local lines = {
  "// 한글",
  "program P {",
  "  fn inc(n: int): int { return n + 1 }",
  "  fn run(): int { return inc(1) }",
  "}",
}
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
local publications = 0
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.workspace.workspaceEdit.documentChanges = true
local id = assert(vim.lsp.start({
  name = "official-amlc-test",
  cmd = { server },
  cmd_env = { PATH = "", AMLC = "/must-not-run", REHOVOT_CHECK = "/must-not-run" },
  root_dir = directory,
  capabilities = capabilities,
  handlers = {
    ["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
      publications = publications + 1
      vim.lsp.handlers["textDocument/publishDiagnostics"](err, result, ctx, config)
    end,
  },
}))
local client = assert(vim.lsp.get_client_by_id(id))
local function wait(predicate, message)
  assert(vim.wait(20000, predicate, 25), message)
end
local function request(method, params)
  local response = assert(client:request_sync(method, params, 20000, 0), method)
  assert(not response.err, vim.inspect(response.err))
  return response.result
end
local ok, err = xpcall(function()
  wait(function() return client.initialized and publications > 0 end, "no initial diagnostics")
  assert(#vim.diagnostic.get(0) == 0, "valid source rejected")
  assert(client.server_capabilities.definitionProvider)
  local document = { uri = vim.uri_from_bufnr(0) }
  assert(client.server_capabilities.renameProvider and client.server_capabilities.codeActionProvider)
  local before = publications
  vim.api.nvim_buf_set_lines(0, 0, -1, false,
    { "program Fix { fn run(): int { return (1 + 2 } }" })
  wait(function()
    return publications > before and #vim.diagnostic.get(0) == 1
      and vim.diagnostic.get(0)[1].code == "AMLC101"
  end, "validated quick-fix diagnostic was not published")
  local quick_diagnostic = vim.diagnostic.get(0)[1]
  local quick_range = {
    start = { line = quick_diagnostic.lnum, character = quick_diagnostic.col },
    ["end"] = { line = quick_diagnostic.end_lnum, character = quick_diagnostic.end_col },
  }
  local quick_actions = request("textDocument/codeAction", {
    textDocument = document, range = quick_range, context = { diagnostics = { {
      range = quick_range, message = quick_diagnostic.message, code = quick_diagnostic.code,
      severity = quick_diagnostic.severity, source = quick_diagnostic.source,
    } } },
  })
  assert(#quick_actions == 1 and quick_actions[1].kind == "quickfix",
    "quick fix was not offered: " .. vim.inspect({ quick_diagnostic, quick_range, quick_actions }))
  vim.lsp.util.apply_workspace_edit(quick_actions[1].edit, client.offset_encoding)
  wait(function() return vim.api.nvim_get_current_line():find("2 )", 1, true) ~= nil end,
    "quick fix edit was not applied")
  before = publications
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end,
    "source did not recover after quick-fix test")
  assert(client.server_capabilities.semanticTokensProvider.full)
  local colors = request("textDocument/semanticTokens/full", { textDocument = document }).data
  local color_line, color_column, saw_function, saw_parameter = 0, 0, false, false
  for offset = 1, #colors, 5 do
    color_line = color_line + colors[offset]
    color_column = colors[offset] == 0 and color_column + colors[offset + 1] or colors[offset + 1]
    local kind = client.server_capabilities.semanticTokensProvider.legend.tokenTypes[colors[offset + 3] + 1]
    if color_line == 2 and color_column == 5 then
      assert(kind == "function" and colors[offset + 2] == 3)
      saw_function = true
    elseif color_line == 2 and color_column == 9 then
      assert(kind == "parameter" and colors[offset + 2] == 1)
      saw_parameter = true
    end
  end
  assert(saw_function and saw_parameter, "missing verified semantic colors")
  local result = request("textDocument/completion", {
    textDocument = document, position = { line = 3, character = 25 },
  })
  assert(vim.iter(result.items):any(function(item) return item.label == "inc" end), "no declaration completion")
  local targets = request("textDocument/definition", {
    textDocument = document, position = { line = 3, character = 25 },
  })
  assert(#targets == 1 and targets[1].range.start.line == 2, "incorrect function definition")
  local hover = request("textDocument/hover", {
    textDocument = document, position = { line = 3, character = 25 },
  })
  assert(hover.contents.value == "inc(n: int) -> int", "incorrect typed hover")
  before = publications
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { "  fn run(): int { return inc(true) }" })
  wait(function() return publications > before and #vim.diagnostic.get(0) > 0 end, "no changed-buffer diagnostic")
  before = publications
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { lines[4] })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "diagnostic did not clear")
  before = publications
  local binder_line = "  fn run(seed: int): int { return (let many seed: int = seed in seed) + seed }"
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { binder_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "term binder buffer was not checked")
  for _, case in ipairs({ { "= seed", 2, true }, { "in seed", 3, false }, { "+ seed", 2, true } }) do
    targets = request("textDocument/definition", {
      textDocument = document,
      position = { line = 3, character = binder_line:find(case[1], 1, true) - 1 + case[2] },
    })
    if case[3] then
      assert(#targets == 1 and targets[1].range.start.character == binder_line:find("seed: int", 1, true) - 1,
        "outer term use lost parameter navigation")
    else
      assert(#targets == 1 and targets[1].range.start.character == binder_line:find("many seed", 1, true) - 1 + #"many ",
        "term binder did not resolve to its own declaration")
    end
  end
  before = publications
  local local_line = "  fn run(seed: int): int { let secret: int = seed return secret }"
  local shadow_line = "  fn run(seed: int): bool { return let many seed: bool = true in"
  vim.api.nvim_buf_set_lines(0, 3, 5, false, { shadow_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) > 0 end, "unfinished term body lost diagnostics")
  result = request("textDocument/completion", {
    textDocument = document, position = { line = 3, character = #shadow_line },
  })
  local shadow_items = vim.iter(result.items):filter(function(item) return item.label == "seed" end):totable()
  assert(#shadow_items == 1 and shadow_items[1].detail == "let seed: bool", "EOF completion chose the shadowed parameter")
  before = publications
  vim.api.nvim_buf_set_lines(0, 3, -1, false, { local_line, "}" })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "local buffer was not checked")
  result = request("textDocument/completion", {
    textDocument = document,
    position = { line = 3, character = assert(local_line:find("return secret", 1, true)) - 1 },
  })
  assert(vim.iter(result.items):any(function(item)
    return item.label == "secret" and item.kind == 6 and item.detail == "let secret: int"
  end), "no scoped local completion")
  assert(vim.iter(result.items):any(function(item)
    return item.label == "seed" and item.kind == 6 and item.detail == "seed: int"
  end), "no scoped parameter completion")
  result = request("textDocument/completion", {
    textDocument = document, position = { line = 2, character = 25 },
  })
  assert(not vim.iter(result.items):any(function(item) return item.label == "secret" end), "local leaked into another function")
  assert(not vim.iter(result.items):any(function(item) return item.label == "seed" end), "parameter leaked into another function")
  before = publications
  local loop_line = "  fn run(seed: int): int { for seed in 0..2 { return seed } return seed }"
  local tuple_line = "  fn run(seed: int): int { let (seed, other) = (seed, 1) return seed + other }"
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { tuple_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "tuple buffer was not checked")
  targets = request("textDocument/definition", {
    textDocument = document,
    position = { line = 3, character = tuple_line:find("return seed", 1, true) - 1 + #"return " },
  })
  assert(#targets == 1 and targets[1].range.start.character == tuple_line:find("(seed, other)", 1, true),
    "tuple name navigated to the shadowed parameter")
  result = request("textDocument/completion", {
    textDocument = document,
    position = { line = 3, character = tuple_line:find("return seed", 1, true) - 1 },
  })
  assert(vim.iter(result.items):any(function(item) return item.label == "seed" and item.detail == "let seed" end),
    "missing tuple completion")
  before = publications
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { loop_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "loop buffer was not checked")
  local inner = assert(loop_line:find("return seed", 1, true))
  local outer = assert(loop_line:find("return seed", inner + 1, true))
  for _, check in ipairs({ { inner, "seed in" }, { outer, "seed: int" } }) do
    targets = request("textDocument/definition", {
      textDocument = document, position = { line = 3, character = check[1] - 1 + #"return " },
    })
    assert(#targets == 1 and targets[1].range.start.character == loop_line:find(check[2], 1, true) - 1,
      "loop exit did not restore the parameter binding")
  end
  before = publications
  local incomplete_line = "  fn run(seed: int): int { let secret = seed let unfinished = }"
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { incomplete_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) > 0 end, "incomplete edit lost its diagnostic")
  result = request("textDocument/completion", {
    textDocument = document,
    position = { line = 3, character = incomplete_line:find("unfinished =", 1, true) - 1 + #"unfinished =" },
  })
  assert(result.isIncomplete, "recovered candidates must be refreshed as typing continues")
  assert(vim.iter(result.items):any(function(item) return item.label == "secret" end), "incomplete edit lost preceding locals")
  assert(not vim.iter(result.items):any(function(item) return item.label == "unfinished" end), "incomplete binding was invented")
  before = publications
  local member_line = "program P { state { total: int } fn run(): int { return self. } }"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { member_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) > 0 end, "unfinished member lost its diagnostic")
  result = request("textDocument/completion", {
    textDocument = document,
    position = { line = 0, character = member_line:find("self.", 1, true) - 1 + #"self." },
  })
  assert(#result.items == 1 and result.items[1].label == "total" and result.items[1].kind == 5,
    "no compiler-backed state member completion")
  before = publications
  local method_line = "program P { state { entries: list[int] } fn run(): int { self.entries. } }"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { method_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) > 0 end, "unfinished method lost diagnostics")
  result = request("textDocument/completion", {
    textDocument = document,
    position = { line = 0, character = method_line:find("self.entries.", 1, true) - 1 + #"self.entries." },
  })
  assert(#result.items == 4 and vim.iter(result.items):any(function(item)
    return item.label == "push" and item.detail == "push(value: int)" and item.kind == 2
  end), "missing typed list method completion")
  before = publications
  local indexed_line = "program P { struct Account { count: int } state { accounts: map[int]Account } fn run(): int { return self.accounts[0]. } }"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { indexed_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) > 0 end, "unfinished indexed member lost its diagnostic")
  result = request("textDocument/completion", {
    textDocument = document,
    position = { line = 0, character = indexed_line:find("self.accounts[0].", 1, true) - 1 + #"self.accounts[0]." },
  })
  assert(#result.items == 1 and result.items[1].label == "count" and result.items[1].detail == "int",
    "indexed receiver lost its storage type")
  before = publications
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "program Fib { public fn fib(n: int): int {",
    "let a = 0 let b = 1 let i = 0",
    "while i < n { let t = a + b",
    "a = b b = t i = i + 1 }",
    "return a } }",
  })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "Fibonacci buffer was not checked")
  result = request("textDocument/completion", {
    textDocument = document, position = { line = 3, character = 0 },
  })
  for _, name in ipairs({ "n", "a", "b", "i", "t" }) do
    assert(vim.iter(result.items):any(function(item) return item.label == name and item.kind == 6 end),
      "while completion lost " .. name)
  end
  result = request("textDocument/completion", {
    textDocument = document, position = { line = 4, character = 7 },
  })
  assert(not vim.iter(result.items):any(function(item) return item.label == "t" end), "while local leaked after body")
  before = publications
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "program P { enum Mode { A, B } fn run(mode: Mode, n: int): int {",
    "if n > 0 { let x = 1 return x } else if n < 0 { let x = 2 return x }",
    "match mode { Mode.A => { let x = 3 return x } Mode.B => return n }",
    "return n } }",
  })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "branch buffer was not checked")
  for _, line in ipairs({ 1, 2 }) do
    local text = vim.api.nvim_buf_get_lines(0, line, line + 1, false)[1]
    targets = request("textDocument/definition", {
      textDocument = document,
      position = { line = line, character = text:find("return x", 1, true) - 1 + #"return " },
    })
    assert(#targets == 1 and targets[1].range.start.line == line
      and targets[1].range.start.character == text:find("x =", 1, true) - 1,
      "branch navigation selected another scope")
  end
  result = request("textDocument/completion", {
    textDocument = document, position = { line = 3, character = 7 },
  })
  assert(vim.iter(result.items):any(function(item) return item.label == "n" and item.kind == 6 end),
    "branch lost unshadowed parameter")
  assert(not vim.iter(result.items):any(function(item) return item.label == "x" end), "branch local leaked")
  before = publications
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "program P { state { n: int } fn run(n: int): int {",
    "let n = n + self.n",
    "n += n",
    "return n + n } }",
  })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "expression buffer was not checked")
  for _, check in ipairs({ { 1, 8, 0 }, { 2, 0, 1 }, { 2, 5, 1 }, { 3, 11, 1 } }) do
    targets = request("textDocument/definition", {
      textDocument = document, position = { line = check[1], character = check[2] },
    })
    assert(#targets == 1 and targets[1].range.start.line == check[3],
      "expression reference selected the wrong binding")
  end
  targets = request("textDocument/definition", {
    textDocument = document, position = { line = 1, character = 17 },
  })
  assert(#targets == 1 and targets[1].range.start.line == 0
    and targets[1].range.start.character == #"program P { state { ",
    "storage field was mistaken for a local")
  before = publications
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "program P { fn inc(n: int): int { return n + 1 }",
    "fn run(): int { let n = 1",
    "let result = inc(inc(n))",
    "return result } }",
  })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "nested call buffer was not checked")
  for _, column in ipairs({ 13, 17 }) do
    targets = request("textDocument/definition", {
      textDocument = document, position = { line = 2, character = column },
    })
    assert(#targets == 1 and targets[1].range.start.line == 0
      and targets[1].range.start.character == 15, "nested call did not resolve to its function")
  end
  before = publications
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "program P { fn choose(text: string, n: int): int { return n }",
    'fn run(): int { return choose("a,b", ',
  })
  wait(function() return publications > before and #vim.diagnostic.get(0) > 0 end, "unfinished signature lost diagnostics")
  result = request("textDocument/signatureHelp", {
    textDocument = document, position = { line = 1, character = #'fn run(): int { return choose("a,b", ' },
  })
  assert(result.signatures[1].label == "choose(text: string, n: int) -> int"
    and result.activeParameter == 1, "signature help counted a string comma as an argument")
  local immediate = "program P { state { fresh: int } fn run(): int { return self."
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { immediate })
  -- Request immediately: waiting for diagnostics here would hide the race.
  result = request("textDocument/completion", {
    textDocument = document, position = { line = 0, character = #immediate },
  })
  assert(#result.items == 1 and result.items[1].label == "fresh", "completion raced buffer analysis")
  before = publications
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "program P {", "fn run(): int {", "/* } */ return 1", "}", "}",
  })
  result = request("textDocument/formatting", {
    textDocument = document, options = { tabSize = 2, insertSpaces = true },
  })
  assert(#result == 3, "formatter did not return minimal line edits: " .. vim.inspect(result)
    .. " diagnostics=" .. vim.inspect(vim.diagnostic.get(0)))
  before = publications
  vim.lsp.util.apply_text_edits(result, vim.api.nvim_get_current_buf(), "utf-16")
  local formatted = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(formatted[2] == "  fn run(): int {" and formatted[3] == "    /* } */ return 1"
    and formatted[4] == "  }", "formatter changed comment semantics or indentation")
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "formatted buffer was not checked")
  result = request("textDocument/formatting", {
    textDocument = document, options = { tabSize = 2, insertSpaces = true },
  })
  assert(#result == 0, "second format changed the buffer again")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "program P {", "term unit", "}" })
  result = request("textDocument/formatting", {
    textDocument = document, options = { tabSize = 2, insertSpaces = true },
  })
  assert(#result == 1 and result[1].range.start.line == 1 and result[1].newText == "  ",
    "term formatting did not use the default server")
  before = publications
  vim.lsp.util.apply_text_edits(result, vim.api.nvim_get_current_buf(), "utf-16")
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "formatted term buffer was not checked")
  assert(vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == "  term unit", "term edit was not applied")
  before = publications
  local constructor_line = "program P { state { total: int } constructor(seed: int) { let value = seed self.total = value } }"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { constructor_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "constructor buffer was not checked")
  targets = request("textDocument/definition", { textDocument = document,
    position = { line = 0, character = constructor_line:find("= seed", 1, true) - 1 + #"= " },
  })
  assert(#targets == 1 and targets[1].range.start.character == constructor_line:find("seed: int", 1, true) - 1,
    "constructor parameter navigation failed")
  result = request("textDocument/completion", { textDocument = document,
    position = { line = 0, character = constructor_line:find("self.total", 1, true) - 1 },
  })
  assert(vim.iter(result.items):any(function(item) return item.label == "value" and item.detail == "let value" end),
    "constructor local completion failed")
  before = publications
  local form_line = "program P { form identity [] (many value: int) ->[many] int marks {} = value fn run(): int { return use identity[](1) as many result: int in result } }"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { form_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "form buffer was not checked")
  local form_position = { line = 0, character = form_line:find("= value", 1, true) - 1 + #"= " }
  targets = request("textDocument/definition", { textDocument = document, position = form_position })
  assert(#targets == 1 and targets[1].range.start.character == form_line:find("value: int", 1, true) - 1,
    "form parameter navigation failed")
  result = request("textDocument/completion", { textDocument = document, position = form_position })
  assert(vim.iter(result.items):any(function(item) return item.label == "value" and item.detail == "value: int" end),
    "form parameter completion failed")
  targets = request("textDocument/definition", { textDocument = document,
    position = { line = 0, character = form_line:find("use identity", 1, true) - 1 + #"use " },
  })
  assert(#targets == 1 and targets[1].range.start.character == form_line:find("form identity", 1, true) - 1 + #"form ",
    "explicit form use navigation failed")
  before = publications
  local signature_line = "program P { form add [many left: int] (many value: int) ->[many] int marks {} = left + value fn run(): int { return use add[1](2) as many result: int in result } }"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { signature_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "form signature buffer was not checked")
  for index, marker in ipairs({ "add[", "add[1](" }) do
    result = request("textDocument/signatureHelp", { textDocument = document,
      position = { line = 0, character = signature_line:find(marker, 1, true) - 1 + #marker },
    })
    assert(result and result.signatures[1].label == "add(left: int, value: int) -> int"
      and result.activeParameter == index - 1, "form capture/argument signature failed")
  end
  before = publications
  local enum_line = "interface I { fn get(value: Mode): Mode } program P { enum Mode { Ready } enum Other { Ready } struct Box { field: Mode } state { current: Mode } fn run(mode: Mode): Mode { let other: Other = Other.Ready return Mode.Ready } }"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { enum_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "enum buffer was not checked")
  targets = request("textDocument/definition", { textDocument = document,
    position = { line = 0, character = enum_line:find("Other.Ready", 1, true) - 1 + #"Other." },
  })
  assert(#targets == 1 and targets[1].range.start.character == enum_line:find("{ Ready", enum_line:find("enum Other", 1, true), true) - 1 + #"{ ",
    "enum variant navigation selected a different owner")
  for _, marker in ipairs({ "mode: ", "): ", "value: ", "field: ", "current: " }) do
    targets = request("textDocument/definition", { textDocument = document,
      position = { line = 0, character = enum_line:find(marker, 1, true) - 1 + #marker },
    })
    assert(#targets == 1 and targets[1].range.start.character == enum_line:find("enum Mode", 1, true) - 1 + #"enum ",
      "enum type annotation navigation failed")
  end
  before = publications
  local struct_line = "program P { struct Box { n: int } state { boxes: map[int]Box } fn run(): int { return self.boxes[0].n } }"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { struct_line })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end, "struct buffer was not checked")
  targets = request("textDocument/definition", { textDocument = document,
    position = { line = 0, character = struct_line:find("map[int]", 1, true) - 1 + #"map[int]" },
  })
  assert(#targets == 1 and targets[1].range.start.character == struct_line:find("struct Box", 1, true) - 1 + #"struct ",
    "struct type navigation failed")
  assert(vim.fn.filereadable(directory .. "/unsaved.aml") == 0, "analysis saved the buffer")
  targets = request("textDocument/definition", { textDocument = document,
    position = { line = 0, character = struct_line:find("self.boxes", 1, true) - 1 + #"self." },
  })
  assert(#targets == 1 and targets[1].range.start.character == struct_line:find("boxes: map", 1, true) - 1,
    "root state field navigation failed")
  for _, include in ipairs({ false, true }) do
    result = request("textDocument/references", { textDocument = document,
      position = { line = 0, character = struct_line:find("self.boxes", 1, true) - 1 + #"self." },
      context = { includeDeclaration = include },
    })
    assert(#result == (include and 2 or 1), "state references did not honor includeDeclaration")
    assert(result[#result].range.start.character == struct_line:find("self.boxes", 1, true) - 1 + #"self.",
      "state reference range is not the unsaved occurrence")
  end

  local library = directory .. "/library.aml"
  local consumer = directory .. "/consumer.aml"
  local unopened = directory .. "/unopened.aml"
  vim.fn.writefile({ "interface I { fn helper(n: int): int }" }, library)
  vim.fn.writefile({ 'import I from "./library.aml"',
    "program Consumer implements I { fn helper(n: int): int { return n } }" }, consumer)
  vim.fn.writefile({ 'import I from "./library.aml"',
    "program Unopened implements I { fn helper(n: int): int { return n } }" }, unopened)
  vim.cmd.edit(vim.fn.fnameescape(consumer))
  vim.bo.filetype = "aml"
  assert(vim.lsp.buf_attach_client(0, id), "could not attach workspace buffer")
  document = { uri = vim.uri_from_bufnr(0) }
  before = publications
  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = 0 })
  wait(function() return publications > before and #vim.diagnostic.get(0) == 0 end,
    "workspace consumer was not checked")
  local interface_position = { line = 1, character = #"program Consumer implements " }
  result = request("textDocument/references", { textDocument = document,
    position = interface_position, context = { includeDeclaration = true } })
  assert(#result == 5, "workspace interface references omitted a document: " .. vim.inspect(result))
  result = request("textDocument/prepareRename", {
    textDocument = document, position = interface_position })
  assert(result and result.placeholder == "I", "workspace prepareRename failed")
  result = request("textDocument/rename", {
    textDocument = document, position = interface_position, newName = "Renamed" })
  assert(result and #result.documentChanges == 3,
    "workspace rename did not return versioned document changes: " .. vim.inspect(result))
end, debug.traceback)
client:stop(true)
vim.bo.modified = false
vim.fn.delete(directory, "rf")
if not ok then error(err) end
print("Official AMLC Neovim: completion, navigation, workspace references/rename and diagnostics passed")
