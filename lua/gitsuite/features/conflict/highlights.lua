---@module 'gitsuite.features.conflict.highlights'
--- Default highlight groups for conflict regions, defined ONCE, not on
--- every refresh: `nvim_set_hl` forces a full redraw, while an extmark
--- that merely references an already-defined group does not.
--- `default = true` on every group means a user's own highlight
--- (colorscheme or explicit override) always wins.

local M = {}

local defined = false

---@return nil
function M.setup()
  if defined then return end
  defined = true

  local set = vim.api.nvim_set_hl
  set(0, "GitSuiteConflictOurs", { link = "DiffAdd", default = true })
  set(0, "GitSuiteConflictBase", { link = "Comment", default = true })
  set(0, "GitSuiteConflictTheirs", { link = "DiffChange", default = true })
  set(0, "GitSuiteConflictMarker", { link = "DiffDelete", default = true })
end

return M
