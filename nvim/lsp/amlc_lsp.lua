---@brief
--- https://github.com/arkenstone-lab/amlc-lsp
---
--- Language server for AppliedML. The companion runtime plugin can resolve or
--- install the server through OPAM; manual OPAM and Nix setups are also supported.
--- Register the filetype with `vim.filetype.add({ extension = { aml = 'aml' } })`.
---@type vim.lsp.Config
return {
  cmd = { 'amlc-lsp' },
  filetypes = { 'aml' },
  root_markers = { 'project.amlp', '.git' },
}
