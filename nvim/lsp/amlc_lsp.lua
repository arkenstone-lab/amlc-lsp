---@brief
--- https://github.com/arkenstone-lab/amlc-lsp
---
--- Language server for AppliedML. Install it with the Git-pinned OPAM or Nix
--- procedure documented in the repository README.
--- Register the filetype with `vim.filetype.add({ extension = { aml = 'aml' } })`.
---@type vim.lsp.Config
return {
  cmd = { 'amlc-lsp' },
  filetypes = { 'aml' },
  root_markers = { 'project.amlp', '.git' },
}
