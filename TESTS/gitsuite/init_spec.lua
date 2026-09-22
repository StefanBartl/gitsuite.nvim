-- TESTS/gitsuite/init_spec.lua -- gitsuite's top-level require("gitsuite")
-- .setup() entry point.
describe("gitsuite", function()
  before_each(function()
    package.loaded["gitsuite"] = nil
    package.loaded["gitsuite.statusline"] = nil
  end)

  it(
    "setup() requires gitsuite.statusline, so a package.loaded-only consumer "
      .. "(ui.statusline.modules.gitsuite_conflict in ui.nvim) can see it without requiring it itself",
    function()
      -- Reproduces the bug directly: before this require, the statusline
      -- module was only ever pulled in by something that already knew to
      -- ask for it by name -- nothing in a normal setup() did, so
      -- package.loaded["gitsuite.statusline"] stayed nil forever and the
      -- ui.nvim adapter (which deliberately checks package.loaded rather
      -- than requiring the module itself, precisely to avoid forcing an
      -- early load) rendered "" no matter what the buffer held.
      ---@diagnostic disable-next-line: undefined-field
      assert.is_nil(package.loaded["gitsuite.statusline"])

      require("gitsuite").setup({})

      ---@diagnostic disable-next-line: undefined-field
      assert.equals("table", type(package.loaded["gitsuite.statusline"]))
    end
  )

  it("setup() is idempotent: a second call does not error or re-require", function()
    require("gitsuite").setup({})
    local statusline_after_first = package.loaded["gitsuite.statusline"]

    local ok = pcall(function()
      require("gitsuite").setup({})
    end)

    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(statusline_after_first, package.loaded["gitsuite.statusline"])
  end)
end)
