---@module 'gitsuite.features.ui'
--- `:Git ui lazygit|neogit|diffview {open|close}` -- TUI launchers. lazygit
--- is gitsuite.nvim's own (`features/ui/lazygit/`, a float + the real
--- `lazygit` binary); neogit and diffview are thin adapters (Schicht 3,
--- never nachbauen). diffview's file-history is not exposed here -- moved
--- onto diff.nvim's own `:Git diff history` (GS-08).
---
--- `diffview {open|close}` never hard-requires sindrets/diffview.nvim
--- (interactive-review fix after GS-08): diffview.nvim was always meant to
--- be optional richer tooling, not a second required diff backend next to
--- diff.nvim, gitsuite's own hard dependency -- a plugin without diffview.nvim
--- installed falls back onto `gitsuite.features.diff`'s own `split()`/
--- `close()` instead of erroring "not installed" for two keymaps
--- (`<leader>dv`/`<leader>dc`) that already have a perfectly good backend.

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

---Open diffview.nvim's multi-file review UI when it is installed;
---otherwise diff.nvim's own interactive diff picker (`:Git diff split`) --
---diffview.nvim is optional, richer tooling, never a required second diff
---backend.
---@return nil
function M.diffview_open()
  local a = adapter.resolve("diffview")
  if a then
    ---@diagnostic disable-next-line: undefined-field
    a.open()
    return
  end
  require("gitsuite.features.diff").split()
end

---Close the current diffview.nvim view when it is installed; otherwise
---close diff.nvim's own diff (`:Git diff close`).
---@return nil
function M.diffview_close()
  local a = adapter.resolve("diffview")
  if a then
    ---@diagnostic disable-next-line: undefined-field
    a.close()
    return
  end
  require("gitsuite.features.diff").close()
end

return M
