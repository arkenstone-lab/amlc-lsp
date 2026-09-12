local server = assert(arg[1])
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local library = root .. "/library.aml"
local consumer = root .. "/consumer.aml"
local library_lines = { "program Library {", "public fn helper(n: int): int { return n }", "}" }
local consumer_lines = { 'import helper from "./library.aml"', "program Consumer {",
  "fn run(n: int): int { return helper(n) }", "}" }
vim.fn.writefile(library_lines, library)
vim.fn.writefile(consumer_lines, consumer)
vim.cmd.edit(vim.fn.fnameescape(consumer))
vim.bo.filetype = "aml"
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.workspace.workspaceEdit.documentChanges = true
local client_id = assert(vim.lsp.start({ name = "rename-test", cmd = { server }, root_dir = root,
  capabilities = capabilities }))
local client = assert(vim.lsp.get_client_by_id(client_id))
assert(vim.wait(10000, function() return client.initialized end, 50), "initialize timed out")
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// unsaved 😀" })
local document = { uri = vim.uri_from_bufnr(0) }
local position = { line = 3, character = consumer_lines[3]:find("helper", 1, true) + 1 }
local function request(method, extra)
  local params = vim.tbl_extend("force", { textDocument = document, position = position }, extra or {})
  local responses = vim.lsp.buf_request_sync(0, method, params, 10000)
  local response = assert(responses and responses[client_id], "missing " .. method)
  assert(not response.err, vim.inspect(response.err))
  return response.result
end
local prepared = request("textDocument/prepareRename")
assert(prepared and prepared.placeholder == "helper" and prepared.range.start.line == 3,
  "prepareRename ignored the unsaved snapshot: " .. vim.inspect(prepared))
local edit = request("textDocument/rename", { newName = "renamed" })
assert(edit and #edit.documentChanges == 2, "rename did not include both documents: " .. vim.inspect(edit))
for _, change in ipairs(edit.documentChanges) do
  if change.textDocument.uri == document.uri then
    assert(type(change.textDocument.version) == "number" and #change.edits == 2,
      "open consumer edits must be versioned and include import plus call")
  else
    assert(change.textDocument.uri == vim.uri_from_fname(vim.uv.fs_realpath(library)), "unexpected rename target")
    assert(change.textDocument.version == vim.NIL and #change.edits == 1, "closed declaration edit is invalid")
  end
end
assert(vim.deep_equal(vim.fn.readfile(library), library_lines), "request wrote to the library")
assert(vim.deep_equal(vim.fn.readfile(consumer), consumer_lines), "request saved the consumer")
local collision = request("textDocument/rename", { newName = "run" })
assert(collision == nil or collision == vim.NIL, "name collision was accepted")
vim.fn.writefile({ "program Broken {" }, root .. "/broken.aml")
local incomplete = request("textDocument/rename", { newName = "renamed" })
assert(incomplete == nil or incomplete == vim.NIL, "incomplete scan produced a partial rename")
-- Apply only the already-validated successful edit to test the client-facing shape.
vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding)
assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("renamed(n)", 1, true),
  "client could not apply the consumer edit")
local library_buffer = vim.fn.bufnr(library)
assert(library_buffer > 0 and table.concat(vim.api.nvim_buf_get_lines(library_buffer, 0, -1, false), "\n")
  :find("fn renamed", 1, true), "client could not apply the declaration edit")
client:stop()
vim.cmd("%bdelete!")
vim.fn.delete(root, "rf")
vim.cmd("qa!")
