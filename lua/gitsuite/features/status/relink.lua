---@module 'gitsuite.features.status.relink'
--- `:Git status relink` -- after a git-detected rename, fix Markdown (and
--- Lua/Python/TS/JS) references that still point at the old path.
---
--- filetree.nvim's reference engine already knows "who points at file X" --
--- built for its own smart_rename flow, but its scan step
--- (`filetree.refs.scan`) works just as well against a rename git already
--- made: a provider's `plan()` works from the old path's BASENAME alone (see
--- `filetree.refs.providers.markdown`), never reads the old file itself, so
--- it does not care that the old path no longer exists on disk by the time
--- this command runs.
---
--- filetree.nvim is an optional dependency of THIS feature only (LUA-05):
--- gitsuite.nvim as a whole stays usable without it, only `:Git status
--- relink` degrades to a clear error.
---
--- This writes into files the rename itself never touched, so it never
--- applies silently, whatever filetree.nvim's own ambient `refs.on_rename`
--- is configured to: `mode = "ask"` (`filetree.refs.ui`) always offers
--- Update all / Select… / Show diff / Leave as-is before anything is
--- written.

local git = require("lib.nvim.git")
local notify = require("gitsuite.util.notify")

local M = {}

---@internal
---Renamed (not copied) entries from `status`, as old absolute path -> new
---absolute path. A pure copy ('C' without 'R') is skipped on purpose: the
---old file is still there, so its existing references remain correct and
---retargeting them would be wrong, not just unnecessary.
---@param status Lib.Git.StatusMap
---@param root string
---@return table<string, string> moves
local function renamed_paths(status, root)
  local moves = {}
  for path, entry in pairs(status) do
    if entry.orig_path and (entry.code:sub(1, 1) == "R" or entry.code:sub(2, 2) == "R") then
      moves[vim.fs.joinpath(root, entry.orig_path)] = vim.fs.joinpath(root, path)
    end
  end
  return moves
end

---Scan for references to every rename `git status` currently reports, and
---offer to update them (preview/diff/select, never silent -- see module doc).
---@return nil
function M.relink()
  if not git.in_git_repo() then
    notify.error("status: not inside a git repository")
    return
  end

  local ok_req, refs = pcall(require, "filetree.refs")
  if not ok_req then
    notify.error(
      'status: filetree.nvim is not installed -- install "StefanBartl/filetree.nvim" to use :Git status relink'
    )
    return
  end

  local status = git.status_porcelain()
  if not status then
    notify.info("status: relink: nothing to report (clean working tree, or not a git repo)")
    return
  end

  local root = git.repo_root()
  if not root then
    notify.error("status: relink: could not resolve the repository root")
    return
  end

  local moves = renamed_paths(status, root)
  local old_paths = vim.tbl_keys(moves)
  if #old_paths == 0 then
    notify.info("status: relink: no renamed files in the working tree")
    return
  end
  table.sort(old_paths)

  refs.scan(old_paths, { op = "rename", mode = "ask" }, function(result)
    refs.handle_result(result, moves, { op = "rename", mode = "ask" }, function(applied)
      if applied == 0 then notify.info("status: relink: no references needed updating") end
    end)
  end)
end

return M
