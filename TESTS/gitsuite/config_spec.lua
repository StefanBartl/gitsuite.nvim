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
end)
