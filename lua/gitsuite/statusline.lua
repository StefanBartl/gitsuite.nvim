---@module 'gitsuite.statusline'
--- Ambient merge-conflict indicator for a statusline plugin (lualine,
--- heirline, or the native statusline via `%{v:lua...}`), following the
--- ui.nvim-adapter pattern `sandbox.statusline`/`sessions.statusline`
--- already established (GS-10): a plain Lua string, no hard dependency on
--- any statusline plugin, cached so a statusline redrawing many times a
--- second never re-scans the buffer on every call.
---
--- Cached by `nvim_buf_get_changedtick`, not by the GS-10 card's original
--- "GS-06 events + BufWritePost" sketch: `conflict.choose()` always edits
--- the buffer, whether or not it resolves the *last* remaining region
--- (`GitsuiteConflictsResolved` only fires for that one case, by design --
--- see `gitsuite.events`), so an event-based cache would keep showing a
--- stale count between "resolved one of three" and "resolved the last one
--- or the next save". changedtick has no such gap -- it bumps on every
--- real edit, matches `ui.statusline.modules.recommender_badge`'s own
--- per-buffer cache in this same ecosystem (a sibling plugin's statusline
--- module, not gitsuite's own), and needs no autocmd wiring at all:
--- `M.status()` checks it lazily on the next call, which is still "no
--- process in the render path". `conflict.refresh()`'s own extmark/
--- highlight work never bumps changedtick (no text edited), so a plain
--- `:Git conflict refresh` after an external buffer reload is still
--- covered -- the reload itself is the edit that bumps it.

local M = {}

---@type table<integer, { tick: integer, text: string }>
local cache = {}

---@internal
---@param bufnr integer
---@return string
local function compute(bufnr)
  local cfg = require("gitsuite.config").get()
  if not cfg.features.conflict then return "" end

  local ok_req, conflict = pcall(require, "gitsuite.features.conflict")
  if not ok_req then return "" end

  local ok_scan, regions = pcall(conflict.scan, bufnr)
  if not ok_scan or #regions == 0 then return "" end

  return ("MERGE %d"):format(#regions)
end

---Ambient merge-conflict indicator for `bufnr` (default the current
---buffer), e.g. `"MERGE 2"` -- empty when the buffer has none, the
---`conflict` feature is off, or `bufnr` is invalid. Cached per buffer by
---`nvim_buf_get_changedtick`; safe to call unconditionally on every redraw.
---@param bufnr? integer
---@return string
function M.status(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok_tick, tick = pcall(vim.api.nvim_buf_get_changedtick, bufnr)
  if not ok_tick then return "" end

  local cached = cache[bufnr]
  if cached and cached.tick == tick then return cached.text end

  local text = compute(bufnr)
  cache[bufnr] = { tick = tick, text = text }
  return text
end

--- Ready-made lualine component function. Usage:
---   require("lualine").setup({
---     sections = { lualine_x = { require("gitsuite.statusline").lualine_component } },
---   })
M.lualine_component = M.status

return M
