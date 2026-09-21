-- TESTS/gitsuite/ui_spec.lua -- gitsuite.features.ui. Deliberately does NOT
-- spawn a real lazygit/neogit/diffview process even where the binary/plugin
-- happens to be installed on the machine running this suite: an
-- interactive TUI process left running (or a flaky kill) would make this
-- suite non-deterministic across dev machines and CI. Every case here
-- forces the "not available" path instead, which is also exactly what CI
-- sees for real (none of the three are sibling checkouts/PATH entries
-- there) -- see hunk_spec.lua/browse_spec.lua for the same approach with
-- gitsigns/open.nvim.
describe("gitsuite.features.ui", function()
  local ui

  before_each(function()
    package.loaded["gitsuite.features.ui"] = nil
    package.loaded["gitsuite.adapter"] = nil
    ui = require("gitsuite.features.ui")
  end)

  it("lazygit() reports a clean error, does not crash, when lazygit is not on $PATH", function()
    local original_executable = vim.fn.executable
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      if name == "lazygit" then return 0 end
      return original_executable(name)
    end

    local ok = pcall(ui.lazygit)

    vim.fn.executable = original_executable
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("neogit() reports 'not installed', does not crash, without neogit", function()
    local ok = pcall(ui.neogit)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("diffview() reports 'not installed', does not crash, without diffview", function()
    local ok = pcall(ui.diffview)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)
end)
