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

  -- Without `-z`, git C-quotes a path containing a space or a non-ASCII byte
  -- (`"a b.txt"`, `"\303\274.txt"`), so the quickfix export used to list
  -- entries whose "file" did not exist. Needs a real throwaway repo: the
  -- repo this suite runs in has no such files.
  describe("paths git would otherwise quote", function()
    local original_cwd, repo

    before_each(function()
      original_cwd = vim.fn.getcwd()
      repo = vim.fn.tempname() .. "-gitsuite-status-quoting"
      vim.fn.mkdir(repo, "p")
      local init = vim.system({ "git", "-C", repo, "init", "-q" }):wait()
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(0, init.code, "fixture: git init failed: " .. tostring(init.stderr))
      vim.fn.writefile({ "x" }, repo .. "/a b.txt")
      vim.fn.writefile({ "x" }, repo .. "/ü.txt")
      vim.api.nvim_set_current_dir(repo)
    end)

    after_each(function()
      vim.api.nvim_set_current_dir(original_cwd)
      vim.cmd("cclose")
      pcall(vim.fn.delete, repo, "rf")
    end)

    it("quickfix() lists them under their real, existing paths", function()
      status.quickfix()
      local items = vim.fn.getqflist({ items = 0 }).items

      ---@diagnostic disable-next-line: undefined-field
      assert.equals(2, #items)
      for _, item in ipairs(items) do
        local name = vim.fn.bufname(item.bufnr)
        ---@diagnostic disable-next-line: undefined-field
        assert.equals(
          1,
          vim.fn.filereadable(name),
          ("quickfix entry %q is not a real file"):format(name)
        )
        ---@diagnostic disable-next-line: undefined-field
        assert.is_nil(item.text:find('"', 1, true), "the entry text carries no git quoting")
      end
    end)
  end)
end)
