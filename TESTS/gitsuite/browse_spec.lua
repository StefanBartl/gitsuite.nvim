-- TESTS/gitsuite/browse_spec.lua -- gitsuite.features.browse (the impure
-- shell) against this repo's own real "origin" remote (github.com), no
-- fixture needed. open.nvim is not a sibling checkout in this test
-- environment, so every case here exercises the resolve()/error path up to
-- (but not through) actually opening a browser -- covered separately by
-- browse_url_spec.lua's pure build()/parse_remote() tests.
describe("gitsuite.features.browse", function()
  local browse
  local bufnr

  before_each(function()
    package.loaded["gitsuite.features.browse"] = nil
    browse = require("gitsuite.features.browse")
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/README.md"))
    bufnr = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("file() does not error on a real tracked file with a real remote", function()
    local ok = pcall(browse.file)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("repo() does not error", function()
    local ok = pcall(browse.repo)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("selection() reports an error, not a crash, without a visual selection", function()
    vim.cmd("normal! mA") -- irrelevant mark, just to ensure we're not accidentally reusing a stray '< from a prior test
    local ok = pcall(browse.selection)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("file() reports an error, not a crash, on an unnamed buffer", function()
    vim.cmd("enew")
    local ok = pcall(browse.file)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
    vim.cmd("bdelete!")
  end)

  it("file() reports an error, not a crash, on an untracked file", function()
    local scratch = vim.fn.getcwd() .. "/__gitsuite_browse_spec_scratch.md"
    vim.fn.writefile({ "scratch" }, scratch)
    vim.cmd("edit " .. vim.fn.fnameescape(scratch))
    local ok = pcall(browse.file)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
    vim.cmd("bdelete!")
    vim.fn.delete(scratch)
  end)
end)
