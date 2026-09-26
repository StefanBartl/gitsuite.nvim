---@module 'gitsuite.features.dashboard.actions'
---@brief Single-repository git push/pull/fetch/update for the dashboard.
---@description
--- Thin adapters over `lib.nvim.git`'s write primitives (`push_async`,
--- `pull_async`, `fetch_async`, `update_async`), reshaped from
--- `(opts, on_done, git_cmd)` to `(repo, on_done)` -- the shape
--- `gitsuite.features.dashboard.view`'s row/bulk actions already call,
--- ported unchanged from reposcope.nvim's own `utils.repo_actions`.
---
--- The `changed` flag `lib.nvim.git`'s functions report is dropped here: the
--- dashboard view re-reads a row's status after every action instead of
--- trusting a boolean, so nothing here currently consumes it. Add a second
--- return value if a future caller needs it -- Lua ignores extra returns a
--- caller does not bind.

local git = require("lib.nvim.git")

---@class GitSuiteDashboardActions
local M = {}

---Pushes the current branch of `repo` to its upstream.
---@param repo string Absolute path to the repository
---@param on_done fun(ok: boolean, err: string|nil): nil
---@return nil
function M.push(repo, on_done)
  git.push_async({ dir = repo }, on_done)
end

---Pulls the current branch of `repo` from its upstream (fast-forward only).
---@param repo string Absolute path to the repository
---@param on_done fun(ok: boolean, err: string|nil): nil
---@return nil
function M.pull(repo, on_done)
  git.pull_async({ dir = repo }, on_done)
end

---Fetches `repo`'s remote-tracking refs (does not change the working tree).
---@param repo string Absolute path to the repository
---@param on_done fun(ok: boolean, err: string|nil): nil
---@return nil
function M.fetch(repo, on_done)
  git.fetch_async({ dir = repo }, on_done)
end

---Fetches every remote of `repo` and then fast-forwards the current branch
----- the same pair `:Git dashboard update` runs across a whole page,
---expressed for a single repository so the bulk queue and a lone `gu` keymap
---agree on exactly what "update" means.
---@param repo string Absolute path to the repository
---@param on_done fun(ok: boolean, err: string|nil): nil
---@return nil
function M.update(repo, on_done)
  git.update_async({ dir = repo }, on_done)
end

return M
