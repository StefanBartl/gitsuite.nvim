-- TESTS/gitsuite/spec_guard_spec.lua -- spec_guard.lua puts back what a test patched and did not.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("spec_guard", function()
  local G = dofile(dir_of_spec .. "spec_guard.lua")()

  local plain = { kept = "original", untouched = "same" }
  package.loaded["gitsuite_spec_guard_module"] = { field = "original" }
  local module = package.loaded["gitsuite_spec_guard_module"]
  local select_before = vim.ui.select
  local env_before = vim.env.GITSUITE_SPEC_GUARD

  G.install({
    { plain, "kept", "added" },
    { vim.ui, "select" },
    { vim.env, "GITSUITE_SPEC_GUARD" },
    { "gitsuite_spec_guard_module", "field" },
  })

  -- The tests run in order: the first one patches and puts nothing back, the next ones look.
  it("lets a test patch a table, the editor and a module", function()
    plain.kept = "patched"
    plain.added = "new"
    vim.ui.select = function() end
    vim.env.GITSUITE_SPEC_GUARD = "set"
    module.field = "patched"
    assert.equals("patched", plain.kept)
  end)

  it("has put the patched fields back for the next test", function()
    assert.equals("original", plain.kept)
    assert.is_nil(plain.added, "a key that did not exist is removed again")
    assert.equals(select_before, vim.ui.select)
    assert.equals(env_before, vim.env.GITSUITE_SPEC_GUARD)
    assert.equals("original", module.field)
  end)

  it("leaves a field alone that no test named", function()
    plain.untouched = "changed on purpose"
    assert.equals("changed on purpose", plain.untouched)
  end)

  local fresh = { field = "fresh code" }

  it("lets a test reload a module", function()
    package.loaded["gitsuite_spec_guard_module"] = fresh
    assert.equals(fresh, require("gitsuite_spec_guard_module"))
  end)

  it("does not write the old table's value into the reloaded module", function()
    assert.equals("fresh code", fresh.field)
    -- the last test: the stand-in module goes out of the process with it
    package.loaded["gitsuite_spec_guard_module"] = nil
  end)
end)
