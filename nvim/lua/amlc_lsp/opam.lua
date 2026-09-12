local M = {}

local required_amlc_version = "0.1.0~preview"
local server_package = "amlc-lsp.0.3.0"
local server_source = "git+https://github.com/arkenstone-lab/amlc-lsp.git#34d5c62c5e45687a0b0bd384d79657621b2deb12"

local installing = false

local function notify(message, level)
  vim.notify(message, level, { title = "AppliedML" })
end

local function opam_command()
  return vim.g.amlc_lsp_opam_path or "opam"
end

local function working_directory()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    local root = vim.fs.root(name, { "project.amlp", ".git" })
    if root then
      return root
    end
    return vim.fs.dirname(name)
  end
  return vim.uv.cwd()
end

local function run(args, callback)
  local command = { opam_command() }
  vim.list_extend(command, args)
  local ok, error_or_process = pcall(vim.system, command, {
    cwd = working_directory(),
    text = true,
  }, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback({ code = -1, stdout = "", stderr = tostring(error_or_process) })
    end)
  end
end

local function executable_in(directory)
  local name = jit.os == "Windows" and "amlc-lsp.exe" or "amlc-lsp"
  return vim.fs.joinpath(vim.trim(directory), name)
end

local function use_server(executable)
  vim.lsp.enable("amlc_lsp", false)
  vim.lsp.config("amlc_lsp", { cmd = { executable } })
  vim.lsp.enable("amlc_lsp")
  notify("Using " .. executable, vim.log.levels.INFO)
end

local function finish_with_error(message)
  installing = false
  notify(message, vim.log.levels.ERROR)
end

local function locate_installed(callback)
  run({ "var", "bin" }, function(result)
    if result.code ~= 0 or vim.trim(result.stdout or "") == "" then
      callback(nil)
      return
    end
    local executable = executable_in(result.stdout)
    callback(vim.uv.fs_stat(executable) and executable or nil)
  end)
end

local function install_server()
  notify("Installing amlc-lsp in the active OPAM switch…", vim.log.levels.INFO)
  run({
    "pin",
    "add",
    "--yes",
    "--ignore-pin-depends",
    server_package,
    server_source,
  }, function(result)
    if result.code ~= 0 then
      local detail = vim.trim(result.stderr or "")
      finish_with_error("OPAM could not install amlc-lsp" .. (detail ~= "" and ": " .. detail or ""))
      return
    end
    locate_installed(function(executable)
      installing = false
      if not executable then
        notify("OPAM completed, but amlc-lsp was not found in the switch bin directory", vim.log.levels.ERROR)
        return
      end
      use_server(executable)
    end)
  end)
end

local function confirm_install()
  vim.ui.select({ "Install", "Cancel" }, {
    prompt = "Install amlc-lsp 0.3.0 in the active OPAM switch? AMLC will not be changed.",
  }, function(choice)
    if choice ~= "Install" then
      installing = false
      return
    end
    install_server()
  end)
end

local function check_amlc()
  run({ "show", "--field=installed-version", "amlc" }, function(result)
    local version = vim.trim(result.stdout or "")
    if result.code == -1 then
      finish_with_error("Could not run OPAM: " .. vim.trim(result.stderr or "unknown error"))
    elseif result.code ~= 0 or version == "" then
      finish_with_error("AMLC is not installed in the active OPAM switch")
    elseif version ~= required_amlc_version then
      finish_with_error(
        "The active OPAM switch contains amlc " .. version .. "; amlc-lsp 0.3.0 requires " .. required_amlc_version
      )
    else
      confirm_install()
    end
  end)
end

function M.install()
  if installing then
    notify("An amlc-lsp installation is already running", vim.log.levels.WARN)
    return
  end
  installing = true
  locate_installed(function(executable)
    if executable then
      installing = false
      use_server(executable)
    else
      check_amlc()
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("AmlcLspInstall", M.install, {
    desc = "Install amlc-lsp in the active OPAM switch without changing AMLC",
  })

  if vim.fn.exepath("amlc-lsp") == "" then
    local opam = vim.fn.exepath(opam_command())
    if opam ~= "" then
      vim.lsp.config("amlc_lsp", { cmd = { opam, "exec", "--", "amlc-lsp" } })
    end
  end
end

return M
