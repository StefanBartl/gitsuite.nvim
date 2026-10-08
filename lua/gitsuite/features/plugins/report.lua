---@module 'gitsuite.features.plugins.report'
--- Building a report: for every installed plugin, what changed between two
--- states -- and nothing else.
---
--- Two questions, same machinery:
---   * `updated`  what did the last `:Lazy sync` (or any update) change?
---                from = the state before the update, to = now; both from the
---                clone's HEAD reflog (`runs`).
---   * `pending`  what would the next update bring?
---                from = what is installed, to = the commit lazy.nvim would
---                check out (`target`), as of the last fetch.
---
--- The cost is the number of plugins that CHANGED, not the number installed:
--- everything to decide whether one did is read from files (`gitfs`), a
--- plugin that did not change costs no process, and one that did costs one
--- `git log from...to --left-right` (`gitlog.range`), which also tells the
--- direction. A range of two commits never changes, so a range seen in an
--- earlier report is taken from the store instead of asking git again.
---
--- Nothing here writes a clone, fetches or installs; the one thing written is
--- the report itself (`state`).

local async = require("lib.nvim.async")
local config = require("gitsuite.config")
local gitfs = require("gitsuite.features.plugins.gitfs")
local gitlog = require("gitsuite.features.plugins.gitlog")
local runs = require("gitsuite.features.plugins.runs")
local sources = require("gitsuite.features.plugins.sources")
local state = require("gitsuite.features.plugins.state")
local target = require("gitsuite.features.plugins.target")
local text = require("gitsuite.features.plugins.text")

local uv = vim.uv or vim.loop

local M = {}

---A commit message is stored up to this many bytes.
M.MAX_BODY = 2048

---@class GitSuite.Plugins.ReportCommit
---@field sha string
---@field subject string
---@field body string
---@field author string
---@field time? integer  Committer time.
---@field side? "<"|">"  For a symmetric range: which side the commit is on.

---@class GitSuite.Plugins.ReportEntry
---@field name string
---@field dir string
---@field managed_by string
---@field status "forward"|"rollback"|"diverged"|"same"|"new"|"pinned"|"unknown_target"|"from_missing"|"error"|"no_git"
---@field source "reflog"|"snapshot"|"pending"
---@field confidence "exact"|"approx"
---@field head? string        Where the clone stood when the report was made.
---@field from? string
---@field to? string
---@field to_label? string    The tag or branch the target is called.
---@field time? integer       When the update happened (`updated`).
---@field ahead? integer
---@field behind? integer
---@field truncated? boolean
---@field commits? GitSuite.Plugins.ReportCommit[]
---@field reason? string
---@field fetched_at? integer
---@field locked? boolean
---@field merges? boolean     Whether merge commits were kept (part of what a cached entry answers).

---@class GitSuite.Plugins.Report
---@field version integer
---@field id string
---@field at integer
---@field mode "updated"|"pending"
---@field host string
---@field lazy? string
---@field sources string[]
---@field run? { first: integer, last: integer, older: integer, plugins: integer }
---@field plugins GitSuite.Plugins.ReportEntry[]
---@field heads table<string, string>  Where every plugin looked at stood (clone path -> commit), changed or not: the fallback for "from" when a reflog says nothing.
---@field counts { checked: integer, changed: integer, commits: integer, unchanged: integer, failed?: integer }
---@field fetch? { checked: integer, known: integer, oldest?: integer, newest?: integer }  `pending` only: how many clones have a recorded fetch and when (unchanged clones are not listed, but they are what "up to date" is judged against).
---@field errors string[]
---@field save_error? string

---@class GitSuite.Plugins.BuildOpts
---@field mode? "updated"|"pending"
---@field all? boolean                         Take `dir`-mode plugins too.
---@field refs? GitSuite.Plugins.Ref[]         Plugins to look at (default: the configured sources).
---@field now? integer
---@field store_path? string                   Report store (default: below `stdpath("state")`).
---@field persist? boolean                     Write the report to the store (default true).
---@field on_progress? fun(done: integer, total: integer)

