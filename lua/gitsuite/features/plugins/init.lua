---@module 'gitsuite.features.plugins'
--- `:Git plugins` -- the history of the clones a plugin manager installed.
--- Two actions: `log` (the newest commits of one plugin or of any clone) and
--- `report` (what the last update changed, or what the next one would bring,
--- for every installed plugin). Both are built from the same parts: `sources`
--- (which clones), `gitfs` (process-free `.git` reader), `gitlog` (read-only
--- git), `view`.
---
--- Strictly reading: nothing here installs, updates, pins or cleans anything,
--- and no process started from this feature fetches (see `gitlog`).

local config = require("gitsuite.config")
local notify = require("gitsuite.util.notify")
local text = require("gitsuite.features.plugins.text")
local sources = require("gitsuite.features.plugins.sources")
local gitlog = require("gitsuite.features.plugins.gitlog")
local view = require("gitsuite.features.plugins.view")

local M = {}

---Most commits one `log` shows. Above this the list is cut (and says so):
---every commit is a parsed record and a picker row.
M.MAX_COMMITS = 5000

---@class GitSuite.Plugins.LogOpts
---@field n? integer                      How many commits (default `plugins.log_limit`, at most `MAX_COMMITS`).
---@field out? "picker"|"buffer"|"clipboard"  Where to show them (default "picker").
---@field on_done? fun(entries: Lib.Git.LogEntry[]|nil, err: string|nil)  Called exactly once, when the commits are read or the call gave up (for scripts and tests).

---Report a failure to the user and to `on_done`.
---@param opts GitSuite.Plugins.LogOpts
---@param message string
local function fail(opts, message)
  notify.error("plugins log: " .. text.one_line(message))
  if opts.on_done then opts.on_done(nil, message) end
end

---Turn whatever the caller handed over into a target.
---@param target GitSuite.Plugins.Target|string|nil
---@return GitSuite.Plugins.Target|nil
---@return string|nil err
local function to_target(target)
  if type(target) == "table" then return target, nil end
  if type(target) == "string" then return sources.resolve(target) end
  return sources.of_buffer(), nil
end

---@param target GitSuite.Plugins.Target
---@param opts GitSuite.Plugins.LogOpts
---@return { stop: fun() }
local function read(target, opts)
  local n = opts.n or config.get().plugins.log_limit
  if n > M.MAX_COMMITS then
    notify.warn(("plugins log: showing %d commits, not %s"):format(M.MAX_COMMITS, n))
    n = M.MAX_COMMITS
  end
  -- Changed-file lists are only shown in the picker's preview; the buffer and
  -- clipboard listings never print them, so do not ask git for them there.
  local with_files = (opts.out or "picker") == "picker"
  return gitlog.log(target.dir, n, function(entries, err)
    if not entries then
      fail(opts, ("%s: %s"):format(target.name, err or "git failed"))
      return
    end
    if opts.on_done then opts.on_done(entries, nil) end
    if #entries == 0 then
      notify.info(("plugins log: %s has no commits"):format(text.one_line(target.name)))
      return
    end
    view.show(target, entries, opts.out)
  end, with_files)
end

