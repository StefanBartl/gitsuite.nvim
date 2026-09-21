---@module 'gitsuite.adapter.gitsigns'
--- Adapter for lewis6991/gitsigns.nvim -- hunk actions and blame text.
---
--- gitsigns owns its own `setup()` via the user's `lua/plugins/git.lua` spec
--- (LUA-90/92): this adapter never calls it and never `require`s "gitsigns"
--- to check availability, only `package.loaded` -- otherwise checking
--- availability would itself trigger a lazy-load.

---@type GitSuite.Adapter
local M = { name = "gitsigns" }

---@return boolean
function M.is_available()
  return package.loaded["gitsigns"] ~= nil
end

return M
