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
---@field on_done? fun(report: GitSuite.Plugins.Report|nil, err: string|nil)  Called once (for scripts and tests).

---Show a report as Markdown.
---@param report GitSuite.Plugins.Report
---@param opts GitSuite.Plugins.ReportCmdOpts
local function present(report, opts)
  local lines = require("gitsuite.features.plugins.markdown").render(report)
  view.show_markdown(lines, report.id, opts.out, opts.to)
end

---The report run in flight, if any: a second `:Git plugins report` before the
---first finished would read the same clones and run every git process twice.
---@type { stop: fun() }|nil
local running

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

---Build a report of what changed in the installed plugins -- the last update's
---changes (`mode = "updated"`) or what the next one would bring
---(`"pending"`) -- store it and show it. Reads local state only: no fetch, no
---install, no change to any clone.
---@param opts? GitSuite.Plugins.ReportCmdOpts
---@return { stop: fun() }|nil handle
function M.report(opts)
  opts = opts or {}
  local state = require("gitsuite.features.plugins.state")

  if opts.mode ~= nil and opts.mode ~= "updated" and opts.mode ~= "pending" then
    report_fail(opts, ("unknown mode '%s' (updated or pending)"):format(tostring(opts.mode)))
    return nil
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
    present(newest, opts)
    if opts.on_done then opts.on_done(newest, nil) end
    return nil
  end

  if running then
    notify.warn("plugins report: already running")
    if opts.on_done then opts.on_done(nil, "already running") end
    return running
  end

  notify.info("plugins report: reading the clones ...")
  local handle = require("gitsuite.features.plugins.report").build(
    { mode = opts.mode, all = opts.all },
    function(report, info)
      running = nil
      require("gitsuite.events").plugins_reported({
        id = report.id,
        mode = report.mode,
        at = report.at,
        plugins = report.counts.changed,
        commits = report.counts.commits,
        errors = #report.errors + (report.counts.failed or 0),
        saved = report.save_error == nil,
      })
      if info.recovered then
        notify.warn(
          "plugins report: the report store could not be read; it was moved to "
            .. text.one_line(info.recovered)
        )
      end
      if info.foreign then
        notify.warn(
          ("plugins report: the report store came from another machine (%s); it was kept aside"):format(
            text.one_line(info.foreign)
          )
        )
      end
      if info.dropped then
        notify.warn(
          ("plugins report: %d stored report%s could not be used and %s left out (the old file is kept as .dropped.bak)"):format(
            info.dropped,
            info.dropped == 1 and "" or "s",
            info.dropped == 1 and "was" or "were"
          )
        )
      end
      if report.save_error then
        notify.warn("plugins report: not saved: " .. text.one_line(report.save_error))
      end
      present(report, opts)
      if opts.on_done then opts.on_done(report, nil) end
    end
  )
  -- (the callback is always scheduled, so `running` is set before it can clear it)
  running = {
    stop = function()
      running = nil
      handle.stop()
    end,
  }
  return running
end

return M