---Show the newest commits of one plugin or clone.
---
---`target` is a resolved target, a plugin name / `owner/repo` / path, or `nil`:
---then the installed plugin the current buffer belongs to, else a choice among
---the installed plugins.
---@param target? GitSuite.Plugins.Target|string
---@param opts? GitSuite.Plugins.LogOpts
---@return { stop: fun() }|nil handle
function M.log(target, opts)
  opts = opts or {}
  -- `n ~= n` is NaN; above 2^31 (and so `math.huge`) is not a count git takes.
  if
    opts.n ~= nil
    and (
      type(opts.n) ~= "number"
      or opts.n ~= opts.n
      or opts.n < 1
      or opts.n > 2147483647
      or opts.n ~= math.floor(opts.n)
    )
  then
    fail(opts, "the count must be a positive integer")
    return nil
  end

  local resolved, err = to_target(target)
  if err then
    fail(opts, err)
    return nil
  end
  if resolved then return read(resolved, opts) end

  -- No target and the buffer belongs to no plugin: ask.
  local refs, _, errors = sources.list()
  if #refs == 0 then
    fail(
      opts,
      "no installed plugins found"
        .. (#errors > 0 and (" (" .. table.concat(errors, "; ") .. ")") or "")
    )
    return nil
  end
  local names = vim.tbl_map(function(ref)
    return ref.name
  end, refs)
  vim.ui.select(names, { prompt = "Plugin:" }, function(choice)
    if not choice then
      if opts.on_done then opts.on_done(nil, "cancelled") end
      return
    end
    local chosen, choose_err = sources.resolve(choice)
    if not chosen then
      fail(opts, choose_err or "unknown plugin")
      return
    end
    read(chosen, opts)
  end)
  return nil
end

---@class GitSuite.Plugins.ReportCmdOpts
---@field mode? "updated"|"pending"           What to compare (default `plugins.mode`).
---@field all? boolean                        Take `dir`-mode plugins too.
---@field last? boolean                       Show the newest stored report instead of building one.
---@field out? "buffer"|"clipboard"|"path"    Where to put the Markdown (default "buffer").
---@field to? string                          The file for `out = "path"`.
---@field open? boolean                      false = do not open a buffer (default true). An explicit `out = "clipboard"|"path"` is still honoured: copying or writing a file is not opening.
---@field quiet? boolean                      No info messages ("reading the clones", the `open = false` summary); warnings and errors still show.
---@field accept? fun(report: GitSuite.Plugins.Report): boolean  Called with the built report before it is stored: false = neither store, announce nor show it (`on_done` still gets it). For the `:Lazy sync` hook: a sync that changed nothing.
---@field queue? boolean                      While another report is being built, run after it instead of giving up with "already running".
---@field fetch? boolean                      `pending` only: `git fetch` every clone first (network; never a default). From `plugins.fetch_confirm` clones on it asks first.
---@field yes? boolean                        With `fetch`: do not ask.
---@field on_done? fun(report: GitSuite.Plugins.Report|nil, err: string|nil)  Called once (for scripts and tests).

---Show a report as Markdown.
---@param report GitSuite.Plugins.Report
---@param opts GitSuite.Plugins.ReportCmdOpts
local function present(report, opts)
  local ok, ctx = pcall(require("gitsuite.features.plugins.report").context)
  ctx = ok and ctx or nil
  local markdown = require("gitsuite.features.plugins.markdown")
  local lines = markdown.render(report, nil, ctx)
  view.show_markdown(lines, report.id, opts.out, opts.to)

  -- The report buffer is the current one now: with a `plugins.summarize` hook
  -- it gets the key that asks for the AI summary of the plugin under the cursor.
  if (opts.out or "buffer") == "buffer" then
    local buf = vim.api.nvim_get_current_buf()
    require("gitsuite.features.plugins.ai_summary").attach(buf, report, function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local cursor = vim.api.nvim_buf_call(buf, function()
        return vim.api.nvim_win_get_cursor(0)
      end)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, markdown.render(report, nil, ctx))
      vim.bo[buf].modifiable = false
      pcall(vim.api.nvim_win_set_cursor, 0, cursor)
    end, ctx, opts.store_path)
  end
end

---Whether `present` runs: `open = false` only suppresses the buffer, an
---explicit clipboard or file output still happens.
---@param opts GitSuite.Plugins.ReportCmdOpts
---@return boolean
local function presents(opts)
  return opts.open ~= false or opts.out == "clipboard" or opts.out == "path"
end

---Show a report that was already built (e.g. by the `:Lazy sync` hook).
---@param report GitSuite.Plugins.Report
---@param opts? { out?: "buffer"|"clipboard"|"path", to?: string }
---@return nil
function M.show(report, opts)
  present(report, opts or {})
end

---The report run in flight, if any: a second `:Git plugins report` before the
---first finished would read the same clones and run every git process twice.
---@type { stop: fun() }|nil
local running

---A `queue = true` call that arrived while `running`: started once that run
---ends (only the newest waits; an older one is told it was superseded).
---@type GitSuite.Plugins.ReportCmdOpts|nil
local queued

---Tell the user (and `on_done`) that the call gave up.
---@param opts GitSuite.Plugins.ReportCmdOpts
---@param message string
local function report_fail(opts, message)
  notify.error("plugins report: " .. text.one_line(message))
  if opts.on_done then opts.on_done(nil, message) end
end

---What `--last` has to say when there is nothing to show.
---@param store GitSuite.Plugins.Store
---@param info GitSuite.Plugins.StoreInfo
---@param mode? string
---@return string
local function nothing_stored(store, info, mode)
  if info.recovered then
    return ("the report store cannot be read (%s); the next `:Git plugins report` moves it aside"):format(
      info.recovered
    )
  end
  if info.foreign then
    return ("the report store was written on another machine (%s); `:Git plugins report` starts this machine's own"):format(
      info.foreign
    )
  end
  if info.readonly then return info.readonly end
  if mode and #store.reports > 0 then
    return ("no stored '%s' report (the newest is a '%s' one)"):format(mode, store.reports[1].mode)
  end
  return "no stored report yet"
end

local build, fetch_then_build

