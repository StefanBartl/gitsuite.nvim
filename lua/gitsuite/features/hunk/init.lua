---@module 'gitsuite.features.hunk'
--- Hunk actions, delegated to the gitsigns adapter (Schicht 3: gitsigns'
--- hunk engine is years of edge-case work, never nachbauen). There is no
--- native fallback for stage/reset/toggle-deleted -- that would mean
--- reimplementing gitsigns' git-index writes and deleted-line tracking.
--- `preview` alone degrades gracefully to `:Git diff head` (diff.nvim)
--- instead of erroring outright: that answers the same underlying question
--- ("what changed here") without gitsigns.

local adapter = require("gitsuite.adapter")
local notify = require("gitsuite.util.notify")

local M = {}

---@internal
---@return boolean
local function gitsigns_available()
  return adapter.resolve("gitsigns") ~= nil
end

---@internal
---@param action string
local function unavailable(action)
  notify.error(
    ('hunk %s: gitsigns.nvim is not installed -- install "lewis6991/gitsigns.nvim" to use :Git hunk %s'):format(
      action,
      action
    )
  )
end

---@return nil
function M.stage()
  if not gitsigns_available() then
    unavailable("stage")
    return
  end
  require("gitsuite.adapter.gitsigns").stage_hunk()
end

---@return nil
function M.reset()
  if not gitsigns_available() then
    unavailable("reset")
    return
  end
  require("gitsuite.adapter.gitsigns").reset_hunk()
end

---@return nil
function M.preview()
  if gitsigns_available() then
    require("gitsuite.adapter.gitsigns").preview_hunk()
    return
  end
  notify.info("hunk preview: gitsigns.nvim not installed -- falling back to :Git diff head")
  require("gitsuite.features.diff").head()
end

---@return nil
function M.stage_buffer()
  if not gitsigns_available() then
    unavailable("stage-buffer")
    return
  end
  require("gitsuite.adapter.gitsigns").stage_buffer()
end

---@return nil
function M.reset_buffer()
  if not gitsigns_available() then
    unavailable("reset-buffer")
    return
  end
  require("gitsuite.adapter.gitsigns").reset_buffer()
end

---@return nil
function M.toggle_deleted()
  if not gitsigns_available() then
    unavailable("toggle-deleted")
    return
  end
  require("gitsuite.adapter.gitsigns").toggle_deleted()
end

return M
