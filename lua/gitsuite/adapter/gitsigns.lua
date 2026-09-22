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

---`callback` (`fun(err?: string)`), when given, is gitsigns' own async
---completion callback -- called after the git index write actually
---happened, not merely after the (async) action was requested.
---@param callback? fun(err?: string)
---@return nil
function M.stage_hunk(callback)
  require("gitsigns").stage_hunk(nil, nil, callback)
end

---@param callback? fun(err?: string)
---@return nil
function M.reset_hunk(callback)
  require("gitsigns").reset_hunk(nil, nil, callback)
end

---@return nil
function M.preview_hunk()
  require("gitsigns").preview_hunk()
end

---@param callback? fun(err?: string)
---@return nil
function M.stage_buffer(callback)
  require("gitsigns").stage_buffer(callback)
end

---@return nil
function M.reset_buffer()
  require("gitsigns").reset_buffer()
end

---@return nil
function M.toggle_deleted()
  require("gitsigns").toggle_deleted()
end

---Toggle inline diff: invert word_diff & linehl, then preview the hunk under
---the cursor inline (temporary) -- the old `:ToggleInlineDiff` combo from
---`nvim-config`'s `bindings/mappings/git.lua` (GS-08), moved here as an
---adapter method. Falls back to the popup preview on a gitsigns version
---without `preview_hunk_inline` (added later than `toggle_word_diff`/
---`toggle_linehl`).
---@return nil
function M.toggle_inline_diff()
  local gs = require("gitsigns")
  gs.toggle_word_diff()
  gs.toggle_linehl()
  if type(gs.preview_hunk_inline) == "function" then
    gs.preview_hunk_inline()
  else
    gs.preview_hunk()
  end
end

return M
