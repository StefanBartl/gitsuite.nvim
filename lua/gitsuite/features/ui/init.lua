---@module 'gitsuite.features.ui'
--- `:Git ui lazygit|neogit|diffview` -- TUI launchers. lazygit is
--- gitsuite.nvim's own (`features/ui/lazygit/`, a float + the real
--- `lazygit` binary); neogit and diffview are thin adapters (Schicht 3,
--- never nachbauen).

local adapter = require("gitsuite.adapter")
local notify = require("gitsuite.util.notify")

local M = {}

---Open the lazygit float.
---@return nil
function M.lazygit()
  require("gitsuite.features.ui.lazygit").open()
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

---Open diffview.
---@return nil
function M.diffview()
  local a = adapter.resolve("diffview")
  if not a then
    notify.error(
      'ui diffview: diffview.nvim is not installed -- install "sindrets/diffview.nvim" to use :Git ui diffview'
    )
    return
  end
  ---@diagnostic disable-next-line: undefined-field
  a.open()
end

return M
