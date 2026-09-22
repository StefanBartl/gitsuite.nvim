---@module 'gitsuite.adapter.diffview'
--- Adapter for sindrets/diffview.nvim -- side-by-side diff, file history.
--- Never nachbaubar (Schicht 3): jahrelange Edge-Case-Arbeit, stays a pure
--- adapter. Owns its own `setup()` via `lua/plugins/git.lua` (LUA-90/92).

---@class GitSuite.Adapter.Diffview: GitSuite.Adapter
local M = { name = "diffview" }

---@return boolean
function M.is_available()
  return package.loaded["diffview"] ~= nil
end

---@return nil
function M.open()
  require("diffview").open({})
end

---Close the current diffview tab.
---@return nil
function M.close()
  require("diffview").close()
end

return M
