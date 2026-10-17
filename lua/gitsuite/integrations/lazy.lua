---@module 'gitsuite.integrations.lazy'
--- The optional `:Lazy sync` hook (`plugins.after_sync`): the one module that
--- listens to lazy.nvim's own `User LazySync` event (LUA-05: foreign events
--- only under `integrations/`).
---
--- After a sync it builds the `updated` report (what that sync changed),
--- stores it like `:Git plugins report` does, fires `User
--- GitsuitePluginsReported`, and then either shows a corner toast that never
--- takes focus (`"toast"`) or additionally opens the report (`"open"`). With
--- `"off"` (the default) nothing is registered at all.
---
--- Only `LazySync`: lazy.nvim fires it once, after the lock file is written
--- (`LazyUpdate` fires before that, and `:Lazy sync` runs clean/install/update
--- in a row). A short debounce (`DELAY_MS`) still folds repeated events into
--- one build, and the report's own "already running" guard covers a sync that
--- lands while one is being built.
---
--- Never in a headless instance: `nvim --headless "+Lazy! sync" +qa` quits
--- before an asynchronous report could finish; a script calls the report
--- itself and waits for it (see docs/integrations.md).

local M = {}

---Debounce between `User LazySync` and the build, in milliseconds.
M.DELAY_MS = 200

---The augroup every listener of this module lives in (lazy.nvim re-fires an
---event that loaded a plugin into the groups that plugin created, so the group
---must be a named one).
M.GROUP = "gitsuite_lazy_sync"

---@type uv.uv_timer_t|nil
local pending

---Whether a UI is attached (`nvim --headless` has none).
---@return boolean
local function has_ui()
  return #vim.api.nvim_list_uis() > 0
end

---The one-line summary the toast shows.
---@param report GitSuite.Plugins.Report
---@param fresh boolean  Whether the report's update run is the sync that just ended.
---@return string
function M.summary(report, fresh)
  local cmd = require("gitsuite.config").get().commands.git
  local counts = report.counts
  if not fresh then
    return ("plugins: the sync updated nothing (%d checked)"):format(counts.checked)
  end
  local parts = {
    ("%d of %d updated"):format(counts.changed, counts.checked),
    ("%d commit%s"):format(counts.commits, counts.commits == 1 and "" or "s"),
  }
  local errors = #report.errors + (counts.failed or 0)
  if errors > 0 then parts[#parts + 1] = ("%d failed"):format(errors) end
  return ("plugins: %s -> :%s plugins report --last"):format(table.concat(parts, ", "), cmd)
end

---Whether the report's update run belongs to a sync that ended at `synced_at`:
---the newest plugin update of the run lies within `plugins.run_window_s` of it.
---An older run means this sync changed nothing and the report shows the one
---before.
---@param report GitSuite.Plugins.Report
---@param synced_at integer
---@return boolean
function M.is_fresh(report, synced_at)
  local run = report.run
  if not run or report.counts.changed == 0 then return false end
  return run.last >= synced_at - require("gitsuite.config").get().plugins.run_window_s
end

---Build, store and announce the `updated` report of the sync that just ended.
---@param mode "toast"|"open"
---@param synced_at integer  `os.time()` when the sync was seen to end.
---@return nil
function M.run(mode, synced_at)
  if not has_ui() then return end
  require("gitsuite.features.plugins").report({
    mode = "updated",
    open = false,
    quiet = true,
    on_done = function(report)
      if not report then return end
      local fresh = M.is_fresh(report, synced_at)
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
  local synced_at = os.time()
  local timer = assert((vim.uv or vim.loop).new_timer())
  pending = timer
  timer:start(
    M.DELAY_MS,
    0,
    vim.schedule_wrap(function()
      if pending ~= timer then return end
      pending = nil
      timer:close()
      M.run(mode, synced_at)
    end)
  )
end

---Register (or, with `"off"`, remove) the listener. Idempotent: the named
---group is cleared every time.
---@param cfg GitSuite.Config
---@return nil
function M.setup(cfg)
  local mode = cfg.plugins.after_sync
  if mode ~= "toast" and mode ~= "open" then
    pcall(vim.api.nvim_del_augroup_by_name, M.GROUP)
    return
  end
  local group = vim.api.nvim_create_augroup(M.GROUP, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LazySync",
    desc = "[gitsuite] Report what :Lazy sync changed (plugins.after_sync)",
    callback = function()
      M.on_sync(mode)
    end,
  })
end

---What `:checkhealth` says about the hook.
---@return { mode: string, registered: boolean }
function M.status()
  -- (`nvim_get_autocmds` raises for a group that does not exist)
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = M.GROUP, event = "User" })
  local registered = ok and #autocmds > 0
  return { mode = require("gitsuite.config").get().plugins.after_sync, registered = registered }
end

return M