---Fill the fields every entry has, from the plugin and what its clone says.
---@param entry table  The fields specific to this entry.
---@param ref GitSuite.Plugins.Ref
---@param head GitSuite.Plugins.Head|nil
---@return GitSuite.Plugins.ReportEntry
local function base_entry(entry, ref, head)
  entry.name = ref.name
  entry.dir = ref.dir
  entry.managed_by = ref.managed_by
  entry.head = head and head.sha or nil
  entry.fetched_at = gitfs.fetch_time(ref.dir)
  entry.locked = gitfs.index_locked(ref.dir) or nil
  return entry
end

---Why a clone's `.git` cannot be used, by what `gitfs.clone_state` found.
local NO_GIT = {
  file = "its .git is a file (a worktree or submodule): its history lives elsewhere",
  link = "its .git is a symbolic link, which is not followed",
  other = "its .git is not a directory",
  none = "it has no .git",
}

---The row for a clone whose state cannot be read: no usable `.git`, or a HEAD
---that does not name a commit.
---@param ref GitSuite.Plugins.Ref
---@param head GitSuite.Plugins.Head|nil
---@param herr string|nil
---@param source "reflog"|"pending"
---@return GitSuite.Plugins.ReportEntry
local function unreadable_row(ref, head, herr, source)
  local clone = gitfs.clone_state(ref.dir)
  if clone ~= "clone" then
    return base_entry({
      status = "no_git",
      source = source,
      confidence = "exact",
      reason = NO_GIT[clone] or NO_GIT.other,
    }, ref, nil)
  end
  return base_entry({
    status = "error",
    source = source,
    confidence = "exact",
    reason = "HEAD could not be read: " .. text.one_line(herr or "no commit"),
  }, ref, head)
end

---Run `fn` for one plugin; an error in it makes that plugin's row, not the
---report's failure (a hostile spec or clone must not take the others with it).
---@param ctx table
---@param ref GitSuite.Plugins.Ref
---@param source "reflog"|"pending"
---@param fn fun()
local function guarded(ctx, ref, source, fn)
  local ok, err = pcall(fn)
  if not ok then
    ctx.rows[#ctx.rows + 1] = base_entry({
      status = "error",
      source = source,
      confidence = "exact",
      reason = "planning failed: " .. text.one_line(err),
    }, ref, nil)
  end
end

---A subject or author line is stored up to this many bytes: a hostile commit
---must not be able to make the stored report unreadably large.
M.MAX_LINE = 500

---@param s string
---@param max integer
---@return string
local function cap(s, max)
  if #s <= max then return s end
  return s:sub(1, max) .. "…"
end

---A commit time that can be stored: a real, finite point in time. A hostile
---commit can carry a 400-digit date, which parses as infinity and which JSON
---cannot encode -- the whole report would then never be saved.
---@param t any
---@return integer|nil
local function finite_time(t)
  if type(t) ~= "number" or t ~= t or t < 0 or t > gitfs.MAX_TIME then return nil end
  return t
end

---@param commit Lib.Git.LogEntry
---@return GitSuite.Plugins.ReportCommit
local function to_commit(commit)
  local body = commit.body or ""
  if #body > M.MAX_BODY then body = body:sub(1, M.MAX_BODY) .. "…" end
  return {
    sha = commit.sha,
    subject = text.utf8(cap(commit.subject or "", M.MAX_LINE)),
    body = text.utf8(body),
    author = text.utf8(cap(commit.author or "", M.MAX_LINE)),
    time = finite_time(commit.commit_time),
    side = (commit.side == "<" or commit.side == ">") and commit.side or nil,
  }
end

