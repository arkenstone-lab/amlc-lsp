if vim.fn.has("nvim-0.11") == 0 or vim.g.loaded_amlc_lsp_plugin then
  return
end

vim.g.loaded_amlc_lsp_plugin = true

vim.filetype.add({ extension = { aml = "aml" } })

vim.api.nvim_create_autocmd("FileType", {
  pattern = "aml",
  callback = function(args)
    if vim.bo[args.buf].syntax == "" then vim.bo[args.buf].syntax = "aml" end
  end,
})

vim.lsp.config("amlc_lsp", {
  cmd = { "amlc-lsp" },
  filetypes = { "aml" },
  root_markers = { "project.amlp", ".git" },
  single_file_support = true,
})

vim.lsp.enable("amlc_lsp")
