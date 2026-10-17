---@module 'gitsuite.features.dashboard.pull_scope'
--- What the dashboard's `gP` (pull every repository) offers to pull.
---
--- Pulling a repository that has nothing to fetch is wasted time over forty
--- clones, so `gP` asks whether to pull only the repositories that are behind
--- their upstream, or all of them. "Behind" is only as fresh as the last fetch,
--- so a repository whose behind count cannot be trusted -- no upstream, or no
--- fetch recorded yet -- is neither pulled silently under "only behind" nor
--- dropped silently: it is named in the prompt as skipped.
---
--- Pure: takes the records and a fetch-time lookup, returns the prompt and
--- the index sets each answer stands for. The view owns the dialog.

local gitfs = require("gitsuite.features.plugins.gitfs")

local M = {}

---How many repository names the prompt lists before it shortens to "+N more".
M.MAX_NAMES = 8

---@class DashboardPullPlan
---@field question string Prompt text (may span several lines)
---@field choices string[] Button labels, the configured default first
---@field targets table<string, integer[]> Record indices each choice pulls
---@field behind integer[] Indices of the repositories known to be behind
---@field unknown integer[] Indices whose behind state is unknown
---@field all integer[] Every index

---@private
---@internal
---Names of `records[indices]`, shortened to `M.MAX_NAMES` plus a count.
---@param records RepoDashboardRecord[]
---@param indices integer[]
---@return string
local function names_of(records, indices)
  local names = {}
  for i = 1, math.min(#indices, M.MAX_NAMES) do
    names[i] = records[indices[i]].name
  end
  local text = table.concat(names, ", ")
  if #indices > M.MAX_NAMES then text = ("%s, +%d more"):format(text, #indices - M.MAX_NAMES) end
  return text
end

---Splits `records` into the repositories known to be behind, the ones whose
---behind state is unknown (no upstream, or a zero count with no fetch recorded),
---and all of them.
---@param records RepoDashboardRecord[]
---@param fetch_time? fun(path: string): integer|nil Last fetch of a repository; defaults to `FETCH_HEAD`'s mtime
---@return integer[] behind, integer[] unknown, integer[] all
function M.classify(records, fetch_time)
  fetch_time = fetch_time or gitfs.fetch_time
  local behind, unknown, all = {}, {}, {}
  for i, r in ipairs(records) do
    all[#all + 1] = i
    if not r.has_upstream then
      unknown[#unknown + 1] = i
    elseif (r.behind or 0) > 0 then
      -- A positive count is proof on its own (the tracking ref is past HEAD),
      -- whatever wrote it: a clone, a fetch from another worktree, a `.git`
      -- file `fetch_time` cannot read. Only a zero needs a fetch to be trusted.
      behind[#behind + 1] = i
    elseif fetch_time(r.path) == nil then
      unknown[#unknown + 1] = i
    end
  end
  return behind, unknown, all
end

---Builds `gP`'s prompt.
---@param records RepoDashboardRecord[]
---@param scope? "behind"|"all" Which choice comes first (focused); default "behind"
---@param fetch_time? fun(path: string): integer|nil See `classify`
---@return DashboardPullPlan
function M.plan(records, scope, fetch_time)
  local behind, unknown, all = M.classify(records, fetch_time)

  local behind_label = ("Only behind (%d)"):format(#behind)
  local all_label = ("All (%d)"):format(#all)
  local choices = scope == "all" and { all_label, behind_label } or { behind_label, all_label }

  local lines = {
    ("Pull %d of %d repositor%s behind their upstream, or all of them?"):format(
      #behind,
      #all,
      #all == 1 and "y" or "ies"
    ),
  }
  if #unknown > 0 then
    lines[#lines + 1] = ("Behind state unknown (no upstream or not fetched yet), skipped by 'Only behind': %s"):format(
      names_of(records, unknown)
    )
  end

  return {
    question = table.concat(lines, "\n"),
    choices = choices,
    targets = { [behind_label] = behind, [all_label] = all },
    behind = behind,
    unknown = unknown,
    all = all,
  }
end

return M
