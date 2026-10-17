-- TESTS/gitsuite/lazy_sync_spec.lua -- `plugins.after_sync`: the optional `User LazySync`
-- listener (integrations/lazy.lua) and the `open = false` report it builds. The report
-- builder, the toast and the UI check are stubbed: a real `:Lazy sync` cannot run here.
-- lazy.nvim's event handler (load the plugin, then re-fire `User` into its new augroups
-- without a pattern) runs for real when a lazy.nvim checkout is found, else as a faithful
-- stub of that re-fire.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.

local lazy = require("gitsuite.integrations.lazy")
local config = require("gitsuite.config")

---@param counts? table
---@param run? table
---@return GitSuite.Plugins.Report
local function fake_report(counts, run)
  return {
    version = 1,
    id = "r1",
    at = os.time(),
    mode = "updated",
    host = "h",
    sources = { "lazy" },
    run = run,
    plugins = {},
    heads = {},
    counts = counts or { checked = 50, changed = 5, commits = 42, unchanged = 45, failed = 0 },
    errors = {},
  }
end

---A run whose newest update happened `ago` seconds ago.
---@param ago integer
---@return table
local function run_ago(ago)
  return { first = os.time() - ago - 4, last = os.time() - ago, older = 0, plugins = 5 }
end

---A lazy.nvim checkout to run the real event handler with, if there is one.
---@return string|nil
local function lazy_nvim_dir()
  local candidates = {
    vim.env.LAZY_NVIM_DIR,
    vim.env.LOCALAPPDATA and (vim.env.LOCALAPPDATA .. "/nvim-data/lazy/lazy.nvim") or nil,
    vim.env.HOME and (vim.env.HOME .. "/.local/share/nvim/lazy/lazy.nvim") or nil,
  }
  for _, dir in pairs(candidates) do
    if
      dir
      and dir ~= ""
      and vim.uv.fs_stat(vim.fs.normalize(dir) .. "/lua/lazy/core/handler/event.lua")
    then
      return vim.fs.normalize(dir)
    end
  end
  return nil
end

