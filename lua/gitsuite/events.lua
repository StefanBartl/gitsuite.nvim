---@module 'gitsuite.events'
--- The one place gitsuite.nvim fires its `User` autocmd events from (D-2:
--- events, not direct `pcall(require, ...)` integrations -- see
--- `integrations/pickers_nvim.lua`'s docstring for the sibling rule on the
--- *consuming* side). gitsuite itself never requires or knows about a
--- consumer; a sister plugin that wants to react to a branch switch, a
--- buffer's conflicts all being resolved, or a hunk stage/reset subscribes
--- with its own `autocmd User Gitsuite* ...`. Payload shapes are declared on
--- `GitSuite.Event.*` in `@types/init.lua` and in `doc/gitsuite.txt`.

local M = {}

---Fired after `gitsuite.features.branch.switch()` (or any future
---branch-changing action) checks out a different branch.
---@param dir string  Repo root the checkout ran in.
---@param branch string  The branch now checked out.
---@return nil
function M.branch_switched(dir, branch)
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "GitsuiteBranchSwitched", data = { dir = dir, branch = branch } }
  )
end

---Fired after `gitsuite.features.conflict.choose()` resolves the last
---remaining conflict region in a buffer (not on every `choose()` call --
---only once the buffer has none left).
---@param bufnr integer
---@return nil
function M.conflicts_resolved(bufnr)
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "GitsuiteConflictsResolved", data = { bufnr = bufnr } }
  )
end

---Fired after a hunk stage/reset (single hunk or whole buffer) completes --
---i.e. after gitsigns' own callback confirms the git index/working-tree
---write, not merely after the (async) action was requested.
---@param dir string  Repo root the change happened in.
---@return nil
function M.status_changed(dir)
  vim.api.nvim_exec_autocmds("User", { pattern = "GitsuiteStatusChanged", data = { dir = dir } })
end

return M
