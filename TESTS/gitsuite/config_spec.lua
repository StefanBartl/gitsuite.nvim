-- TESTS/gitsuite/config_spec.lua -- config merge (DEFAULTS + user options).
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
describe("gitsuite.config", function()
  local config

  before_each(function()
    package.loaded["gitsuite.config"] = nil
    config = require("gitsuite.config")
  end)

  it("returns the defaults when setup() was never called", function()
    local d = config.get()
    assert.equals("Git", d.commands.git)
    assert.is_true(d.features.conflict)
    assert.is_true(d.features.ui)
  end)

  it("shallow-overrides one field, keeps untouched siblings", function()
    config.setup({ features = { conflict = false } })
    local c = config.get()
    assert.is_false(c.features.conflict)
    assert.is_true(c.features.hunk)
  end)

  it("rejects counts that are not usable numbers and keeps the default", function()
    config.setup({})
    local defaults = vim.deepcopy(config.get().plugins)
    for _, key in ipairs({ "max_commits", "log_limit", "timeout_ms", "parallel", "keep_reports" }) do
      for _, bad in ipairs({ math.huge, 1e300, 2 ^ 63, 0, -5, 2.5, 0 / 0 }) do
        package.loaded["gitsuite.config"] = nil
        config = require("gitsuite.config")
        config.setup({ plugins = { [key] = bad } })
        assert.equals(defaults[key], config.get().plugins[key], key .. " = " .. tostring(bad))
        assert.is_true(#config.issues() > 0, key .. " = " .. tostring(bad))
      end
    end
  end)

  it("drops an unknown top-level key and records it in issues() (ERR-50)", function()
    config.setup({ not_a_real_key = true })
    local issues = config.issues()
    assert.is_true(#issues > 0)
    assert.is_not_nil(table.concat(issues, "\n"):find("not_a_real_key", 1, true))
  end)

  it("drops an unknown nested key, the real sibling option keeps its default", function()
    config.setup({ features = { conflcit = false } })
    local c = config.get()
    assert.is_true(c.features.conflict, "the typo never touched the real option")
  end)

  it("drops a wrongly-typed value, falls back to the default (ERR-22)", function()
    config.setup({ commands = { git = 123 } })
    local c = config.get()
    assert.equals("Git", c.commands.git)
  end)

  it("drops a non-table dashboard.extra_paths instead of reaching ipairs() and raising", function()
    config.setup({ dashboard = { extra_paths = "~/repos/foo" } })
    local c = config.get()
    assert.same({}, c.dashboard.extra_paths, "the default (empty list) applies, not the string")
    local issues = config.issues()
    assert.is_not_nil(table.concat(issues, "\n"):find("dashboard.extra_paths", 1, true))
  end)

  it("drops a non-table dashboard.groups the same way", function()
    config.setup({ dashboard = { groups = "not-a-list" } })
    local c = config.get()
    assert.same({}, c.dashboard.groups)
  end)

  it(
    "drops a dashboard.extra_paths entry that isn't a string, not just a non-table value",
    function()
      config.setup({ dashboard = { extra_paths = { "~/repos/foo", 42 } } })
      local c = config.get()
      assert.same(
        {},
        c.dashboard.extra_paths,
        "the default applies -- a non-string entry would crash inside repos.to_absolute()"
      )
      local issues = config.issues()
      assert.is_not_nil(table.concat(issues, "\n"):find("dashboard.extra_paths", 1, true))
    end
  )

  it("drops a dashboard.groups entry whose paths isn't a list of strings", function()
    config.setup({ dashboard = { groups = { { name = "Work", paths = "~/work" } } } })
    local c = config.get()
    assert.same(
      {},
      c.dashboard.groups,
      "a single un-listed path string would crash inside dashboard_pages.apply()'s ipairs"
    )
  end)

  it("drops a dashboard.groups entry missing a name", function()
    config.setup({ dashboard = { groups = { { paths = { "~/work" } } } } })
    local c = config.get()
    assert.same({}, c.dashboard.groups)
  end)

  it("drops a hash-keyed table masquerading as an empty extra_paths list", function()
    -- Regression: is_list_of_strings()/is_valid_groups() only looped with
    -- ipairs(), which silently skips a non-sequential-integer key -- a
    -- table like { foo = "bar" } iterates zero times, so it looked
    -- identical to a genuinely empty (valid) list and passed straight
    -- through with no warning at all.
    config.setup({ dashboard = { extra_paths = { foo = "bar" } } })
    local c = config.get()
    assert.same({}, c.dashboard.extra_paths, "a hash-keyed table is not a list, empty or not")
    local issues = config.issues()
    assert.is_not_nil(table.concat(issues, "\n"):find("dashboard.extra_paths", 1, true))
  end)

  it("drops a hash-keyed table masquerading as an empty dashboard.groups list", function()
    config.setup({ dashboard = { groups = { foo = "bar" } } })
    local c = config.get()
    assert.same({}, c.dashboard.groups)
  end)

  it(
    "deep-copies DEFAULTS on merge (ERR-51): mutating one setup() result never leaks into the next",
    function()
      config.setup({})
      local first = config.get()
      first.features.conflict = false

      config.setup({})
      local second = config.get()
      assert.is_true(
        second.features.conflict,
        "second setup() must not see the first result's mutation"
      )
    end
  )

  describe("plugins", function()
    it("has defaults: auto sources, no extra roots, 50 commits, a 30 s timeout", function()
      local p = config.get().plugins
      assert.equals("auto", p.sources)
      assert.same({}, p.roots)
      assert.equals(50, p.log_limit)
      assert.equals(30000, p.timeout_ms)
    end)

    it("accepts valid values, including an explicit source list", function()
      config.setup({
        plugins = {
          sources = { "lazy", "clones" },
          roots = { "~/plugins" },
          log_limit = 10,
          timeout_ms = 5000,
        },
      })
      local p = config.get().plugins
      assert.same({ "lazy", "clones" }, p.sources)
      assert.same({ "~/plugins" }, p.roots)
      assert.equals(10, p.log_limit)
      assert.equals(5000, p.timeout_ms)
      assert.same({}, config.issues())
    end)

    it("drops an unknown source name, a non-list roots and non-positive numbers", function()
      config.setup({
        plugins = {
          sources = { "lazy", "packer" },
          roots = "~/plugins",
          log_limit = 0,
          timeout_ms = -5,
        },
      })
      local p = config.get().plugins
      assert.equals("auto", p.sources)
      assert.same({}, p.roots)
      assert.equals(50, p.log_limit)
      assert.equals(30000, p.timeout_ms)
      assert.equals(4, #config.issues())
    end)

    it("drops a fractional count and an empty source list", function()
      config.setup({ plugins = { log_limit = 2.5, sources = {} } })
      assert.equals(50, config.get().plugins.log_limit)
      assert.equals("auto", config.get().plugins.sources)
    end)

    it("has report defaults: third-party only, last update, generous retention", function()
      local p = config.get().plugins
      assert.is_false(p.include_local)
      assert.equals("updated", p.mode)
      assert.equals(1000, p.max_commits)
      assert.equals(4, p.parallel)
      assert.equals(300, p.run_window_s)
      assert.is_false(p.merges)
      assert.equals(20, p.keep_reports)
      assert.equals(365, p.max_age_days)
    end)

    it("accepts valid report options", function()
      config.setup({
        plugins = {
          include_local = true,
          mode = "pending",
          max_commits = 50,
          parallel = 2,
          run_window_s = 60,
          merges = true,
          keep_reports = 3,
          max_age_days = 30,
        },
      })
      local p = config.get().plugins
      assert.is_true(p.include_local)
      assert.equals("pending", p.mode)
      assert.equals(50, p.max_commits)
      assert.equals(2, p.parallel)
      assert.equals(60, p.run_window_s)
      assert.is_true(p.merges)
      assert.equals(3, p.keep_reports)
      assert.equals(30, p.max_age_days)
      assert.same({}, config.issues())
    end)

    it("drops a wrong report option and keeps the default under it", function()
      config.setup({
        plugins = {
          include_local = "yes",
          mode = "all",
          max_commits = 0,
          parallel = 1.5,
          run_window_s = "300",
          merges = 1,
          keep_reports = -1,
          max_age_days = false,
        },
      })
      local p = config.get().plugins
      assert.is_false(p.include_local)
      assert.equals("updated", p.mode)
      assert.equals(1000, p.max_commits)
      assert.equals(4, p.parallel)
      assert.equals(300, p.run_window_s)
      assert.is_false(p.merges)
      assert.equals(20, p.keep_reports)
      assert.equals(365, p.max_age_days)
      assert.equals(8, #config.issues())
    end)

    it("reports an unknown key inside plugins", function()
      config.setup({ plugins = { sourcez = "auto" } })
      assert.is_truthy(config.issues()[1]:find("plugins.sourcez", 1, true))
    end)
  end)
end)
