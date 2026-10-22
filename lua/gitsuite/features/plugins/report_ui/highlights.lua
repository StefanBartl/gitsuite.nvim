---@module 'gitsuite.features.plugins.report_ui.highlights'
--- The report tab's highlight groups. Each links to a standard group with
--- `default = true`, so a colorscheme or the user can set them; they are made
--- when the tab first opens (not on `require`) and again after every
--- `ColorScheme`, which clears groups it does not know. Colour is never the
--- only signal: every state also has a glyph and a word (`render.lua`).

local M = {}

---Group -> the standard group it links to.
---@type table<string, string>
M.LINKS = {
  GitSuitePluginsHeader = "Title",
  GitSuitePluginsSection = "Statement",
  GitSuitePluginsName = "Directory",
  GitSuitePluginsSha = "Number",
  GitSuitePluginsDim = "Comment",
  GitSuitePluginsGroup = "Special",
  GitSuitePluginsBreaking = "DiagnosticError",
  GitSuitePluginsProbable = "DiagnosticWarn",
  GitSuitePluginsForward = "DiagnosticOk",
  GitSuitePluginsRollback = "DiagnosticWarn",
  GitSuitePluginsError = "DiagnosticError",
  GitSuitePluginsUnseen = "DiagnosticInfo",
  GitSuitePluginsStale = "DiagnosticHint",
}

local AUGROUP = "gitsuite_plugins_report_hl"

---(Re)define every group.
function M.define()
  for group, target in pairs(M.LINKS) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

---Define the groups and keep them across colorscheme changes. Idempotent.
function M.setup()
  M.define()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.define })
end

return M
