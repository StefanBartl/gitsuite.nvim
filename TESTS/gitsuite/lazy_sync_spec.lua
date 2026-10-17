-- TESTS/gitsuite/lazy_sync_spec.lua -- `plugins.after_sync`: the optional `User LazySync`
-- listener (integrations/lazy.lua) and the `open = false` report it builds. The report
-- builder, the toast and the UI check are stubbed: a real `:Lazy sync` cannot run here.
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

describe("gitsuite.integrations.lazy", function()
  local plugins = require("gitsuite.features.plugins")
  local popup = require("lib.nvim.notify").popup
  local saved = {}
  local builds, toasts, shown, uis

  before_each(function()
    builds, toasts, shown, uis = {}, {}, {}, { {} }
    saved.report, saved.show = plugins.report, plugins.show
    saved.deliver, saved.list_uis = popup.deliver, vim.api.nvim_list_uis
    saved.delay = lazy.DELAY_MS
    lazy.DELAY_MS = 20
    plugins.report = function(opts)
      builds[#builds + 1] = opts
      vim.schedule(function()
        opts.on_done(
          fake_report(nil, { first = os.time() - 5, last = os.time() - 1, older = 0, plugins = 5 })
        )
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
    lazy.DELAY_MS = saved.delay
    pcall(vim.api.nvim_del_augroup_by_name, lazy.GROUP)
    config.setup({})
  end)

  local function fire(times)
    for _ = 1, times do
      vim.api.nvim_exec_autocmds("User", { pattern = "LazySync", modeline = false })
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

  it("is idempotent: a second setup() keeps one listener in the named group", function()
    local cfg = config.setup({ plugins = { after_sync = "toast" } })
    lazy.setup(cfg)
    lazy.setup(cfg)
    local autocmds = vim.api.nvim_get_autocmds({ group = lazy.GROUP, event = "User" })
    assert.equals(1, #autocmds)
    assert.equals("LazySync", autocmds[1].pattern)
  end)

  it("'toast' builds exactly once for repeated LazySync events and shows one toast", function()
    lazy.setup(config.setup({ plugins = { after_sync = "toast" } }))
    fire(3)
    settle()
    fire(0)
    assert.equals(1, #builds)
    assert.equals("updated", builds[1].mode)
    assert.is_false(builds[1].open)
    assert.is_true(builds[1].quiet)
    assert.equals(1, #toasts)
    assert.equals(
      "plugins: 5 of 50 updated, 42 commits -> :Git plugins report --last",
      toasts[1].msg
    )
    assert.equals(vim.log.levels.INFO, toasts[1].level)
    assert.equals(0, #shown, "'toast' never opens the report")
  end)

  it("only listens to LazySync, not to the other lazy.nvim events", function()
    lazy.setup(config.setup({ plugins = { after_sync = "toast" } }))
    for _, pattern in ipairs({ "LazyUpdate", "LazyInstall", "LazyClean", "LazySyncPre" }) do
      vim.api.nvim_exec_autocmds("User", { pattern = pattern, modeline = false })
    end
    settle()
    assert.equals(0, #builds)
  end)

  it("'open' also opens the report", function()
    lazy.setup(config.setup({ plugins = { after_sync = "open" } }))
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
    plugins.report = function(opts)
      builds[#builds + 1] = opts
      vim.schedule(function()
        -- the newest run is a day old: this sync changed nothing
        opts.on_done(
          fake_report(
            nil,
            { first = os.time() - 86400, last = os.time() - 86000, older = 0, plugins = 5 }
          )
        )
      end)
    end
    lazy.setup(config.setup({ plugins = { after_sync = "open" } }))
    fire(1)
    settle()
    assert.equals(1, #toasts)
    assert.equals("plugins: the sync updated nothing (50 checked)", toasts[1].msg)
    assert.equals(0, #shown)
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
  local notify = require("gitsuite.util.notify")
  local saved = {}
  local presented, infos

  before_each(function()
    presented, infos = 0, {}
    saved.build, saved.show_markdown, saved.info = builder.build, view.show_markdown, notify.info
    builder.build = function(_, cb)
      vim.schedule(function()
        cb(fake_report(), {})
      end)
      return { stop = function() end }
    end
    view.show_markdown = function()
      presented = presented + 1
    end
    notify.info = function(msg)
      infos[#infos + 1] = msg
    end
    config.setup({})
  end)

  after_each(function()
    builder.build, view.show_markdown, notify.info = saved.build, saved.show_markdown, saved.info
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

  it("stores and announces without showing the report", function()
    local events = 0
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "GitsuitePluginsReported",
      callback = function()
        events = events + 1
      end,
    })
    assert.is_not_nil(run({ open = false }))
    vim.api.nvim_del_autocmd(id)
    assert.equals(0, presented)
    assert.equals(1, events, "the consumer event still fires")
    assert.is_truthy(table.concat(infos, "\n"):find("5 of 50 changed", 1, true))
  end)

  it("quiet suppresses the info messages", function()
    run({ open = false, quiet = true })
    assert.equals(0, presented)
    assert.same({}, infos)
  end)

  it("shows the report by default", function()
    run({})
    assert.equals(1, presented)
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
end)
