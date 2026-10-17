---@module 'gitsuite.features.plugins.fetch'
--- `:Git plugins report --mode=pending --fetch`: bring the remote-tracking refs of
--- the plugin clones up to date before the pending report reads them.
---
--- The one place `features/plugins` uses the network, and only on request: the
--- flag is never a default, a run over many clones is confirmed first (see
--- `features.plugins.report`), and each clone gets one `git fetch --all --prune`
--- (`gitlog.fetch`) with no prompt, under `plugins.fetch_timeout_ms`, at most
--- `plugins.fetch_jobs` at a time. A clone that times out, needs credentials or
--- is gone upstream is a line in the result; the others go on.
---
--- Not fetched at all:
---   * anything while lazy.nvim is working on plugins (`busy`): two managers
---     fetching the same clones at once is what makes a Windows machine with a
---     virus scanner freeze;
---   * a clone without its own `.git` directory, and one whose `index.lock` is
---     held (lazy.nvim or another git process is in the middle of it).

local async = require("lib.nvim.async")
local config = require("gitsuite.config")
local gitfs = require("gitsuite.features.plugins.gitfs")
local gitlog = require("gitsuite.features.plugins.gitlog")
local text = require("gitsuite.features.plugins.text")

local M = {}

---A failure reason is kept up to this many bytes (it is git's stderr).
M.MAX_REASON = 300

---@class GitSuite.Plugins.FetchProblem
---@field name string
---@field dir string
---@field reason string

---@class GitSuite.Plugins.FetchRun
---@field at integer        When the fetch started.
---@field clones integer    Clones it was asked to fetch.
---@field fetched integer   Fetches that succeeded.
---@field changed integer   Of those, how many moved a remote-tracking ref.
---@field failed GitSuite.Plugins.FetchProblem[]
---@field skipped GitSuite.Plugins.FetchProblem[]
---@field stopped? boolean  The run was stopped before every clone was fetched.

---@param s any
---@return string
local function reason_text(s)
  local line = text.one_line(s)
  if #line > M.MAX_REASON then line = line:sub(1, M.MAX_REASON) .. "…" end
  return line
end

---Why no fetch may start now, or `nil`: lazy.nvim is working on plugins.
---@return string|nil
function M.busy()
  local ok, lazy = pcall(require, "gitsuite.adapter.lazy")
  if not ok or not lazy.is_available() then return nil end
  local names = lazy.working()
  if #names == 0 then return nil end
  local shown = {}
  for i = 1, math.min(#names, 3) do
    shown[i] = text.one_line(names[i])
  end
  return ("lazy.nvim is working on %d plugin%s (%s%s); fetch again once :Lazy is done"):format(
    #names,
    #names == 1 and "" or "s",
    table.concat(shown, ", "),
    #names > 3 and ", ..." or ""
  )
end

---Why one clone is left out, or `nil`.
---@param ref GitSuite.Plugins.Ref
---@return string|nil
function M.skip_reason(ref)
  if not gitfs.is_clone(ref.dir) then return "it has no .git directory of its own" end
  if gitfs.index_locked(ref.dir) then
    return "its index.lock is held (lazy.nvim or another git process is working in it)"
  end
  return nil
end

---Fetch every clone of `refs` (minus the ones `skip_reason` leaves out).
---Asynchronous; `on_done` is called once, scheduled -- also after `stop()`, with
---`stopped` set and the clones that had not finished listed as failed.
---@param refs GitSuite.Plugins.Ref[]
---@param opts? { on_progress?: fun(done: integer, total: integer) }
---@param on_done fun(run: GitSuite.Plugins.FetchRun)
---@return { stop: fun() } handle
function M.run(refs, opts, on_done)
  opts = opts or {}
  local cfg = config.get().plugins
  ---@type GitSuite.Plugins.FetchRun
  local run =
    { at = os.time(), clones = #refs, fetched = 0, changed = 0, failed = {}, skipped = {} }
  local jobs = {}
  for _, ref in ipairs(refs) do
    local why = M.skip_reason(ref)
    if why then
      run.skipped[#run.skipped + 1] = { name = ref.name, dir = ref.dir, reason = why }
    else
      jobs[#jobs + 1] = ref
    end
  end

  ---@param ref GitSuite.Plugins.Ref
  ---@param done fun(result: any, err: any)
  local function work(ref, _, done)
    return gitlog.fetch(ref.dir, cfg.fetch_timeout_ms, function(ok, err, changed)
      done({ ok = ok, err = err, changed = changed })
    end)
  end

  return async.map_limit(jobs, cfg.fetch_jobs, work, function(results, errors, stopped)
    for i, ref in ipairs(jobs) do
      local r = results[i]
      if r and r.ok then
        run.fetched = run.fetched + 1
        if r.changed then run.changed = run.changed + 1 end
      else
        local why = (r and r.err) or errors[i] or (stopped and "stopped" or "not finished")
        run.failed[#run.failed + 1] = { name = ref.name, dir = ref.dir, reason = reason_text(why) }
      end
    end
    run.stopped = stopped or nil
    on_done(run)
  end, { on_progress = opts.on_progress })
end

return M