---Tell what reading the report store did or found. `stored`: whether the
---report was written (`add` then also set a foreign store aside and kept a
---copy of one with unusable reports); a discarded report left the file as it
---was, except for an unreadable one, which the read itself moved aside.
---@param info GitSuite.Plugins.StoreInfo
---@param stored boolean
---@return nil
local function warn_store(info, stored)
  if info.recovered then
    notify.warn(
      "plugins report: the report store could not be read; it was moved to "
        .. text.one_line(info.recovered)
    )
  end
  if info.foreign then
    notify.warn(
      (
        stored
          and "plugins report: the report store came from another machine (%s); it was kept aside"
        or "plugins report: the report store came from another machine (%s); it is not used (the next stored report keeps it aside)"
      ):format(text.one_line(info.foreign))
    )
  end
  if info.dropped then
    local n, one = info.dropped, info.dropped == 1
    notify.warn(
      stored
          and ("plugins report: %d stored report%s could not be used and %s left out (the old file is kept as .dropped-<time>.bak)"):format(
            n,
            one and "" or "s",
            one and "was" or "were"
          )
        or ("plugins report: %d stored report%s could not be used (the file is unchanged until the next report is stored)"):format(
          n,
          one and "" or "s"
        )
    )
  end
end

---Build a report of what changed in the installed plugins -- the last update's
---changes (`mode = "updated"`) or what the next one would bring
---(`"pending"`) -- store it and show it. Reads local state only: no install, no
---change to any clone, and no fetch unless `opts.fetch` asks for one (pending
---only; it moves remote-tracking refs, see `features.plugins.fetch`).
---@param opts? GitSuite.Plugins.ReportCmdOpts
---@return { stop: fun() }|nil handle
function M.report(opts)
  opts = opts or {}
  local state = require("gitsuite.features.plugins.state")

  if opts.mode ~= nil and opts.mode ~= "updated" and opts.mode ~= "pending" then
    report_fail(opts, ("unknown mode '%s' (updated or pending)"):format(tostring(opts.mode)))
    return nil
  end

  if opts.fetch then
    if opts.last then
      report_fail(opts, "--fetch builds a new report; it does not go with --last")
      return nil
    end
    if (opts.mode or config.get().plugins.mode) ~= "pending" then
      report_fail(
        opts,
        "--fetch is for --mode=pending (an updated report compares the clones' own states only)"
      )
      return nil
    end
  end

  if opts.last then
    -- A display command does not tidy up: `peek` leaves a broken store where it is.
    local store, info = state.load(nil, { peek = true })
    local newest
    for _, stored in ipairs(store.reports) do
      if opts.mode == nil or stored.mode == opts.mode then
        newest = stored
        break
      end
    end
    if not newest then
      report_fail(opts, nothing_stored(store, info, opts.mode))
      return nil
    end
    if presents(opts) then
      present(newest, opts)
    elseif not opts.quiet then
      notify.info(
        ("plugins report: the newest stored report has %d of %d changed, %d commits (not shown: --no-open)"):format(
          newest.counts.changed,
          newest.counts.checked,
          newest.counts.commits
        )
      )
    end
    if opts.on_done then opts.on_done(newest, nil) end
    return nil
  end

  if running then
    if opts.queue then
      local older = queued
      queued = opts
      if older and older.on_done then older.on_done(nil, "superseded") end
      return running
    end
    notify.warn("plugins report: already running")
    if opts.on_done then opts.on_done(nil, "already running") end
    return running
  end

  if opts.fetch then return fetch_then_build(opts) end
  return build(opts)
end

---Build, store and show a report (the part of `M.report` after its checks).
---@param opts GitSuite.Plugins.ReportCmdOpts
---@param fetched? GitSuite.Plugins.FetchRun  The `--fetch` that ran just before.
---@return { stop: fun() } handle
function build(opts, fetched)
  if not opts.quiet then notify.info("plugins report: reading the clones ...") end
  local handle = require("gitsuite.features.plugins.report").build(
    { mode = opts.mode, all = opts.all, accept = opts.accept, fetched = fetched },
    function(report, info)
      running = nil
      -- (a queued call starts after this one is fully handled)
      local next_opts = queued
      queued = nil
      if next_opts then vim.schedule(function()
        M.report(next_opts)
      end) end
      if info.discarded then
        -- (nothing stored, but the read may have moved a broken store aside)
        warn_store(info, false)
        if opts.on_done then opts.on_done(report, nil) end
        return
      end
      require("gitsuite.events").plugins_reported({
        id = report.id,
        mode = report.mode,
        at = report.at,
        plugins = report.counts.changed,
        commits = report.counts.commits,
        errors = #report.errors + (report.counts.failed or 0),
        saved = report.save_error == nil,
      })
      warn_store(info, true)
      if report.save_error then
        notify.warn("plugins report: not saved: " .. text.one_line(report.save_error))
      end
      if presents(opts) then
        present(report, opts)
      elseif not opts.quiet then
        notify.info(
          ("plugins report: %d of %d changed, %d commits (%s) -- :%s plugins report --last shows it"):format(
            report.counts.changed,
            report.counts.checked,
            report.counts.commits,
            report.save_error and "not saved" or "saved",
            config.get().commands.git
          )
        )
      end
      if opts.on_done then opts.on_done(report, nil) end
    end
  )
  -- (the callback is always scheduled, so `running` is set before it can clear it)
  running = {
    stop = function()
      running = nil
      local dropped = queued
      queued = nil
      handle.stop()
      if dropped and dropped.on_done then dropped.on_done(nil, "stopped") end
    end,
  }
  return running
