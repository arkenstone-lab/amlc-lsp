local server = assert(arg[1], "missing amlc-lsp executable")
local project_dir = vim.fn.tempname()
local source = project_dir .. "/main.aml"
local lsp_timeout = 20000
local request_timeout = 10000

vim.fn.mkdir(project_dir, "p")
vim.fn.writefile({
  "program Broken {",
  "  term =",
  "}",
}, source)
vim.cmd.edit(vim.fn.fnameescape(source))
vim.bo.filetype = "aml"

local client_id = vim.lsp.start({
  name = "amlc-lsp-smoke-test",
  cmd = { server },
  root_dir = project_dir,
})

assert(client_id, "could not start amlc-lsp")
local client = assert(vim.lsp.get_client_by_id(client_id), "missing LSP client")
assert(vim.wait(lsp_timeout, function() return client.initialized end, 50), "LSP did not initialize")
assert(client.server_capabilities.completionProvider, "keyword completion was not advertised")
assert(not client.server_capabilities.diagnosticProvider, "push diagnostics also registered an automatic pull provider")
assert(client.server_capabilities.documentSymbolProvider, "document symbols were not advertised")
assert(client.server_capabilities.declarationProvider, "compiler-backed declarations were not advertised")
assert(client.server_capabilities.renameProvider, "compiler-backed rename was not advertised")
assert(client.server_capabilities.documentHighlightProvider, "compiler-backed document highlights were not advertised")
assert(client.server_capabilities.inlayHintProvider, "compiler-backed inlay hints were not advertised")
assert(client.server_capabilities.foldingRangeProvider, "folding ranges were not advertised")
assert(client.server_capabilities.selectionRangeProvider, "selection ranges were not advertised")
assert(client.server_capabilities.codeActionProvider, "compiler-backed quick fixes were not advertised")
assert(client.server_capabilities.documentFormattingProvider, "safe formatter was not advertised")
assert(client.server_capabilities.semanticTokensProvider, "compiler-backed semantic tokens were not advertised")
assert(client.server_capabilities.workspace and client.server_capabilities.workspace.workspaceFolders, "workspace folder support was not advertised")

local received = vim.wait(lsp_timeout, function()
  return #vim.diagnostic.get(0) > 0
end, 50)
assert(received, "timed out waiting for compiler diagnostics")

local completion = vim.lsp.buf_request_sync(0, "textDocument/completion", {
  textDocument = { uri = vim.uri_from_bufnr(0) },
  position = { line = 1, character = 2 },
}, request_timeout)
local result = assert(completion[client_id] and completion[client_id].result, "missing completion result")
local form = vim.tbl_filter(function(item) return item.label == "form" end, result.items)[1]
assert(form, "legacy AMLC completion did not include form")

local function request(method, params, timeout)
  local response
  if method == "textDocument/diagnostic" then
    -- This compatibility query is deliberately not an advertised provider.
    response = client:request_sync(method, params, timeout or request_timeout, 0)
  else
    local responses = vim.lsp.buf_request_sync(0, method, params, timeout or request_timeout)
    response = responses and responses[client_id]
  end
  response = assert(response, "missing " .. method .. " response")
  assert(not response.err, method .. " was rejected by the JSON-RPC dispatcher")
  return response.result
end

local document = { uri = vim.uri_from_bufnr(0) }
local pull_diagnostics = request("textDocument/diagnostic", { textDocument = document })
assert(pull_diagnostics and pull_diagnostics.kind == "full", "pull diagnostics did not return a full report")
assert(#pull_diagnostics.items > 0, "pull diagnostics lost the worker's errors")
request("textDocument/definition", { textDocument = document, position = { line = 1, character = 2 } })
request("textDocument/declaration", { textDocument = document, position = { line = 1, character = 2 } })
request("textDocument/references", { textDocument = document, position = { line = 1, character = 2 }, context = { includeDeclaration = true } })
request("textDocument/prepareRename", { textDocument = document, position = { line = 1, character = 2 } })
request("textDocument/rename", { textDocument = document, position = { line = 1, character = 2 }, newName = "renamed" })
request("textDocument/codeAction", { textDocument = document, range = { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 0 } }, context = { diagnostics = {} } })
request("textDocument/signatureHelp", { textDocument = document, position = { line = 1, character = 2 } })
request("textDocument/inlayHint", { textDocument = document, range = { start = { line = 0, character = 0 }, ['end'] = { line = 2, character = 0 } } })
request("textDocument/documentHighlight", { textDocument = document, position = { line = 1, character = 2 } })
request("textDocument/foldingRange", { textDocument = document })
request("textDocument/selectionRange", { textDocument = document, positions = { { line = 1, character = 2 } } })
request("textDocument/formatting", { textDocument = document, options = { tabSize = 2, insertSpaces = true } })
local tokens = request("textDocument/semanticTokens/full", { textDocument = document })
assert(tokens and tokens.data, "semantic-token request did not return a data envelope")
local workspace_symbols = request("workspace/symbol", { query = "contract" })
assert(workspace_symbols, "workspace-symbol request did not return a result")

