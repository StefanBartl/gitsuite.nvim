---@module 'gitsuite.integrations.lazy'
--- The optional `:Lazy sync` hook (`plugins.after_sync`): the one module that
--- listens to lazy.nvim's own `User LazySyncPre` / `User LazySync` events
--- (LUA-05: foreign events only under `integrations/`).
---
--- After a sync it builds the `updated` report (what that sync changed),
--- stores it like `:Git plugins report` does, fires `User
--- GitsuitePluginsReported`, and then either shows a corner toast that never
--- takes focus (`"toast"`) or additionally opens the report (`"open"`). A sync
--- that changed nothing stores and announces nothing; its toast says so. With
--- `"off"` (the default) nothing is registered at all.
---
--- Whether a report belongs to the sync: `User LazySyncPre` records when the
--- sync started, and the report counts as this sync's only when its update run
--- ended at or after that moment (reflog times are checkout times, so a long
--- build step after the checkouts does not matter). When gitsuite was not
--- loaded yet at `LazySyncPre` (lazy-loaded on `User LazySync`), lazy.nvim's
--- own record decides instead: a sync clears `plugin._.updated` of every plugin
--- before it starts, and its checkout sets it for each plugin it moves. The
--- report is this sync's only when one of its entries ends at a commit lazy.nvim
--- moved a plugin to in this sync. Without that record (lazy.nvim's state
--- cannot be read) nothing tells this sync's checkouts from an earlier update
--- that was never reported (a `:Lazy update`, a headless sync), so the report
--- does not count as this sync's.
---
--- (A `plugin/` file cannot record `LazySyncPre` for a lazy-loaded gitsuite:
--- lazy.nvim sources it only when it loads the plugin, i.e. inside
--- `LazySync`.)
---
--- Lazy-loading on `User LazySync`: lazy.nvim loads the plugin from inside that
--- event and then re-fires `User` into the plugin's new augroups WITHOUT a
--- pattern, so a `pattern = "LazySync"` listener created by `setup()` never sees
--- the sync that loaded it. `setup()` therefore notices that it runs inside
--- `User LazySync` (`<amatch>`) and starts the hook itself.
---
--- One sync means one report: repeated events within `DELAY_MS` fold into one
--- build, and a sync that ends while a report is being built waits for that
--- build and runs afterwards (`queue`) instead of being dropped.
---
--- Never in a headless instance: `nvim --headless "+Lazy! sync" +qa` quits
--- before an asynchronous report could finish; a script calls the report
--- itself and waits for it (see docs/integrations.md).

local M = {}

---Debounce between `User LazySync` and the build, in milliseconds.
M.DELAY_MS = 200

---The named augroup every listener of this module lives in (cleared on every
---`setup()`, so a second call does not add a second listener).
M.GROUP = "gitsuite_lazy_sync"

---@type uv.uv_timer_t|nil
local pending

---`os.time()` of the last `User LazySyncPre` not yet consumed by a build.
---@type integer|nil
local started_at

---Whether a UI is attached (`nvim --headless` has none).
---@return boolean
local function has_ui()
  return #vim.api.nvim_list_uis() > 0
end

---How many plugins of the report have breaking hits: at least one commit the
---classifier calls `sure` or `probable` (the `!`/`?` of the report's Breaking
---column; hints and grouped commits do not count). Judged like the report
---view judges it (`report.context()` unless `ctx` is given).
---@param report GitSuite.Plugins.Report
---@param ctx? GitSuite.Plugins.ClassifyContext
---@return integer
function M.breaking_count(report, ctx)
  local ok, n = pcall(function()
    local summary = require("gitsuite.features.plugins.summary")
    ctx = ctx or require("gitsuite.features.plugins.report").context()
    local count = 0
    for _, entry in ipairs(report.plugins or {}) do
      if type(entry.commits) == "table" and #entry.commits > 0 then
        local digest = summary.build(entry, summary.options(ctx, entry.name)).digest
        if #digest.sure + #digest.probable > 0 then count = count + 1 end
      end
    end
    return count
  end)
  -- (a classifier failure must not cost the toast)
  return ok and n or 0
end

