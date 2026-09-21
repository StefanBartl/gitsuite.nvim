-- TESTS/gitsuite/blame_spec.lua -- gitsuite.features.blame against this
-- repo's own tracked README.md (real git history, no fixture needed).
describe("gitsuite.features.blame", function()
  local blame
  local bufnr

  before_each(function()
    package.loaded["gitsuite.features.blame"] = nil
    blame = require("gitsuite.features.blame")
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/README.md"))
    bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("line() does not error on a real tracked file", function()
    local ok = pcall(blame.line)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("line() reports an error, not a crash, on an unnamed buffer", function()
    vim.cmd("enew")
    local ok = pcall(blame.line)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok, "must not raise even without a file")
    vim.cmd("bdelete!")
  end)

  it("toggle() sets a buffer-local flag and an extmark, toggling again clears both", function()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_nil(vim.b[bufnr].gitsuite_blame_active)

    blame.toggle()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(vim.b[bufnr].gitsuite_blame_active)
    local ns = vim.api.nvim_create_namespace("gitsuite_blame")
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(#marks > 0, "toggle() on must place at least one extmark")

    blame.toggle()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_nil(vim.b[bufnr].gitsuite_blame_active)
    marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(0, #marks, "toggle() off must clear its own extmarks")
  end)

  it("full() opens a synced split with one line per source line", function()
    local src_win = vim.api.nvim_get_current_win()
    local expected = #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    blame.full()

    local blame_win = vim.api.nvim_get_current_win()
    ---@diagnostic disable-next-line: undefined-field
    assert.are_not.equal(src_win, blame_win, "full() opens a new window, not the source one")

    local blame_bufnr = vim.api.nvim_win_get_buf(blame_win)
    local lines = vim.api.nvim_buf_get_lines(blame_bufnr, 0, -1, false)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(expected, #lines, "one blame line per source line")

    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(vim.wo[blame_win].scrollbind)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(vim.wo[src_win].scrollbind)

    -- Closing the blame window must clear scrollbind on the source window
    -- again (BufWinLeave cleanup), not leave it stuck bound forever.
    vim.api.nvim_win_close(blame_win, true)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_false(vim.wo[src_win].scrollbind)
  end)
end)