---What a finished `from...to` log means for the plugin.
---@param entry GitSuite.Plugins.ReportEntry
---@param entries Lib.Git.LogEntry[]
---@param max integer
local function apply_log(entry, entries, max)
  local ahead, behind = 0, 0
  for _, commit in ipairs(entries) do
    if commit.side == ">" then
      ahead = ahead + 1
    elseif commit.side == "<" then
      behind = behind + 1
    end
  end
  entry.ahead, entry.behind = ahead, behind
  entry.status = runs.direction(ahead, behind)
  entry.truncated = #entries > max or nil
  if entry.truncated then
    -- `max_count` cuts the whole symmetric difference, so a one-sided answer may
    -- hide the other side and the counts are lower bounds.
    entry.reason = "the list was cut at plugins.max_commits; counts are lower bounds"
  end

  local kept = {}
  for _, commit in ipairs(entries) do
    local wanted = entry.status == "diverged"
      or (entry.status == "forward" and commit.side == ">")
      or (entry.status == "rollback" and commit.side == "<")
    if wanted then
      kept[#kept + 1] = to_commit(commit)
      if #kept >= max then break end
    end
  end
  entry.commits = kept
end

---The answers a `from...to` log can give; only these are taken from the store.
---@type table<string, true>
local DIRECTIONS = { forward = true, rollback = true, diverged = true, same = true }

---@class GitSuite.Plugins.Job
---@field entry GitSuite.Plugins.ReportEntry
---@field from string
---@field rev string      What git turns into the target commit.
---@field cache_to? string  The target as a full hash, when known (then the range can be cached).

---Collect the entries and jobs of mode `updated`.
---@param refs GitSuite.Plugins.Ref[]
---@param ctx table
---@return GitSuite.Plugins.ReportEntry[] rows
---@return GitSuite.Plugins.Job[] jobs
---@return table meta
local function plan_updated(refs, ctx)
  local cfg = ctx.cfg
  local cands = {}
  local times = {}
  for _, ref in ipairs(refs) do
    guarded(ctx, ref, "reflog", function()
      local clone = gitfs.is_clone(ref.dir)
      local head, herr
      if clone then
        head, herr = gitfs.head(ref.dir)
      end
      if head and head.sha then ctx.heads[ref.dir] = head.sha end
      if not clone or not head or not head.sha then
        ctx.rows[#ctx.rows + 1] = unreadable_row(ref, head, herr, "reflog")
        return
      end
      local reflog = gitfs.reflog(ref.dir)
      local analysis = reflog and runs.last_update(reflog, { head = head.sha, now = ctx.now })
        or { state = "none" }
      local cand = { ref = ref, head = head, analysis = analysis }
      cands[#cands + 1] = cand
      if analysis.state == "updated" then
        times[#times + 1] = analysis.time
        cand.index = #times
      end
    end)
  end

  local run = runs.latest_run(times, cfg.run_window_s)
  local in_run = {}
  if run then
    for _, member in ipairs(run.members) do
      in_run[member] = true
    end
  end

  local jobs = {}
  for _, cand in ipairs(cands) do
    local a, ref, head = cand.analysis, cand.ref, cand.head
    if a.state == "updated" then
      if cand.index and in_run[cand.index] then
        jobs[#jobs + 1] = {
          entry = base_entry({
            source = "reflog",
            confidence = "exact",
            from = a.from,
            to = a.to,
            time = a.time,
          }, ref, head),
          from = a.from,
          rev = a.to,
          cache_to = a.to,
        }
      end
    elseif a.state == "installed" then
      if
        run
        and a.time >= run.first_time - cfg.run_window_s
        and a.time <= run.last_time + cfg.run_window_s
      then
        ctx.rows[#ctx.rows + 1] = base_entry({
          status = "new",
          source = "reflog",
          confidence = "exact",
          to = a.to,
          time = a.time,
          reason = "installed in this run",
        }, ref, head)
      end
    else
      -- The reflog says nothing usable (expired, never written, ends elsewhere,
      -- only the user's own commits): the state of the last report stands in.
      local snapshot = state.snapshot(ctx.store, ref.dir)
      if snapshot and snapshot ~= head.sha then
        jobs[#jobs + 1] = {
          entry = base_entry({
            source = "snapshot",
            confidence = "approx",
            from = snapshot,
            to = head.sha,
          }, ref, head),
          from = snapshot,
          rev = head.sha,
          cache_to = head.sha,
        }
      end
    end
  end

  local meta = {}
  if run then
    meta.run = {
      first = run.first_time,
      last = run.last_time,
      older = run.older,
      plugins = #run.members,
    }
  end
  return ctx.rows, jobs, meta
end

---Collect the entries and jobs of mode `pending`.
---@param refs GitSuite.Plugins.Ref[]
---@param ctx table
---@return GitSuite.Plugins.ReportEntry[] rows
---@return GitSuite.Plugins.Job[] jobs
---@return table meta
local function plan_pending(refs, ctx)
  local lazy_ok, lazy = pcall(require, "gitsuite.adapter.lazy")
  local defaults_version = lazy_ok and lazy.is_available() and lazy.defaults_version() or nil
  local jobs = {}
  for _, ref in ipairs(refs) do
    guarded(ctx, ref, "pending", function()
      local clone = gitfs.is_clone(ref.dir)
      local head, herr
      if clone then
        head, herr = gitfs.head(ref.dir)
      end
      if head and head.sha then ctx.heads[ref.dir] = head.sha end
      if not clone or not head or not head.sha then
        ctx.rows[#ctx.rows + 1] = unreadable_row(ref, head, herr, "pending")
        return
      end

      local fetched = gitfs.fetch_time(ref.dir)
      local f = ctx.fetch
      f.checked = f.checked + 1
      if fetched then
        f.known = f.known + 1
        f.oldest = f.oldest and math.min(f.oldest, fetched) or fetched
        f.newest = f.newest and math.max(f.newest, fetched) or fetched
      end

      local t =
        target.resolve(ref, { defaults_version = defaults_version, head = head, cloned = true })
      if t.tier == "pin" then
        ctx.rows[#ctx.rows + 1] = base_entry({
          status = "pinned",
          source = "pending",
          confidence = "exact",
          reason = t.reason,
        }, ref, head)
      elseif t.tier == "unknown" then
        ctx.rows[#ctx.rows + 1] = base_entry({
          status = "unknown_target",
          source = "pending",
          confidence = "exact",
          reason = "cannot tell what lazy.nvim would update to: " .. text.one_line(t.reason),
        }, ref, head)
      elseif t.sha and t.sha == head.sha then
        return
      else
        jobs[#jobs + 1] = {
          entry = base_entry({
            source = "pending",
            confidence = "exact",
            from = head.sha,
            to = t.sha,
            to_label = t.label,
          }, ref, head),
          from = head.sha,
          rev = t.rev,
          cache_to = t.certain and t.sha or nil,
        }
      end
    end)
  end
  return ctx.rows, jobs, {}
end

---Build a report. Asynchronous (one git process per changed plugin, `parallel`
---at a time); `on_done` is called once, scheduled.
---@param opts GitSuite.Plugins.BuildOpts
---@param on_done fun(report: GitSuite.Plugins.Report, info: GitSuite.Plugins.StoreInfo)
---@return { stop: fun() } handle
function M.build(opts, on_done)
  local cfg = config.get().plugins
  local mode = opts.mode
  if mode ~= "updated" and mode ~= "pending" then mode = cfg.mode end
  local now = opts.now or os.time()
  local store, store_info = state.load(opts.store_path)

  ---@type GitSuite.Plugins.Ref[], string[], string[]
  local refs, used, errors
  if opts.refs then
    refs, used, errors = opts.refs, { "given" }, {}
  else
    refs, used, errors =
      sources.list({ include_local = (opts.all or cfg.include_local) and true or false })
  end

  local ctx = {
    cfg = cfg,
    store = store,
    rows = {},
    heads = {},
    now = now,
    fetch = { checked = 0, known = 0 },
  }
  local rows, jobs, meta
  if mode == "pending" then
    rows, jobs, meta = plan_pending(refs, ctx)
  else
    rows, jobs, meta = plan_updated(refs, ctx)
  end

  local cache = state.cache_index(store)
  local max = cfg.max_commits
  local stopped = false

  ---@param j GitSuite.Plugins.Job
  ---@param done fun(result: any, err: any)
  local function work(j, _, done)
    local entry = j.entry
    local cached = j.cache_to and cache[state.cache_key(entry.dir, j.from, j.cache_to)]
    -- Only an answer computed under the same settings and not cut short stands
    -- in for the real thing: the range is fixed, what was asked of it is not.
    if
      cached
      and type(cached.commits) == "table"
      and DIRECTIONS[cached.status]
      and cached.merges == cfg.merges
      and not cached.truncated
      and #cached.commits <= max
    then
      entry.status = cached.status
      entry.ahead = type(cached.ahead) == "number" and cached.ahead or nil
      entry.behind = type(cached.behind) == "number" and cached.behind or nil
      entry.commits = cached.commits
      entry.merges = cfg.merges
      return done(entry)
    end
    entry.merges = cfg.merges
    return gitlog.range(
      entry.dir,
      j.from,
      j.rev,
      { max_count = max + 1, no_merges = not cfg.merges },
      function(entries, err)
        if entries then
          apply_log(entry, entries, max)
          return done(entry)
        end
        gitlog.has_commit(entry.dir, j.from, function(has, has_err)
          if has == nil then
            -- git itself could not answer (missing binary, timeout, broken config):
            -- that says nothing about the history, so do not blame a force-push.
            entry.status = "error"
            entry.reason = "git could not be run: " .. text.one_line(has_err or err)
          elseif has then
            entry.status = "error"
            entry.reason = "git could not list the commits: " .. text.one_line(err)
          else
            entry.status = "from_missing"
            entry.reason =
              "the previous state is no longer in the clone (a force-push, or a pruned history)"
          end
          done(entry)
        end)
      end
    )
  end

  local function finish(results, worker_errors)
    if stopped then return end
    local plugins = {}
    for _, row in ipairs(rows) do
      plugins[#plugins + 1] = row
    end
    for i = 1, #jobs do
      plugins[#plugins + 1] = results[i] or jobs[i].entry
      if not results[i] then
        plugins[#plugins].status = "error"
        plugins[#plugins].reason = worker_errors[i] and text.one_line(worker_errors[i])
          or "not finished"
      end
    end
    table.sort(plugins, function(a, b)
      local la, lb = a.name:lower(), b.name:lower()
      if la ~= lb then return la < lb end
      if a.name ~= b.name then return a.name < b.name end
      return a.dir < b.dir
    end)

    local changed, commits, failed = 0, 0, 0
    for _, entry in ipairs(plugins) do
      if entry.status == "forward" or entry.status == "rollback" or entry.status == "diverged" then
        changed = changed + 1
        commits = commits + #(entry.commits or {})
      elseif
        entry.status == "error"
        or entry.status == "from_missing"
        or entry.status == "no_git"
        or entry.status == "unknown_target"
      then
        failed = failed + 1
      end
    end

    local lazy_version
    local lazy_ok, lazy = pcall(require, "gitsuite.adapter.lazy")
    if lazy_ok and lazy.is_available() then lazy_version = lazy.version() end

    ---@type GitSuite.Plugins.Report
    local report = {
      version = state.VERSION,
      id = ("%s-%04x"):format(os.date("!%Y%m%dT%H%M%SZ", now), uv.hrtime() % 0x10000),
      at = now,
      mode = mode,
      host = state.host(),
      lazy = lazy_version,
      sources = used,
      run = meta.run,
      plugins = plugins,
      counts = {
        checked = #refs,
        changed = changed,
        commits = commits,
        unchanged = #refs - #plugins,
        failed = failed,
      },
      fetch = mode == "pending" and ctx.fetch or nil,
      errors = errors,
      heads = ctx.heads,
    }

    local info = store_info
    if opts.persist ~= false and #refs == 0 then
      -- An empty report would become the newest one and push real reports out
      -- of the store.
      report.save_error = "no installed plugins found; nothing was stored"
    elseif opts.persist ~= false then
      local ok, err, add_info = state.add(report, cfg, opts.store_path)
      if not ok then report.save_error = err end
      -- `build` read the store first, and that read may have moved a broken file
      -- aside: the second read inside `add` then finds none. Keep what the
      -- first one learned.
      info = vim.tbl_extend("keep", add_info or {}, store_info)
    end
    on_done(report, info)
  end

  return async.map_limit(jobs, cfg.parallel, work, function(results, worker_errors, was_stopped)
    stopped = was_stopped
    finish(results, worker_errors)
  end, { on_progress = opts.on_progress })
end

return M
