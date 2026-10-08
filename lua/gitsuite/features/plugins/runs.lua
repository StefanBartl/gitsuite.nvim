---@module 'gitsuite.features.plugins.runs'
--- From a clone's HEAD reflog to "what did the last update change".
---
--- lazy.nvim updates with `git fetch` + `git checkout <commit>` -- never a
--- pull or merge -- so every update is one `checkout` line in `.git/logs/HEAD`.
--- That file is the only persistent record of it: lazy keeps its own
--- `_.updated` in memory only, and the lock file is not tracked.
---
--- Two traps shape the rules:
---   * A fresh install is a `clone` followed, seconds later, by a `checkout` of
---     the pinned or tagged commit. That checkout moves HEAD but is not an
---     update; read naively it looks like a "rollback of 15 commits". A state
---     therefore only counts once it has existed for `dwell_s` seconds.
---   * Several plugins of one `:Lazy sync` finish within seconds of each other;
---     they form one *run*, found by clustering their update times.
---
--- Pure: reflog entries in, plain tables out. Entries stay in FILE order --
--- timestamps can go backwards across a clock change, the file cannot.

local M = {}

---Reflog kinds that are the user's own work in a clone, not an update.
---@type table<string, true>
local LOCAL_WORK = {
  commit = true,
  ["cherry-pick"] = true,
  revert = true,
  am = true,
  rebase = true,
}

---@class GitSuite.Plugins.UpdateAnalysis
---@field state "updated"|"installed"|"none"|"local_work"|"stale"
---@field from? string        Commit before the update (`updated`).
---@field to? string          Commit after it (`updated`, `installed`).
---@field time? integer       When `to` was reached.
---@field kind? string        Reflog kind of the move into `to`.
---@field installed_at? integer  When the clone was made, if the reflog still says.
---@field reflog_head? string    For `stale`: where the reflog ends.

---@class GitSuite.Plugins.RunOpts
---@field dwell_s? integer  A state must have lasted this long to count (default 120).
---@field head? string      The commit HEAD resolves to now; the reflog must end there.
---@field now? integer      The current Unix time; entry times beyond a day after it are clamped to it.

---The last real update recorded in `entries`.
---@param entries GitSuite.Plugins.ReflogEntry[]
---@param opts? GitSuite.Plugins.RunOpts
---@return GitSuite.Plugins.UpdateAnalysis
function M.last_update(entries, opts)
  opts = opts or {}
  local dwell_s = opts.dwell_s or 120

  -- Every entry that changes HEAD, in file order.
  ---@type GitSuite.Plugins.ReflogEntry[]
  local moves = {}
  -- A time later than "now + a day" is a clock gone wrong: it is clamped, so one
  -- such entry cannot become the newest update forever.
  local latest = opts.now and (opts.now + 86400) or nil
  for _, entry in ipairs(entries) do
    if entry.old ~= entry.new then
      if latest and entry.time > latest then
        entry = vim.tbl_extend("force", entry, { time = opts.now })
      end
      moves[#moves + 1] = entry
    end
  end
  if #moves == 0 then return { state = "none" } end

  local final = moves[#moves]
  if opts.head and opts.head ~= final.new then
    return { state = "stale", reflog_head = final.new }
  end

  local installed_at
  for _, entry in ipairs(moves) do
    if entry.kind == "clone" then
      installed_at = entry.time
      break
    end
  end

  -- States in order: the one before the first entry (when the reflog does not
  -- start at a clone, it is a state of unknown age -- assumed long-lived), then
  -- the state each entry reached. A state is stable when the next change came
  -- at least `dwell_s` later; the last state is current, so stable by definition.
  ---@type { sha: string, time: integer?, kind: string?, stable: boolean }[]
  local states = {}
  if not require("gitsuite.features.plugins.gitfs").is_zero(moves[1].old) then
    states[1] = { sha = moves[1].old, stable = true }
  end
  for i, entry in ipairs(moves) do
    local nxt = moves[i + 1]
    local stable = nxt == nil or (nxt.time - entry.time) >= dwell_s
    states[#states + 1] = { sha = entry.new, time = entry.time, kind = entry.kind, stable = stable }
  end

  ---@type { sha: string, time: integer?, kind: string? }[]
  local stable = {}
  for _, state in ipairs(states) do
    if state.stable then stable[#stable + 1] = state end
  end

  if #stable < 2 then
    return { state = "installed", to = final.new, time = final.time, installed_at = installed_at }
  end

  local to = stable[#stable]
  -- The state before the update is the last long-lived one that was a
  -- DIFFERENT commit: A -> B -> A within the dwell time is no change at all.
  local from
  for i = #stable - 1, 1, -1 do
    if stable[i].sha ~= to.sha then
      from = stable[i]
      break
    end
  end
  if not from then return { state = "none" } end
  if LOCAL_WORK[to.kind or ""] then
    return { state = "local_work", to = to.sha, time = to.time, kind = to.kind }
  end
  return {
    state = "updated",
    from = from.sha,
    to = to.sha,
    time = to.time,
    kind = to.kind,
    installed_at = installed_at,
  }
end

---@class GitSuite.Plugins.Clustered
---@field members integer[]  Indices into the input of the newest run, oldest first.
---@field older integer      How many inputs fall before that run.
---@field first_time integer
---@field last_time integer

---The newest run among `times`: walk back from the latest time while the gap to
---the next-older one stays within `window_s`.
---@param times integer[]  One time per update; unsorted.
---@param window_s? integer  Default 300.
---@return GitSuite.Plugins.Clustered|nil  `nil` when `times` is empty.
function M.latest_run(times, window_s)
  if #times == 0 then return nil end
  window_s = window_s or 300
  local order = {}
  for i = 1, #times do
    order[i] = i
  end
  table.sort(order, function(a, b)
    if times[a] ~= times[b] then return times[a] < times[b] end
    return a < b
  end)

  local start = #order
  while start > 1 and times[order[start]] - times[order[start - 1]] <= window_s do
    start = start - 1
  end
  local members = {}
  for k = start, #order do
    members[#members + 1] = order[k]
  end
  return {
    members = members,
    older = start - 1,
    first_time = times[order[start]],
    last_time = times[order[#order]],
  }
end

---How the commits between two states relate, from a symmetric-difference log
---(`A...B --left-right`): commits only in `B` are `>`, only in `A` are `<`.
---@param ahead integer   Commits only on the `to` side.
---@param behind integer  Commits only on the `from` side.
---@return "forward"|"rollback"|"diverged"|"same"
function M.direction(ahead, behind)
  if ahead > 0 and behind > 0 then return "diverged" end
  if ahead > 0 then return "forward" end
  if behind > 0 then return "rollback" end
  return "same"
end

return M