end

---Ask before a fetch over `n` clones; `go` runs on "yes".
---@param n integer
---@param cfg GitSuite.Config.Plugins
---@param go fun()
---@param cancel fun()
local function confirm_fetch(n, cfg, go, cancel)
  local question = (
    "Fetch %d plugin clones?\n"
    .. "Network: %d at a time, up to %d s each; only remote-tracking refs move."
  ):format(n, cfg.fetch_jobs, math.ceil(cfg.fetch_timeout_ms / 1000))
  local function answer(yes)
    if yes then
      go()
    else
      cancel()
    end
  end
  local ok, kit = pcall(require, "ui.kit")
  if ok and type(kit) == "table" and type(kit.confirm) == "function" then
    kit.confirm({ question = question, on_answer = answer })
    return
  end
  vim.ui.select({ "Yes", "No" }, { prompt = question:gsub("\n", " ") }, function(choice)
    answer(choice == "Yes")
  end)
end

---`--fetch`: fetch every clone the report will look at (asking first from
---`plugins.fetch_confirm` clones on), then build the report with the result.
---The run counts as `running` from the start of the fetch to the end of the
---build; the handle stops whichever part is in progress.
---@param opts GitSuite.Plugins.ReportCmdOpts
---@return { stop: fun() }|nil handle  `nil` when nothing was started (refused, or waiting for the answer).
function fetch_then_build(opts)
  local fetch = require("gitsuite.features.plugins.fetch")
  local cfg = config.get().plugins
  local busy = fetch.busy()
  if busy then
    report_fail(opts, busy)
    return nil
  end
  local refs, _, errors =
    sources.list({ include_local = (opts.all or cfg.include_local) and true or false })
  if #refs == 0 then
    report_fail(
      opts,
      "no installed plugins found"
        .. (#errors > 0 and (" (" .. table.concat(errors, "; ") .. ")") or "")
    )
    return nil
  end

  local function go()
    -- (the question may have been open while another report started)
    if running then
      notify.warn("plugins report: already running")
      if opts.on_done then opts.on_done(nil, "already running") end
      return running
    end
    -- (and lazy.nvim may have started working on plugins while it was open)
    local busy_now = fetch.busy()
    if busy_now then
      report_fail(opts, busy_now)
      return nil
    end
    if not opts.quiet then
      notify.info(
        ("plugins report: fetching %d clones (%d at a time, up to %d s each) ..."):format(
          #refs,
          cfg.fetch_jobs,
          math.ceil(cfg.fetch_timeout_ms / 1000)
        )
      )
    end
    local stopped = false
    local fetching, building
    local handle
    handle = {
      stop = function()
        if stopped then return end
        stopped = true
        if building then
          -- the build has taken over: its own handle stops it (a no-op once it ended)
          if running == building then building.stop() end
          return
        end
        running = nil
        local dropped = queued
        queued = nil
        fetching.stop()
        if dropped and dropped.on_done then dropped.on_done(nil, "stopped") end
        if opts.on_done then opts.on_done(nil, "stopped") end
      end,
    }
    running = handle
    fetching = fetch.run(refs, {}, function(run)
      if stopped then return end
      if #run.failed > 0 then
        notify.warn(
          ("plugins report: %d of %d fetches failed; the report lists them and does not count them as fetched"):format(
            #run.failed,
            run.clones - #run.skipped
          )
        )
      end
      running = nil
      building = build(opts, run)
    end)
    return handle
  end

  if #refs >= cfg.fetch_confirm and not opts.yes then
    confirm_fetch(#refs, cfg, go, function()
      if not opts.quiet then notify.info("plugins report: fetch cancelled") end
      if opts.on_done then opts.on_done(nil, "cancelled") end
    end)
    return nil
  end
  return go()
end

return M
