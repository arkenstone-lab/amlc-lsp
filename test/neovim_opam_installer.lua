local plugin = vim.fn.fnamemodify(assert(arg[1], "missing Neovim plugin path"), ":p")
local runtime = vim.fn.fnamemodify(plugin, ":h:h")
local directory = vim.fn.tempname()
local bin = directory .. "/bin"
local log = directory .. "/opam.log"
local fake_opam = directory .. "/opam"

vim.fn.mkdir(bin, "p")
vim.fn.writefile({
  "#!/bin/sh",
  "printf '%s\\n' \"$*\" >> " .. vim.fn.shellescape(log),
  'case "$1" in',
  "  var) printf '%s\\n' " .. vim.fn.shellescape(bin) .. " ;;",
  "  show) printf '%s\\n' '0.1.0~preview' ;;",
  "  pin) : > " .. vim.fn.shellescape(bin .. "/amlc-lsp") .. " ;;",
  "esac",
}, fake_opam)
assert(vim.uv.fs_chmod(fake_opam, 493), "could not make fake OPAM executable")

local configured
local enabled = {}
vim.lsp.config = function(name, config)
  assert(name == "amlc_lsp")
  configured = config.cmd
end
vim.lsp.enable = function(name, enable)
  assert(name == "amlc_lsp")
  table.insert(enabled, enable ~= false)
end
vim.ui.select = function(items, _, callback)
  assert(vim.tbl_contains(items, "Install"))
  callback("Install")
end
vim.notify = function() end
vim.g.amlc_lsp_opam_path = fake_opam
vim.opt.runtimepath:prepend(runtime)
vim.cmd.source(vim.fn.fnameescape(plugin))

assert(vim.fn.exists(":AmlcLspInstall") == 2, "installer command was not registered")
configured = nil
require("amlc_lsp.opam").install()
assert(
  vim.wait(10000, function()
    return configured and configured[1] == bin .. "/amlc-lsp"
  end, 20),
  "installer did not configure the installed server"
)

local calls = vim.fn.readfile(log)
assert(calls[1] == "var bin", "existing-server lookup used unexpected arguments")
assert(calls[2] == "show --field=installed-version amlc", "AMLC preflight was not exact")
assert(calls[3] == table.concat({
  "pin",
  "add",
  "--yes",
  "--ignore-pin-depends",
  "amlc-lsp.0.3.0",
  "git+https://github.com/arkenstone-lab/amlc-lsp.git#34d5c62c5e45687a0b0bd384d79657621b2deb12",
}, " "), "installer pin command changed")
assert(calls[4] == "var bin", "installed server was not located")
assert(enabled[#enabled - 1] == false and enabled[#enabled] == true, "LSP was not restarted")

vim.fn.delete(bin .. "/amlc-lsp")
vim.g.amlc_lsp_opam_path = directory .. "/missing-opam"
local reported
vim.notify = function(message, level)
  if level == vim.log.levels.ERROR then
    reported = message
  end
end
require("amlc_lsp.opam").install()
assert(
  vim.wait(10000, function()
    return reported and reported:find("Could not run OPAM", 1, true)
  end, 20),
  "a missing OPAM executable was not reported"
)

vim.fn.delete(directory, "rf")
