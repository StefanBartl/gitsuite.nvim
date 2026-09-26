---@module 'gitsuite.util.progress'
---@brief Progress indicator for bulk repository operations.
---@description
--- Thin wrapper over `lib.nvim.progress`, which abstracts "an operation is
--- running" away from "how that is shown" (notify, statusline, fidget, or a
--- floating window). gitsuite needs it for the two commands that walk a whole
--- directory of clones — `:Git dashboard update` and `:Git dashboard` — where the
--- per-repository `git` calls are individually fast but collectively take long
--- enough to look like a hang.
---
--- `lib.nvim` itself is a hard, required dependency of this plugin (see
--- docs/requirements.md): every other module requires it bare, at module
--- load, with no fallback, so a missing lib.nvim already stops the plugin
--- long before this module's `M.create` would ever run. The `pcall` below is
--- local defensive padding for this one indicator, not evidence of a
--- project-wide soft-dependency convention -- if it ever did trip, `M.create`
--- returns `nil` and every call site's `if handle then` guard skips the
--- indicator entirely; nothing else is affected.
---
--- Style comes from `config.get().progress_style` and is read on each call
--- rather than cached at require time, so `setup()` ordering never matters.

---@class GitSuite.Util.Progress
local M = {}

local ok_progress, progress_mod = pcall(require, "lib.nvim.progress")

---Starts a progress handle, or returns nil when lib.nvim isn't installed.
---@param text string Initial message, shown after the "[gitsuite]" title
---@param total integer|nil Total unit count, when the operation is countable
---@return Lib.Progress.Handle|nil
function M.create(text, total)
  if not ok_progress then return nil end

  local style = "auto"
  local ok_cfg, config = pcall(require, "gitsuite.config")
  if ok_cfg then style = config.get().progress_style or style end

  local handle = progress_mod.create({ title = "[gitsuite]", style = style })
  handle:update({ text = text, current = 0, total = total })
  return handle
end

return M
