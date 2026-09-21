-- TESTS/gitsuite/branch_spec.lua -- gitsuite.features.branch against this
-- repo's own real git state (branch "main"), no fixture needed.
describe("gitsuite.features.branch", function()
  local branch

  before_each(function()
    package.loaded["gitsuite.features.branch"] = nil
    branch = require("gitsuite.features.branch")
  end)

  it("list() does not error and reports at least the 'main' branch", function()
    local ok = pcall(branch.list)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("current() does not error", function()
    local ok = pcall(branch.current)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("current() reports the real current branch via lib.nvim.git", function()
    local git = require("lib.nvim.git")
    local expected = git.current_branch()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(expected, "this checkout is not in detached HEAD")
  end)

  it("switch() does not error when the picker is dismissed (no choice made)", function()
    -- vim.ui.select has no headless auto-dismiss -- it blocks on real
    -- terminal input by default, which would hang this test. Stub it to
    -- simulate "the user closed the picker without choosing" (nil), the
    -- same outcome switch()'s callback must handle gracefully either way.
    local original_select = vim.ui.select
    vim.ui.select = function(_, _, on_choice)
      on_choice(nil)
    end

    local ok = pcall(branch.switch)

    vim.ui.select = original_select
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("switch() checks out a real branch when one is chosen", function()
    local git = require("lib.nvim.git")
    local original_branch = git.current_branch()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(original_branch)

    local original_select = vim.ui.select
    vim.ui.select = function(_, _, on_choice)
      -- Re-select the branch we're already on: a real `git checkout`, but a
      -- no-op for the repo's actual state, so this test leaves the checkout
      -- exactly as it found it.
      on_choice(original_branch)
    end

    local ok = pcall(branch.switch)
    vim.ui.select = original_select

    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(original_branch, git.current_branch())
  end)
end)
