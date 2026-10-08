---@module 'gitsuite.features.plugins'
--- `:Git plugins` -- the history of the clones a plugin manager installed.
--- So far one action, `log` (the newest commits of one plugin or of any
--- clone). A whole-report over every installed plugin builds on the same
--- parts: `sources` (which clones), `gitlog` (read-only git), `view`.
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
    notify.warn(("plugins log: showing %d commits, not %d"):format(M.MAX_COMMITS, n))
    n = M.MAX_COMMITS
  end
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
  end)
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
  -- `n ~= n` is NaN; `math.huge` fails the integer test.
  if
    opts.n ~= nil
    and (
      type(opts.n) ~= "number"
      or opts.n ~= opts.n
      or opts.n < 1
      or opts.n == math.huge
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

return M
