---@module 'gitsuite.features.ui.lazygit.replace'
--- Open a file selected in lazygit *in place of* the file currently shown
--- in the editor window behind the lazygit float. lazygit's `<C-o>` action,
--- called via `nvr` -- see docs/lazygit-config.yml. Ported from the nvim
--- config's `lua/config/lazygit/actions/replace.lua`, which pre-existed
--- this plugin.
---
--- Focus-safe: the edit runs via `nvim_win_call` (inside
--- `lib.nvim.buf_win_tab.normal_buffer.edit_in_window`), so the focused
--- lazygit terminal float is never disturbed.
---
--- Why no save prompt here (unlike a file-explorer's equivalent): when this
--- runs, the lazygit float owns the screen, so a blocking `vim.fn.confirm`
--- would be invisible and its input swallowed by lazygit. Instead, if the
--- target buffer has unsaved changes, this never clobbers it -- it falls
--- back to a plain badd so nothing is lost.

local notify = require("gitsuite.util.notify")
local resolve = require("lib.nvim.fs.path").from_repo_relative
local normal = require("lib.nvim.buf_win_tab.normal_buffer")
local badd = require("gitsuite.features.ui.lazygit.badd")

local fn = vim.fn

local M = {}

---@param raw string path from lazygit (repo-root-relative or absolute)
---@return boolean ok
function M.run(raw)
  if type(raw) ~= "string" or raw == "" then
    notify.warn("lazygit replace: no path received")
    return false
  end

  local path = resolve(raw)
  if fn.filereadable(path) ~= 1 then
    notify.warn(("lazygit replace: file not readable: %s"):format(path))
    return false
  end

  -- The focused window is the lazygit terminal float; its terminal buffer
  -- is skipped by is_normal_file_buffer, so it is never picked as the target.
  local target_buf, target_win = normal.find_last_normal_window()

  if not target_win then
    notify.info("lazygit replace: no editor window to replace; adding as buffer instead")
    return badd.run(raw)
  end

  if vim.api.nvim_get_option_value("modified", { buf = target_buf }) then
    notify.info("lazygit replace: target buffer modified; adding as buffer instead")
    return badd.run(raw)
  end

  local ok, err = normal.edit_in_window(target_win, path)
  if not ok then
    notify.warn(("lazygit replace failed: %s"):format(err or "?"))
    return false
  end

  notify.info(("replaced -> %s"):format(fn.fnamemodify(path, ":t")))
  return true
end

return M
