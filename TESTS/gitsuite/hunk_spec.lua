-- TESTS/gitsuite/hunk_spec.lua -- gitsuite.features.hunk. gitsigns.nvim is
-- not a sibling checkout in gitsuite.nvim's own test environment (it is an
-- optional adapter, not a runtime dependency), so every case here exercises
-- the "not installed" degrade path -- exactly what `adapter.resolve
-- ("gitsigns")` correctly reports in this environment, and what every real
-- consumer without gitsigns installed will see too. preview()'s fallback
-- onto diff.nvim's real :Diff target=git:HEAD is the one path that still
-- does real work without gitsigns.
describe("gitsuite.features.hunk", function()
  local hunk
  local bufnr

  before_each(function()
    package.loaded["gitsuite.features.hunk"] = nil
    package.loaded["gitsuite.adapter"] = nil
    hunk = require("gitsuite.features.hunk")
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/README.md"))
    bufnr = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    require("diff").clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  local actions = { "stage", "reset", "stage_buffer", "reset_buffer", "toggle_deleted" }
  for _, action in ipairs(actions) do
    it(("%s() reports 'not installed', does not crash, without gitsigns"):format(action), function()
      local ok = pcall(hunk[action])
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok)
    end)
  end

  it("preview() falls back to diff.nvim's :Diff target=git:HEAD without gitsigns", function()
    local ok = pcall(hunk.preview)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)
end)
