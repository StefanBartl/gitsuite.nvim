---@module 'gitsuite.features.status'
--- Repo status / quickfix export -- `lib.nvim.git.status_porcelain`,
--- already written, not duplicated. Native: no adapter needed.

local git = require("lib.nvim.git")
local notify = require("gitsuite.util.notify")

local M = {}

---Show repo status (branch, ahead/behind, dirty) as a notification.
---@return nil
function M.repo()
  if not git.in_git_repo() then
    notify.error("status: not inside a git repository")
    return
  end

  local branch = git.current_branch()
  local ahead, behind = git.ahead_behind()
  local dirty = git.is_dirty()

  local parts = { branch and ("branch: " .. branch) or "branch: (detached HEAD)" }
  if ahead or behind then
    parts[#parts + 1] = ("ahead=%s behind=%s"):format(tostring(ahead), tostring(behind))
  end
  parts[#parts + 1] = dirty and "dirty" or "clean"

  notify.info(table.concat(parts, "  "))
end

---Export the working tree's changed files (`git status --porcelain -u`) to
---the quickfix list.
---@return nil
function M.quickfix()
  local status = git.status_porcelain()
  if not status then
    notify.info("status: nothing to report (clean working tree, or not a git repo)")
    return
  end

  local qf = {}
  for path, entry in pairs(status) do
    qf[#qf + 1] =
      { filename = path, lnum = 1, col = 1, text = ("[%s] %s"):format(entry.code, path) }
  end
  table.sort(qf, function(a, b)
    return a.filename < b.filename
  end)

  vim.fn.setqflist({}, "r", { title = "gitsuite: status", items = qf })
  vim.cmd("copen")
end

return M
