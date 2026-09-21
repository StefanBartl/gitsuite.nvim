-- TESTS/gitsuite/status_spec.lua -- gitsuite.features.status against this
-- repo's own real git state, no fixture needed.
describe("gitsuite.features.status", function()
  local status

  before_each(function()
    package.loaded["gitsuite.features.status"] = nil
    status = require("gitsuite.features.status")
  end)

  it("repo() does not error inside a real git repository", function()
    local ok = pcall(status.repo)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("quickfix() does not error and does not raise on a clean tree", function()
    local ok = pcall(status.quickfix)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("quickfix() populates the quickfix list when there is an untracked file", function()
    local scratch = vim.fn.getcwd() .. "/__gitsuite_status_spec_scratch.md"
    vim.fn.writefile({ "scratch" }, scratch)

    status.quickfix()
    local qf = vim.fn.getqflist({ title = 0, items = 0 })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("gitsuite: status", qf.title)

    local found = false
    for _, item in ipairs(qf.items) do
      local name = vim.fn.bufname(item.bufnr)
      if name:match("__gitsuite_status_spec_scratch%.md$") then found = true end
    end
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(found, "the untracked scratch file shows up in the quickfix export")

    vim.fn.delete(scratch)
    vim.cmd("cclose")
  end)
end)
