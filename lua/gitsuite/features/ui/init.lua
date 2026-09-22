---@module 'gitsuite.features.ui'
--- `:Git ui lazygit|neogit|diffview {open|close}` -- TUI launchers. lazygit
--- is gitsuite.nvim's own (`features/ui/lazygit/`, a float + the real
--- `lazygit` binary); neogit and diffview are thin adapters (Schicht 3,
--- never nachbauen). diffview's file-history is not exposed here -- moved
--- onto diff.nvim's own `:Git diff history` (GS-08).

local adapter = require("gitsuite.adapter")
local notify = require("gitsuite.util.notify")

local M = {}

---Open the lazygit float, rooted at the cwd's repo or -- with `repo_dir` --
---at the repo containing that directory.
---@param repo_dir? string
---@return nil
function M.lazygit(repo_dir)
  require("gitsuite.features.ui.lazygit").open(repo_dir)
end

---Open neogit.
---@return nil
function M.neogit()
  local a = adapter.resolve("neogit")
  if not a then
    notify.error(
      'ui neogit: neogit is not installed -- install "NeogitOrg/neogit" to use :Git ui neogit'
    )
    return
  end
  ---@diagnostic disable-next-line: undefined-field
  a.open()
end

---@internal
---@return GitSuite.Adapter|nil
local function diffview_adapter()
  local a = adapter.resolve("diffview")
  if not a then
    notify.error(
      'ui diffview: diffview.nvim is not installed -- install "sindrets/diffview.nvim" to use :Git ui diffview'
    )
  end
  return a
end

---Open diffview.
---@return nil
function M.diffview_open()
  local a = diffview_adapter()
  ---@diagnostic disable-next-line: undefined-field
  if a then a.open() end
end

---Close the current diffview.
---@return nil
function M.diffview_close()
  local a = diffview_adapter()
  ---@diagnostic disable-next-line: undefined-field
  if a then a.close() end
end

return M
