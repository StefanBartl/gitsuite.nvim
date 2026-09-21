-- TESTS/gitsuite/config_spec.lua -- config merge (DEFAULTS + user options).
describe("gitsuite.config", function()
  local config

  before_each(function()
    package.loaded["gitsuite.config"] = nil
    config = require("gitsuite.config")
  end)

  it("returns the defaults when setup() was never called", function()
    local d = config.get()
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("Git", d.commands.git)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(d.features.conflict)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(d.features.ui)
  end)

  it("shallow-overrides one field, keeps untouched siblings", function()
    config.setup({ features = { conflict = false } })
    local c = config.get()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_false(c.features.conflict)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(c.features.hunk)
  end)

  it("drops an unknown top-level key and records it in issues() (ERR-50)", function()
    config.setup({ not_a_real_key = true })
    local issues = config.issues()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(#issues > 0)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(table.concat(issues, "\n"):find("not_a_real_key", 1, true))
  end)

  it("drops an unknown nested key, the real sibling option keeps its default", function()
    config.setup({ features = { conflcit = false } })
    local c = config.get()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(c.features.conflict, "the typo never touched the real option")
  end)

  it("drops a wrongly-typed value, falls back to the default (ERR-22)", function()
    config.setup({ commands = { git = 123 } })
    local c = config.get()
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("Git", c.commands.git)
  end)

  it(
    "deep-copies DEFAULTS on merge (ERR-51): mutating one setup() result never leaks into the next",
    function()
      config.setup({})
      local first = config.get()
      first.features.conflict = false

      config.setup({})
      local second = config.get()
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(
        second.features.conflict,
        "second setup() must not see the first result's mutation"
      )
    end
  )
end)
