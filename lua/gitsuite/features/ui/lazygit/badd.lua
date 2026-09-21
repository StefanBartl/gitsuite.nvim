---@module 'gitsuite.features.ui.lazygit.badd'
--- Add a file selected in lazygit to the parent Neovim's buffer list,
--- without loading or focusing it (`:badd`). lazygit's `O` action, called
--- via `nvr` -- see docs/lazygit-config.yml. Ported from the nvim config's
--- `lua/config/lazygit/actions/badd.lua`, which pre-existed this plugin.

local notify = require("gitsuite.util.notify")
local resolve = require("lib.nvim.fs.path").from_repo_relative
local open_background = require("lib.nvim.buffer.open_background")

local fn = vim.fn

local M = {}

---@param raw string path from lazygit (repo-root-relative or absolute)
---@return boolean ok
function M.run(raw)
  if type(raw) ~= "string" or raw == "" then
    notify.warn("lazygit badd: no path received")
    return false
  end

  local path = resolve(raw)
  if fn.filereadable(path) ~= 1 then
    notify.warn(("lazygit badd: file not readable: %s"):format(path))
    return false
  end

  local ok, err = open_background(path, { load = false })
  if not ok then
    notify.warn(("lazygit badd failed: %s"):format(err))
    return false
  end

  notify.info(("+buffer %s"):format(fn.fnamemodify(path, ":t")))
  return true
end

return M