local valid_source = project_dir .. "/valid.aml"
vim.fn.writefile({
  "program Demo {",
  "  form add [] (many value: int) ->[many] int marks {} = value",
  "  term add(1)",
  "}",
}, valid_source)
vim.cmd.edit(vim.fn.fnameescape(valid_source))
vim.bo.filetype = "aml"
vim.lsp.buf_attach_client(0, client_id)
local valid_document = { uri = vim.uri_from_bufnr(0) }
local valid_symbols
assert(vim.wait(lsp_timeout, function()
  local responses = vim.lsp.buf_request_sync(0, "textDocument/documentSymbol", { textDocument = valid_document }, 1000)
  local response = responses and responses[client_id]
  valid_symbols = response and response.result or {}
  return not (response and response.err) and #valid_symbols > 0
end, 50), "timed out waiting for compiler symbols on valid AML")

local definition = request("textDocument/definition", { textDocument = valid_document, position = { line = 2, character = 7 } })
assert(#definition > 0, "compiler-backed definition returned no declaration")
local references = request("textDocument/references", { textDocument = valid_document, position = { line = 2, character = 7 }, context = { includeDeclaration = true } })
assert(#references >= 2, "compiler-backed references omitted declaration or call")
local rename = request("textDocument/rename", { textDocument = valid_document, position = { line = 2, character = 7 }, newName = "sum" })
assert(rename and rename.changes, "compiler-backed rename returned no workspace edit")
local valid_tokens = request("textDocument/semanticTokens/full", { textDocument = valid_document })
assert(#valid_tokens.data > 0, "compiler-backed semantic tokens were empty for valid AML")

local applied_source = project_dir .. "/token.aml"
vim.fn.writefile({
  "contract Token {",
  "  state { total_supply: u128 }",
  "  private fn safe_add(left: u128, right: u128): u128 { return left + right }",
  "  fn transfer(to: address, amount: u128): bool {",
  "    let next = safe_add(amount, amount)",
  "    return true",
  "  }",
  "}",
}, applied_source)
vim.cmd.edit(vim.fn.fnameescape(applied_source))
vim.bo.filetype = "aml"
vim.lsp.buf_attach_client(0, client_id)
local applied_document = { uri = vim.uri_from_bufnr(0) }
local applied_symbols
assert(vim.wait(lsp_timeout, function()
  local responses = vim.lsp.buf_request_sync(0, "textDocument/documentSymbol", { textDocument = applied_document }, 1000)
  local response = responses and responses[client_id]
  applied_symbols = response and response.result or {}
  return not (response and response.err) and #applied_symbols > 0
end, 50), "timed out waiting for compiler symbols on valid AppliedML")
local applied_definition = request("textDocument/definition", { textDocument = applied_document, position = { line = 4, character = 17 } })
assert(#applied_definition > 0, "compiler-backed AppliedML definition returned no declaration")
local applied_tokens = request("textDocument/semanticTokens/full", { textDocument = applied_document })
assert(#applied_tokens.data > 0, "compiler-backed semantic tokens were empty for valid AppliedML")

local function completion_at(line, character)
  local result = request("textDocument/completion", {
    textDocument = applied_document, position = { line = line, character = character },
  })
  local items = {}
  for _, item in ipairs(result.items) do items[item.label] = item end
  return items
end
local local_items = completion_at(5, 4)
assert(local_items.to and local_items.amount and local_items.next, "function scope completion omitted bindings")
assert(local_items.next.detail == "u128", "local completion lost the declared function return type")
vim.api.nvim_buf_set_lines(0, 5, 6, false, { "    self." })
local members = completion_at(5, 9)
assert(members.total_supply and not members.fn and not members.amount, "member completion mixed receiver fields and globals")
vim.api.nvim_buf_set_lines(0, 5, 6, false, { "    return true" })

local library_source = project_dir .. "/library.aml"
vim.fn.writefile({ "program Library {", "public fn helper(n: u128): u128 { return n }", "}" }, library_source)
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  'import helper from "./library.aml"',
  'program Main {',
  'fn f(n: u128): u128 { return helper(n) }',
  '}',
})
local imported = completion_at(2, 31)
assert(imported.helper, "imported public function missing from completion")
local unopened_source = project_dir .. "/consumer.aml"
vim.fn.writefile({ 'import helper from "./library.aml"',
  'program Consumer { fn f(): u128 { return helper(1) } }' }, unopened_source)
local imported_references = request("textDocument/references", {
  textDocument = applied_document, position = { line = 2, character = 31 },
  context = { includeDeclaration = true },
})
assert(#imported_references == 5, "references omitted the unopened consumer: " .. vim.inspect(imported_references))
local calls_and_imports = request("textDocument/references", {
  textDocument = applied_document, position = { line = 2, character = 31 },
  context = { includeDeclaration = false },
})
assert(#calls_and_imports == 4, "references ignored includeDeclaration=false")
local imported_definition = request("textDocument/definition", {
  textDocument = applied_document, position = { line = 2, character = 31 },
})
assert(#imported_definition == 1 and imported_definition[1].uri == vim.uri_from_fname(vim.uv.fs_realpath(library_source)),
  "imported definition did not resolve to the source file: " .. vim.inspect(imported_definition))
local library_buffer = vim.fn.bufadd(library_source)
vim.fn.bufload(library_buffer)
vim.bo[library_buffer].filetype = "aml"
assert(vim.lsp.buf_attach_client(library_buffer, client_id), "could not attach the import buffer")
vim.api.nvim_buf_set_lines(library_buffer, 0, -1, false, {
  '// unsaved 한글', 'program Library {', '',
  'public fn fresh(n: u128): u128 { return n }', '}',
})
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  'import fresh from "./library.aml"', 'program Main {',
  'fn f(n: u128): u128 { return fresh(n) }', '}',
})
-- The client debounces didChange for the background import buffer.
assert(vim.wait(lsp_timeout, function() return completion_at(2, 30).fresh ~= nil end, 50),
  "completion ignored an unsaved import")
local unsaved_definition = request("textDocument/definition", {
  textDocument = applied_document, position = { line = 2, character = 30 },
})
assert(#unsaved_definition == 1 and unsaved_definition[1].range.start.line == 3,
  "definition did not use the unsaved import's range: " .. vim.inspect(unsaved_definition))
local unsaved_references = request("textDocument/references", {
  textDocument = applied_document, position = { line = 2, character = 30 },
  context = { includeDeclaration = true },
})
assert(#unsaved_references == 3, "references ignored the unsaved import")
assert(vim.tbl_contains(vim.tbl_map(function(location)
  return location.uri == vim.uri_from_bufnr(library_buffer) and location.range.start.line == 3
end, unsaved_references), true), "references used a stale declaration range")
assert(vim.fn.readfile(library_source)[2]:find("helper", 1, true), "query modified the disk import")
local function await_import_diagnostic(code)
  assert(vim.wait(lsp_timeout, function()
    local function matches(items)
      local found = nil
      for _, item in ipairs(items) do
        if tostring(item.code):match("^REHOVOT20") then found = item.code end
      end
      return found == code
    end
    return matches(request("textDocument/diagnostic", { textDocument = applied_document }).items)
      and matches(vim.diagnostic.get(0))
  end, 50), "push/pull import diagnostics did not converge to " .. tostring(code))
end
await_import_diagnostic(nil)
local valid_library = vim.api.nvim_buf_get_lines(library_buffer, 0, -1, false)
vim.api.nvim_buf_set_lines(library_buffer, 0, -1, false, { "program Library { fn" })
await_import_diagnostic("REHOVOT203")
vim.api.nvim_buf_set_lines(library_buffer, 0, -1, false, valid_library)
await_import_diagnostic(nil)
local leaf_source = project_dir .. "/leaf.aml"
vim.fn.writefile({ "program Leaf { public fn leafHelper(): int { return 1 } }" }, leaf_source)
vim.api.nvim_buf_set_lines(library_buffer, 0, 0, false, { 'import leafHelper from "./leaf.aml"' })
assert(vim.wait(lsp_timeout, function()
  local locations = request("textDocument/definition", {
    textDocument = applied_document, position = { line = 2, character = 30 },
  })
  return #locations == 1 and locations[1].range.start.line == 4
end, 50), "unsaved transitive import header was not synchronized")
local leaf_buffer = vim.fn.bufadd(leaf_source)
vim.fn.bufload(leaf_buffer)
vim.bo[leaf_buffer].filetype = "aml"
assert(vim.lsp.buf_attach_client(leaf_buffer, client_id), "could not attach the transitive import buffer")
vim.api.nvim_buf_set_lines(leaf_buffer, 0, -1, false, { "program Leaf { fn" })
await_import_diagnostic("REHOVOT203")
vim.api.nvim_buf_delete(leaf_buffer, { force = true })
await_import_diagnostic(nil)
assert(vim.fn.readfile(leaf_source)[1]:find("leafHelper", 1, true), "analysis changed the transitive import on disk")
vim.api.nvim_buf_delete(library_buffer, { force = true })
assert(not completion_at(2, 30).fresh, "closed import retained its unsaved overlay")
await_import_diagnostic("REHOVOT202")

-- Exercise the Zed reproduction: the importer is unchanged while an unsaved
-- dependency alternates between compatible and incompatible signatures.
local typed_source = project_dir .. "/typed_library.aml"
local typed_saved = { "program Types { public fn convert(value: int): int { return 1 } }" }
vim.fn.writefile(typed_saved, typed_source)
local typed_buffer = vim.fn.bufadd(typed_source)
vim.fn.bufload(typed_buffer)
vim.bo[typed_buffer].filetype = "aml"
assert(vim.lsp.buf_attach_client(typed_buffer, client_id))
local consumer_source = project_dir .. "/typecheck.aml"
vim.fn.writefile({ 'import convert from "./typed_library.aml"',
  "program Consumer { fn run(): int { return convert(true) } }" }, consumer_source)
vim.cmd.edit(vim.fn.fnameescape(consumer_source))
vim.bo.filetype = "aml"
assert(vim.lsp.buf_attach_client(0, client_id))
local function await_type_count(count)
  assert(vim.wait(lsp_timeout, function()
    return #vim.diagnostic.get(0) == count
  end, 50), "dependency diagnostics did not converge to " .. count)
  for _, item in ipairs(vim.diagnostic.get(0)) do
    assert(item.code == "REHOVOT301", "unexpected type diagnostic: " .. vim.inspect(item))
  end
end
await_type_count(1)
for _ = 1, 3 do
  vim.api.nvim_buf_set_lines(typed_buffer, 0, -1, false,
    { (typed_saved[1]:gsub("value: int", "value: bool")) })
  await_type_count(0)
  vim.api.nvim_buf_set_lines(typed_buffer, 0, -1, false, typed_saved)
  await_type_count(1)
end
assert(vim.deep_equal(vim.fn.readfile(typed_source), typed_saved), "type checks modified the disk dependency")
vim.api.nvim_buf_delete(typed_buffer, { force = true })

local program_source = project_dir .. "/program.aml"
vim.fn.writefile({
  "program Mixed {",
  "  form plus [many left: u128] (many right: u128) ->[many] u128 marks {} =",
  "    left + right",
  "",
  "  public pure fn calculate(left: u128, right: u128): u128 {",
  "    return plus(left, right)",
  "  }",
  "}",
}, program_source)
vim.cmd.edit(vim.fn.fnameescape(program_source))
vim.bo.filetype = "aml"
vim.lsp.buf_attach_client(0, client_id)
local program_document = { uri = vim.uri_from_bufnr(0) }
local program_symbols
assert(vim.wait(lsp_timeout, function()
  local responses = vim.lsp.buf_request_sync(0, "textDocument/documentSymbol", { textDocument = program_document }, 1000)
  local response = responses and responses[client_id]
  program_symbols = response and response.result or {}
  return not (response and response.err) and #program_symbols > 0
end, 50), "timed out waiting for AML Program symbols")
local program_completion = request("textDocument/completion", {
  textDocument = program_document,
  position = { line = 2, character = 2 },
})
local program_form = vim.tbl_filter(function(item) return item.label == "form" end, program_completion.items)[1]
local program_many = vim.tbl_filter(function(item) return item.label == "many" end, program_completion.items)[1]
assert(program_form and program_many, "AML Program completion omitted core keywords")
local program_definition = request("textDocument/definition", {
  textDocument = program_document,
  position = { line = 5, character = 13 },
})
assert(#program_definition > 0, "AML Program form definition returned no declaration")
local program_tokens = request("textDocument/semanticTokens/full", { textDocument = program_document })
assert(#program_tokens.data > 0, "AML Program semantic tokens were empty")

vim.lsp.stop_client(client_id)
vim.cmd("bdelete!")
vim.fn.delete(project_dir, "rf")
vim.cmd("qa!")
