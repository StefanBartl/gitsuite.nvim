---@module 'gitsuite.features.branch'
--- List/switch/show the current branch. Extracted from
--- `ui.nvim/statusline/modules/git_clickable` (see README): only the
--- list/switch logic is reused here, not the click/statusline/context-menu
--- wiring, which stays ui.nvim-specific. Routed through `lib.nvim.git`/
--- `lib.nvim.cross.run_argv` (SEC-01: argv, no shell) instead of the
--- original's `vim.fn.systemlist` -- gitsuite.nvim already treats lib.nvim
--- as a hard dependency, so there is no reason not to.
---
--- Native: no adapter needed, only `git` on `$PATH`.

local git = require("lib.nvim.git")
local notify = require("gitsuite.util.notify")

local M = {}

---@internal
---@return string[]
local function local_branches()
  return git.refs(nil, { branches = true, remotes = false, tags = false })
end

---List local branches.
---@return nil
function M.list()
  local branches = local_branches()
  if #branches == 0 then
    notify.info("branch: no local branches (not a repo, git not on $PATH, or no commits yet)")
    return
  end
  notify.info(table.concat(branches, "\n"))
end

---Show the current branch (or the short commit hash in detached HEAD).
---@return nil
function M.current()
  local name = git.current_branch()
  if name then
    notify.info("branch: " .. name)
    return
  end
  local hash = git.head_short_hash()
  notify.info("branch: detached HEAD" .. (hash and (" @ " .. hash) or ""))
end

---@internal
---@param choice string|nil
---@param current string|nil
local function checkout(choice, current)
  if not choice or choice == current then return end
  local ok, out =
    require("lib.nvim.cross.run_argv").run_blocking_captured({ "git", "checkout", choice })
  if not ok then
    notify.error(("branch: git checkout %s failed: %s"):format(choice, out))
    return
  end
  notify.info("branch: switched to " .. choice)

  local dir = git.repo_root()
  if dir then require("gitsuite.events").branch_switched(dir, choice) end
end

---Switch to another local branch, picked via pickers.nvim's `git_branches`
---picker (preview included) when available, `vim.ui.select` otherwise
---(LUA-05: `gitsuite.integrations.pickers_nvim` is the only module that
---knows pickers.nvim exists).
---@return nil
function M.switch()
  local branches = local_branches()
  if #branches == 0 then
    notify.error("branch: no local branches to switch to")
    return
  end
  local current = git.current_branch()

  local ok_req, pickers_nvim = pcall(require, "gitsuite.integrations.pickers_nvim")
  if ok_req and pickers_nvim.available() then
    local started = pickers_nvim.branch_picker(function(choice)
      checkout(choice, current)
    end)
    if started then return end
  end

  vim.ui.select(branches, {
    prompt = "Switch branch" .. (current and (" (current: " .. current .. ")") or ""),
  }, function(choice)
    checkout(choice, current)
  end)
end

return M