---The one-line summary the toast shows.
---@param report GitSuite.Plugins.Report
---@param fresh boolean  Whether the report's update run is the sync that just ended.
---@param ctx? GitSuite.Plugins.ClassifyContext  What the breaking hits are judged against (default `report.context()`).
---@return string
function M.summary(report, fresh, ctx)
  local cmd = require("gitsuite.config").get().commands.git
  local counts = report.counts
  if not fresh then
    return ("plugins: the sync updated nothing (%d checked)"):format(counts.checked)
  end
  local parts = {
    ("%d of %d updated"):format(counts.changed, counts.checked),
    ("%d commit%s"):format(counts.commits, counts.commits == 1 and "" or "s"),
  }
  local breaking = M.breaking_count(report, ctx)
  if breaking > 0 then parts[#parts + 1] = ("%d with breaking"):format(breaking) end
  local errors = #report.errors + (counts.failed or 0)
  if errors > 0 then parts[#parts + 1] = ("%d failed"):format(errors) end
  return ("plugins: %s -> :%s plugins report --last"):format(table.concat(parts, ", "), cmd)
end

---@class GitSuite.LazySync.Baseline
---@field since? integer  `os.time()` when the sync started (`User LazySyncPre`), if seen.
---@field moved? string[] The commits lazy.nvim moved plugins to in this sync (`M.lazy_moved()`), if readable.

---Whether two commit names mean the same commit (a full hash and an
---abbreviation of at least 7 hex digits of it count as the same).
---@param a string
---@param b string
---@return boolean
local function same_commit(a, b)
  a, b = a:lower(), b:lower()
  if a == b then return true end
  if #a > #b then
    a, b = b, a
  end
  return #a >= 7 and b:sub(1, #a) == a
end

---Whether the report's update run is what the sync changed. With `since` (the
---sync's start was seen): the run's newest update happened at or after it.
---Without: one of the report's entries ends at a commit lazy.nvim moved a
---plugin to in this sync (`moved`). Neither known: not this sync's (an older,
---never reported update must not be announced as this sync's).
---@param report GitSuite.Plugins.Report
---@param baseline GitSuite.LazySync.Baseline
---@return boolean
function M.is_fresh(report, baseline)
  local run = report.run
  if not run or report.counts.changed == 0 then return false end
  if baseline.since then return run.last >= baseline.since end
  for _, entry in ipairs(baseline.moved or {}) do
    for _, plugin in ipairs(report.plugins or {}) do
      if type(plugin.to) == "string" and same_commit(plugin.to, entry) then return true end
    end
  end
  return false
end

---The commits lazy.nvim moved plugins to in the sync that just ended, from its
---own record: `plugin._.updated` is cleared for every plugin when a sync
---starts and set by the checkout of each plugin (`from ~= to` when it moved).
---`nil` when lazy.nvim's state cannot be read.
---@return string[]|nil
function M.lazy_moved()
  local ok, moved = pcall(function()
    local plugins = require("lazy.core.config").plugins
    if type(plugins) ~= "table" then return nil end
    local list = {}
    for _, plugin in pairs(plugins) do
      local updated = type(plugin) == "table" and type(plugin._) == "table" and plugin._.updated
      if
        type(updated) == "table"
        and type(updated.to) == "string"
        and updated.to ~= ""
        and updated.from ~= updated.to
      then
        list[#list + 1] = updated.to
      end
    end
    return list
  end)
  return ok and moved or nil
end

---Build, store and announce the `updated` report of the sync that just ended.
---A report that is not this sync's is neither stored nor announced; the toast
---says the sync updated nothing.
---@param mode "toast"|"open"
---@param baseline GitSuite.LazySync.Baseline
---@return nil
function M.run(mode, baseline)
  if not has_ui() then return end
  local fresh = false
  require("gitsuite.features.plugins").report({
    mode = "updated",
    open = false,
    quiet = true,
    queue = true,
    accept = function(report)
      fresh = M.is_fresh(report, baseline)
      return fresh
    end,
    on_done = function(report)
      if not report then return end
      require("lib.nvim.notify").popup.deliver(M.summary(report, fresh), vim.log.levels.INFO, {
        source = "gitsuite",
        title = "[gitsuite] :Lazy sync",
      })
      if mode == "open" and fresh then require("gitsuite.features.plugins").show(report) end
    end,
  })
end

---Called for every `User LazySync`: (re)start the debounce.
---@param mode "toast"|"open"
---@return nil
function M.on_sync(mode)
  if not has_ui() then return end
  if pending then
    pending:stop()
    pending:close()
  end
  ---@type GitSuite.LazySync.Baseline
  local baseline = { since = started_at }
  -- (read now, while lazy.nvim's record is the one of this sync)
  if not baseline.since then baseline.moved = M.lazy_moved() end
  local timer = assert((vim.uv or vim.loop).new_timer())
  pending = timer
  timer:start(
    M.DELAY_MS,
    0,
    vim.schedule_wrap(function()
      if pending ~= timer then return end
      pending = nil
      timer:close()
      started_at = nil
      M.run(mode, baseline)
    end)
  )
end

---Whether this code runs inside a `User LazySync` autocmd -- e.g. lazy.nvim
---loading gitsuite for `event = "User LazySync"`.
---@return boolean
function M.inside_lazy_sync()
  local ok, match = pcall(vim.fn.expand, "<amatch>")
  return ok and match == "LazySync"
end

---Register (or, with `"off"`, remove) the listeners. Idempotent: the named
---group is cleared every time. Called from inside `User LazySync` (gitsuite
---lazy-loaded by it), it also starts the hook for that sync.
---@param cfg GitSuite.Config
---@return nil
function M.setup(cfg)
  local mode = cfg.plugins.after_sync
  if mode ~= "toast" and mode ~= "open" then
    pcall(vim.api.nvim_del_augroup_by_name, M.GROUP)
    -- Off means off: no build of a sync seen before, and a later "toast" does
    -- not take an old `LazySyncPre` for its own sync's start.
    if pending then
      pending:stop()
      pending:close()
      pending = nil
    end
    started_at = nil
    return
  end
  local group = vim.api.nvim_create_augroup(M.GROUP, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LazySyncPre",
    desc = "[gitsuite] Remember when :Lazy sync started (plugins.after_sync)",
    callback = function()
      started_at = os.time()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LazySync",
    desc = "[gitsuite] Report what :Lazy sync changed (plugins.after_sync)",
    callback = function()
      M.on_sync(mode)
    end,
  })
  if M.inside_lazy_sync() then M.on_sync(mode) end
end

---What `:checkhealth` says about the hook.
---@return { mode: string, registered: boolean }
function M.status()
  -- (`nvim_get_autocmds` raises for a group that does not exist)
  local ok, autocmds =
    pcall(vim.api.nvim_get_autocmds, { group = M.GROUP, event = "User", pattern = "LazySync" })
  local registered = ok and #autocmds > 0
  return { mode = require("gitsuite.config").get().plugins.after_sync, registered = registered }
end

return M
