---@module 'gitsuite.adapter.gitsigns'
--- Adapter for lewis6991/gitsigns.nvim -- hunk actions and blame text.
---
--- gitsigns owns its own `setup()` via the user's `lua/plugins/git.lua` spec
--- (LUA-90/92): this adapter never calls it and never `require`s "gitsigns"
--- to check availability, only `package.loaded` -- otherwise checking
--- availability would itself trigger a lazy-load. Action functions below
--- are only ever called after `is_available()` has already confirmed
--- gitsigns is loaded, so `require("gitsigns")` there is safe.

---@class GitSuite.Adapter.Gitsigns: GitSuite.Adapter
local M = { name = "gitsigns" }

---@return boolean
function M.is_available()
  return package.loaded["gitsigns"] ~= nil
end

---@return nil
function M.stage_hunk()
  require("gitsigns").stage_hunk()
end

---@return nil
function M.reset_hunk()
  require("gitsigns").reset_hunk()
end

---@return nil
function M.preview_hunk()
  require("gitsigns").preview_hunk()
end

---@return nil
function M.stage_buffer()
  require("gitsigns").stage_buffer()
end

---@return nil
function M.reset_buffer()
  require("gitsigns").reset_buffer()
end

---@return nil
function M.toggle_deleted()
  require("gitsigns").toggle_deleted()
end

return M
