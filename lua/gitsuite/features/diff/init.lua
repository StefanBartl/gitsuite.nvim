---@module 'gitsuite.features.diff'
--- `:Git diff head|last|rev|split|history` -- a thin alias onto diff.nvim's
--- own public Lua API (`require("diff")`), not string-built `vim.cmd`
--- invocations: diff.nvim already owns every diff view in this ecosystem
--- and is never reimplemented, so this feature is deliberately a few
--- lines that hand off, not a reimplementation.

local M = {}

---Diff the current file against HEAD.
---@return nil
function M.head()
  require("diff").run("target=git:HEAD")
end

---Diff the current file against the previous commit.
---@return nil
function M.last()
  require("diff").run("target=git:HEAD~1")
end

---Diff the current file against an arbitrary revision.
---@param rev string
---@return nil
function M.rev(rev)
  require("diff").run("target=git:" .. rev)
end

---Open diff.nvim's interactive target/source picker (bare `:Diff`).
---@return nil
function M.split()
  require("diff").run("")
end

---Show file history (diff.nvim's `:DiffHistory`) for the current file.
---@return nil
function M.history()
  require("diff").diff_history("")
end

---Close every open diff.nvim view and leave diff mode (diff.nvim's own
---`:DiffClear`). Used as `:Git ui diffview close`'s fallback when
---diffview.nvim is not installed (GS-08/interactive-review fix).
---@return nil
function M.close()
  require("diff").clear()
end

return M
