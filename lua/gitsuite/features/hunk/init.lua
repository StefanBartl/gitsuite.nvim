---@module 'gitsuite.features.hunk'
--- Hunk actions, delegated to the gitsigns adapter (Schicht 3: gitsigns'
--- hunk engine is years of edge-case work, never nachbauen). There is no
--- native fallback for stage/reset/toggle-deleted -- that would mean
--- reimplementing gitsigns' git-index writes and deleted-line tracking.
--- `preview` alone degrades gracefully to `:Git diff head` (diff.nvim)
--- instead of erroring outright: that answers the same underlying question
--- ("what changed here") without gitsigns.

local adapter = require("gitsuite.adapter")
local git = require("lib.nvim.git")
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

---@internal
---@param bufnr integer
---@return string|nil
local function repo_root_of(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return nil end
  return git.repo_root({ dir = vim.fs.dirname(path) })
end

---@internal
--- A gitsigns action callback (`fun(err?: string)`): fires
--- `GitsuiteStatusChanged` for `dir` once the write actually completed,
--- unless gitsigns reported an error.
---@param dir string|nil
---@return fun(err?: string)
local function on_status_changed(dir)
  return function(err)
    if err or not dir then return end
    require("gitsuite.events").status_changed(dir)
  end
end

---@return nil
function M.stage()
  if not gitsigns_available() then
    unavailable("stage")
    return
  end
  local dir = repo_root_of(vim.api.nvim_get_current_buf())
  require("gitsuite.adapter.gitsigns").stage_hunk(on_status_changed(dir))
end

---@return nil
function M.reset()
  if not gitsigns_available() then
    unavailable("reset")
    return
  end
  local dir = repo_root_of(vim.api.nvim_get_current_buf())
  require("gitsuite.adapter.gitsigns").reset_hunk(on_status_changed(dir))
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
  local dir = repo_root_of(vim.api.nvim_get_current_buf())
  require("gitsuite.adapter.gitsigns").stage_buffer(on_status_changed(dir))
end

---@return nil
function M.reset_buffer()
  if not gitsigns_available() then
    unavailable("reset-buffer")
    return
  end
  local dir = repo_root_of(vim.api.nvim_get_current_buf())
  require("gitsuite.adapter.gitsigns").reset_buffer()
  if dir then require("gitsuite.events").status_changed(dir) end
end

---@return nil
function M.toggle_deleted()
  if not gitsigns_available() then
    unavailable("toggle-deleted")
    return
  end
  require("gitsuite.adapter.gitsigns").toggle_deleted()
end

---Toggle inline diff: invert word_diff & linehl, preview the hunk under the
---cursor inline. A display toggle, not a git write -- unlike stage/reset,
---does not fire `GitsuiteStatusChanged`.
---@return nil
function M.inline()
  if not gitsigns_available() then
    unavailable("inline")
    return
  end
  require("gitsuite.adapter.gitsigns").toggle_inline_diff()
end

return M