describe("gitsuite.integrations.lazy", function()
  local plugins = require("gitsuite.features.plugins")
  local popup = require("lib.nvim.notify").popup
  local saved = {}
  local builds, toasts, shown, uis, accepted
  ---The report the stubbed builder hands back next.
  local next_report

  before_each(function()
    builds, toasts, shown, uis, accepted = {}, {}, {}, { {} }, {}
    next_report = function()
      return fake_report(nil, run_ago(0))
    end
    saved.report, saved.show = plugins.report, plugins.show
    saved.deliver, saved.list_uis = popup.deliver, vim.api.nvim_list_uis
    saved.delay, saved.stored_last = lazy.DELAY_MS, lazy.stored_last
    lazy.DELAY_MS = 20
    lazy.stored_last = function()
      return nil
    end
    plugins.report = function(opts)
      builds[#builds + 1] = opts
      vim.schedule(function()
        local report = next_report()
        -- like the real builder: `accept` decides whether it is stored
        if opts.accept then accepted[#accepted + 1] = opts.accept(report) end
        opts.on_done(report)
      end)
    end
    plugins.show = function(report)
      shown[#shown + 1] = report
    end
    popup.deliver = function(msg, level, opts)
      toasts[#toasts + 1] = { msg = msg, level = level, opts = opts }
    end
    vim.api.nvim_list_uis = function()
      return uis
    end
  end)

  after_each(function()
    plugins.report, plugins.show = saved.report, saved.show
    popup.deliver, vim.api.nvim_list_uis = saved.deliver, saved.list_uis
    lazy.DELAY_MS, lazy.stored_last = saved.delay, saved.stored_last
    pcall(vim.api.nvim_del_augroup_by_name, lazy.GROUP)
    pcall(vim.api.nvim_del_augroup_by_name, "gitsuite_spec_lazy_handler")
    config.setup({})
  end)

  local function fire(times, pattern)
    for _ = 1, times do
      vim.api.nvim_exec_autocmds("User", { pattern = pattern or "LazySync", modeline = false })
    end
  end

  -- Long enough for the debounce and the scheduled on_done, several times over.
  local function settle()
    vim.wait(300, function()
      return false
    end)
  end

  it("'off' registers no listener and does not load the integration from setup", function()
    local cfg = config.setup({})
    assert.equals("off", cfg.plugins.after_sync)
    package.loaded["gitsuite.integrations.lazy"] = nil
    require("gitsuite.bindings").register(cfg)
    assert.is_nil(package.loaded["gitsuite.integrations.lazy"])
    package.loaded["gitsuite.integrations.lazy"] = lazy
    assert.is_false(lazy.status().registered)
    fire(1)
    settle()
    assert.equals(0, #builds)
  end)

  it("'off' after 'toast' removes the listener again", function()
    lazy.setup(config.setup({ plugins = { after_sync = "toast" } }))
    assert.is_true(lazy.status().registered)
    lazy.setup(config.setup({ plugins = { after_sync = "off" } }))
    assert.is_false(lazy.status().registered)
  end)

  it("is idempotent: a second setup() keeps one LazySync listener in the named group", function()
    local cfg = config.setup({ plugins = { after_sync = "toast" } })
    lazy.setup(cfg)
    lazy.setup(cfg)
    local autocmds =
      vim.api.nvim_get_autocmds({ group = lazy.GROUP, event = "User", pattern = "LazySync" })
    assert.equals(1, #autocmds)
    assert.equals("LazySync", autocmds[1].pattern)
  end)

  it("'toast' builds exactly once for repeated LazySync events and shows one toast", function()
    lazy.setup(config.setup({ plugins = { after_sync = "toast" } }))
    fire(1, "LazySyncPre")
    fire(3)
    settle()
    assert.equals(1, #builds)
    assert.equals("updated", builds[1].mode)
    assert.is_false(builds[1].open)
    assert.is_true(builds[1].quiet)
    assert.is_true(builds[1].queue, "a sync during a running report waits for it")
    assert.same({ true }, accepted)
    assert.equals(1, #toasts)
    assert.equals(
      "plugins: 5 of 50 updated, 42 commits -> :Git plugins report --last",
      toasts[1].msg
    )
    assert.equals(vim.log.levels.INFO, toasts[1].level)
    assert.equals(0, #shown, "'toast' never opens the report")
  end)

  it("builds only on LazySync, not on the other lazy.nvim events", function()
    lazy.setup(config.setup({ plugins = { after_sync = "toast" } }))
    for _, pattern in ipairs({ "LazyUpdate", "LazyInstall", "LazyClean", "LazySyncPre" }) do
      fire(1, pattern)
    end
    settle()
    assert.equals(0, #builds)
  end)

  it("'open' also opens the report", function()
    lazy.setup(config.setup({ plugins = { after_sync = "open" } }))
    fire(1, "LazySyncPre")
    fire(1)
    settle()
    assert.equals(1, #builds)
    assert.equals(1, #toasts)
    assert.equals(1, #shown)
  end)

  it("does nothing headless (no UI attached)", function()
    uis = {}
    lazy.setup(config.setup({ plugins = { after_sync = "open" } }))
    fire(2)
    settle()
    assert.equals(0, #builds)
    assert.equals(0, #toasts)
  end)

  it("a sync that updated nothing says so and does not open an older report", function()
    next_report = function()
      -- the newest run is a day old: this sync changed nothing
      return fake_report(nil, run_ago(86000))
    end
    lazy.setup(config.setup({ plugins = { after_sync = "open" } }))
    fire(1, "LazySyncPre")
    fire(1)
    settle()
    assert.same({ false }, accepted, "the report is turned down, so it is not stored")
    assert.equals(1, #toasts)
    assert.equals("plugins: the sync updated nothing (50 checked)", toasts[1].msg)
    assert.equals(0, #shown)
  end)

  it("a no-op sync two minutes after a real one does not repeat the real one", function()
    -- The previous sync updated 5 plugins 120 s ago, well inside run_window_s.
    next_report = function()
      return fake_report(nil, run_ago(120))
    end
    lazy.setup(config.setup({ plugins = { after_sync = "open" } }))
    fire(1, "LazySyncPre")
    fire(1)
    settle()
    assert.same({ false }, accepted)
    assert.equals("plugins: the sync updated nothing (50 checked)", toasts[1].msg)
    assert.equals(0, #shown, "the old report is not opened again")
  end)

  it("a sync whose builds outlast run_window_s is still this sync's", function()
    -- The checkouts happened 600 s ago, at the start of the sync; the builds of the
    -- updated plugins took the rest.
    local real_time = os.time
    local start = real_time() - 600
    os.time = function(t) ---@diagnostic disable-line: duplicate-set-field
      if t then return real_time(t) end
      return start
    end
    local ok, err = pcall(function()
      lazy.setup(config.setup({ plugins = { after_sync = "open", run_window_s = 60 } }))
      fire(1, "LazySyncPre")
    end)
    os.time = real_time
    assert(ok, err)
    next_report = function()
      return fake_report(nil, { first = start, last = start + 2, older = 0, plugins = 5 })
    end
    fire(1)
    settle()
    assert.same({ true }, accepted)
    assert.equals(
      "plugins: 5 of 50 updated, 42 commits -> :Git plugins report --last",
      toasts[1].msg
    )
    assert.equals(1, #shown)
  end)

  it("without LazySyncPre the stored run decides: the same run is no change", function()
    lazy.stored_last = function()
      return os.time() - 30
    end
    next_report = function()
      return fake_report(nil, run_ago(30))
    end
    lazy.setup(config.setup({ plugins = { after_sync = "toast" } }))
    fire(1)
    settle()
    assert.same({ false }, accepted)
    lazy.stored_last = function()
      return os.time() - 3000
    end
    fire(1)
    settle()
    assert.same({ false, true }, accepted, "a newer run than the stored one is this sync's")
  end)

  it("reports the sync that lazy-loads gitsuite (lazy re-fires User without a pattern)", function()
    -- A faithful stub of lazy.nvim's event handler (lazy/core/handler/event.lua): the
    -- plugin is loaded from inside `User LazySync` (its config runs setup()), then
    -- `User` is re-fired into the augroups it created -- with the buffer, no pattern.
    local cfg = config.setup({ plugins = { after_sync = "toast" } })
    local group = vim.api.nvim_create_augroup("gitsuite_spec_lazy_handler", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "LazySync",
      once = true,
      callback = function(ev)
        lazy.setup(cfg)
        vim.api.nvim_exec_autocmds(
          "User",
          { buffer = ev.buf, group = lazy.GROUP, modeline = false, data = ev.data }
        )
      end,
    })
    fire(1)
    settle()
    assert.equals(1, #builds, "the first sync is reported")
    assert.equals(1, #toasts)
    fire(1)
    settle()
    assert.equals(2, #builds, "and the next one through the listener")
  end)

  it("reports the sync that lazy-loads gitsuite, with lazy.nvim's real handler", function()
    local dir = lazy_nvim_dir()
    if not dir then
      pending("no lazy.nvim checkout found (set $LAZY_NVIM_DIR)")
      return
    end
    local saved_path = package.path
    local before = {}
    for name in pairs(package.loaded) do
      before[name] = true
    end
    package.path = dir .. "/lua/?.lua;" .. dir .. "/lua/?/init.lua;" .. package.path
    local ok, err = pcall(function()
      local handler = require("lazy.core.handler.event")
      local cfg = config.setup({ plugins = { after_sync = "toast" } })
      local group = vim.api.nvim_create_augroup("gitsuite_spec_lazy_handler", { clear = true })
      -- The body of the handler's `_add` callback, with `Loader.load` running our setup().
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "LazySync",
        once = true,
        callback = function(ev)
          local state = handler.get_state(ev.event, ev.buf, ev.data)
          lazy.setup(cfg)
          for _, s in ipairs(state) do
            handler.trigger(s)
          end
        end,
      })
      fire(1)
      settle()
    end)
    package.path = saved_path
    for name in pairs(package.loaded) do
      if not before[name] and name:match("^lazy%.") then package.loaded[name] = nil end
    end
    pcall(vim.api.nvim_del_augroup_by_name, "lazy_handler_event")
    assert(ok, err)
    assert.equals(1, #builds, "the first sync is reported")
    assert.equals(1, #toasts)
  end)

  it("setup() outside LazySync starts nothing", function()
    lazy.setup(config.setup({ plugins = { after_sync = "toast" } }))
    settle()
    assert.equals(0, #builds)
  end)

  it("summary names failures and the renamed command", function()
    config.setup({ commands = { git = "G" } })
    local report = fake_report({ checked = 3, changed = 1, commits = 1, unchanged = 2, failed = 1 })
    report.errors = { "x" }
    assert.equals(
      "plugins: 1 of 3 updated, 1 commit, 2 failed -> :G plugins report --last",
      lazy.summary(report, true)
    )
  end)

  it("rejects an unknown after_sync value", function()
    local cfg = config.setup({ plugins = { after_sync = "always" } })
    assert.equals("off", cfg.plugins.after_sync)
    assert.is_truthy(table.concat(config.issues(), "\n"):find("plugins.after_sync", 1, true))
  end)
end)

describe("gitsuite.features.plugins.report({ open = false })", function()
  local plugins = require("gitsuite.features.plugins")
  local builder = require("gitsuite.features.plugins.report")
  local view = require("gitsuite.features.plugins.view")
  local state = require("gitsuite.features.plugins.state")
  local notify = require("gitsuite.util.notify")
  local saved = {}
  local presented, infos, warns, builds
  ---Delay of the stubbed builder, in milliseconds.
  local build_ms

  before_each(function()
    presented, infos, warns, builds, build_ms = {}, {}, {}, 0, 0
    saved.build, saved.show_markdown = builder.build, view.show_markdown
    saved.info, saved.warn, saved.load = notify.info, notify.warn, state.load
    builder.build = function(opts, cb)
      builds = builds + 1
      local stopped = false
      vim.defer_fn(function()
        if stopped then return end
        local report = fake_report()
        -- like the real builder: a report `accept` turns down is not stored
        if opts.accept and not opts.accept(report) then return cb(report, { discarded = true }) end
        cb(report, {})
      end, build_ms)
      return {
        stop = function()
          stopped = true
        end,
      }
    end
    view.show_markdown = function(_, _, out, to)
      presented[#presented + 1] = { out = out, to = to }
    end
    notify.info = function(msg)
      infos[#infos + 1] = msg
    end
    notify.warn = function(msg)
      warns[#warns + 1] = msg
    end
    config.setup({})
  end)

  after_each(function()
    builder.build, view.show_markdown = saved.build, saved.show_markdown
    notify.info, notify.warn, state.load = saved.info, saved.warn, saved.load
  end)

  local function run(opts)
    local done
    opts.on_done = function(report)
      done = report
    end
    plugins.report(opts)
    vim.wait(1000, function()
      return done ~= nil
    end)
    return done
  end

  ---Count `User GitsuitePluginsReported` while `fn` runs.
  local function count_events(fn)
    local events = 0
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "GitsuitePluginsReported",
      callback = function()
        events = events + 1
      end,
    })
    local ok, err = pcall(fn)
    vim.api.nvim_del_autocmd(id)
    assert(ok, err)
    return events
  end

  it("stores and announces without showing the report", function()
    local events = count_events(function()
      assert.is_not_nil(run({ open = false }))
    end)
    assert.equals(0, #presented)
    assert.equals(1, events, "the consumer event still fires")
    assert.is_truthy(table.concat(infos, "\n"):find("5 of 50 changed", 1, true))
  end)

  it("a report accept turns down is neither announced nor shown", function()
    local events = count_events(function()
      assert.is_not_nil(run({
        accept = function()
          return false
        end,
      }))
    end)
    assert.equals(0, events, "no GitsuitePluginsReported with an older run's numbers")
    assert.equals(0, #presented)
  end)

  it("quiet suppresses the info messages", function()
    run({ open = false, quiet = true })
    assert.equals(0, #presented)
    assert.same({}, infos)
  end)

  it("shows the report by default", function()
    run({})
    assert.equals(1, #presented)
  end)

  it("open = false still writes an explicit --out=path / --out=clipboard", function()
    run({ open = false, out = "path", to = "x.md" })
    assert.same({ { out = "path", to = "x.md" } }, presented)
    run({ open = false, out = "clipboard" })
    assert.equals(2, #presented)
    assert.equals("clipboard", presented[2].out)
  end)

  it("--last respects open = false", function()
    state.load = function()
      return { reports = { fake_report() } }, {}
    end
    assert.is_not_nil(run({ last = true, open = false }))
    assert.equals(0, #presented)
    assert.is_truthy(table.concat(infos, "\n"):find("not shown", 1, true))
    run({ last = true, open = false, out = "path", to = "y.md" })
    assert.same({ { out = "path", to = "y.md" } }, presented)
  end)

  it("queue = true waits for a running report instead of being dropped", function()
    build_ms = 80
    local first, second, second_err
    plugins.report({
      quiet = true,
      open = false,
      on_done = function(report)
        first = report
      end,
    })
    plugins.report({
      quiet = true,
      open = false,
      queue = true,
      on_done = function(report, err)
        second, second_err = report, err
      end,
    })
    vim.wait(2000, function()
      return second ~= nil or second_err ~= nil
    end)
    assert.is_not_nil(first)
    assert.is_not_nil(second, "the queued call is built after the running one")
    assert.is_nil(second_err)
    assert.equals(2, builds)
    assert.same({}, warns, "no 'already running' warning")
  end)

  it("without queue a second call still gives up with 'already running'", function()
    build_ms = 80
    plugins.report({ quiet = true, open = false })
    local err
    plugins.report({
      quiet = true,
      open = false,
      on_done = function(_, e)
        err = e
      end,
    })
    assert.equals("already running", err)
    vim.wait(500, function()
      return false
    end)
  end)

  it(":Git plugins report --no-open does not show it", function()
    require("gitsuite").setup({})
    local done
    local saved_report = plugins.report
    plugins.report = function(opts)
      done = opts
    end
    vim.cmd("Git plugins report --no-open")
    plugins.report = saved_report
    assert.is_false(done.open)
  end)

  it(":Git plugins report --to=<file> --no-open writes the file", function()
    require("gitsuite").setup({})
    local done
    vim.cmd("Git plugins report --to=report.md --no-open")
    vim.wait(1000, function()
      done = #presented > 0
      return done
    end)
    assert.same({ { out = "path", to = "report.md" } }, presented)
  end)

  it(":Git plugins report --out=buffer --no-open warns that the buffer is not opened", function()
    require("gitsuite").setup({})
    local saved_report = plugins.report
    plugins.report = function() end
    vim.cmd("Git plugins report --out=buffer --no-open")
    plugins.report = saved_report
    assert.is_truthy(table.concat(warns, "\n"):find("--out=buffer is ignored", 1, true))
  end)
end)
