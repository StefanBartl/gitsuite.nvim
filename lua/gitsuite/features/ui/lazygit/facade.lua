---@module 'gitsuite.features.ui.lazygit.facade'
--- Whether `:Git ui lazygit` can use terminal.nvim. One predicate shared by
--- the runtime (`features/ui/lazygit`) and `:checkhealth gitsuite`, so the
--- health report cannot claim terminal.nvim is used while the runtime falls
--- back to gitsuite.nvim's own float.

local M = {}

---@alias gitsuite.LazygitFacadeStatus
---| "ok"      # terminal.nvim, new enough to offer `run(argv, { direct = true })`
---| "absent"  # no Lua module `terminal` at all
---| "foreign" # a module `terminal` that is not (a new enough) terminal.nvim

---terminal.nvim's facade when it is installed and new enough to offer
---`run`; nil otherwise (optional dependency, the own float is the fallback).
---@return table|nil term
---@return gitsuite.LazygitFacadeStatus status
function M.resolve()
  local ok, term = pcall(require, "terminal")
  if not ok then return nil, "absent" end
  if type(term) == "table" and type(term.run) == "function" then return term, "ok" end
  return nil, "foreign"
end

return M
