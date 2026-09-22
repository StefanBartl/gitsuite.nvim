-- TESTS/gitsuite/adapter_spec.lua -- adapter registry (register/resolve/resolve_first/list).
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
describe("gitsuite.adapter", function()
  local adapter

  before_each(function()
    package.loaded["gitsuite.adapter"] = nil
    adapter = require("gitsuite.adapter")
  end)

  it("resolves a registered, available adapter", function()
    adapter.register({
      name = "fake_available",
      is_available = function()
        return true
      end,
    })
    local a = adapter.resolve("fake_available")
    assert.is_not_nil(a)
    assert.equals("fake_available", a.name)
  end)

  it("returns nil for a registered but unavailable adapter", function()
    adapter.register({
      name = "fake_unavailable",
      is_available = function()
        return false
      end,
    })
    assert.is_nil(adapter.resolve("fake_unavailable"))
  end)

  it("returns nil for an unknown adapter name, no error", function()
    assert.is_nil(adapter.resolve("definitely_not_registered"))
  end)

  it("the native adapter is always resolvable inside a git repo (this repo)", function()
    assert.is_not_nil(adapter.resolve("native"))
  end)

  it("resolve_first picks the first available candidate, in order", function()
    adapter.register({
      name = "fake_a",
      is_available = function()
        return false
      end,
    })
    adapter.register({
      name = "fake_b",
      is_available = function()
        return true
      end,
    })
    local a, name = adapter.resolve_first({ "fake_a", "fake_b" })
    assert.equals("fake_b", name)
    assert.equals("fake_b", a.name)
  end)

  it("resolve_first returns nil, nil when nothing in the list is available", function()
    adapter.register({
      name = "fake_c",
      is_available = function()
        return false
      end,
    })
    local a, name = adapter.resolve_first({ "fake_c" })
    assert.is_nil(a)
    assert.is_nil(name)
  end)

  it("list() only reports adapters that were actually loaded/registered", function()
    adapter.register({
      name = "fake_listed",
      is_available = function()
        return true
      end,
    })
    local names = adapter.list()
    local found = false
    for _, n in ipairs(names) do
      if n == "fake_listed" then found = true end
    end
    assert.is_true(found)
  end)
end)
