---@module 'gitsuite.adapter.neogit'
--- Adapter for NeogitOrg/neogit -- the staging UI. Never nachbaubar
--- (Schicht 3). Owns its own `setup()` via `lua/plugins/git.lua` (LUA-90/92).

---@class GitSuite.Adapter.Neogit: GitSuite.Adapter
local M = { name = "neogit" }

---@return boolean
function M.is_available()
  return package.loaded["neogit"] ~= nil
end

---@return nil
function M.open()
  require("neogit").open()
end

return M
