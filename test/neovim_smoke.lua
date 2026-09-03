local server = assert(arg[1], "missing amlc-lsp executable")
local project_dir = vim.fn.tempname()
local source = project_dir .. "/main.aml"

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
assert(vim.wait(5000, function() return client.initialized end, 50), "LSP did not initialize")
assert(client.server_capabilities.completionProvider, "keyword completion was not advertised")
assert(client.server_capabilities.diagnosticProvider, "compiler-backed pull diagnostics were not advertised")
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

local received = vim.wait(6000, function()
  return #vim.diagnostic.get(0) > 0
end, 50)
assert(received, "timed out waiting for compiler diagnostics")

local completion = vim.lsp.buf_request_sync(0, "textDocument/completion", {
  textDocument = { uri = vim.uri_from_bufnr(0) },
  position = { line = 1, character = 2 },
}, 5000)
local result = assert(completion[client_id] and completion[client_id].result, "missing completion result")
local form = vim.tbl_filter(function(item) return item.label == "form" end, result.items)[1]
assert(form, "legacy AMLC completion did not include form")

local function request(method, params, timeout)
  local responses = vim.lsp.buf_request_sync(0, method, params, timeout or 5000)
  local response = assert(responses[client_id], "missing " .. method .. " response")
  assert(not response.err, method .. " was rejected by the JSON-RPC dispatcher")
  return response.result
end

local document = { uri = vim.uri_from_bufnr(0) }
local pull_diagnostics = request("textDocument/diagnostic", { textDocument = document })
assert(pull_diagnostics and pull_diagnostics.kind == "full", "pull diagnostics did not return a full report")
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
assert(vim.wait(6000, function()
  local responses = vim.lsp.buf_request_sync(0, "textDocument/documentSymbol", { textDocument = valid_document }, 500)
  local response = responses[client_id]
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
assert(vim.wait(6000, function()
  local responses = vim.lsp.buf_request_sync(0, "textDocument/documentSymbol", { textDocument = applied_document }, 500)
  local response = responses[client_id]
  applied_symbols = response and response.result or {}
  return not (response and response.err) and #applied_symbols > 0
end, 50), "timed out waiting for compiler symbols on valid AppliedML")
local applied_definition = request("textDocument/definition", { textDocument = applied_document, position = { line = 4, character = 17 } })
assert(#applied_definition > 0, "compiler-backed AppliedML definition returned no declaration")
local applied_tokens = request("textDocument/semanticTokens/full", { textDocument = applied_document })
assert(#applied_tokens.data > 0, "compiler-backed semantic tokens were empty for valid AppliedML")

vim.lsp.stop_client(client_id)
vim.cmd("bdelete!")
vim.fn.delete(project_dir, "rf")
