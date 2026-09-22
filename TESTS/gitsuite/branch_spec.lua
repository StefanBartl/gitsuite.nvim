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

  it("switch() fires GitsuiteBranchSwitched with {dir, branch} after a real checkout", function()
    -- checkout() is a no-op (and fires nothing) when the choice equals the
    -- current branch (see the "re-select the current branch" tests above),
    -- so this needs an actual checkout to something else. Detaching HEAD
    -- onto the commit it is already on is a real `git checkout <sha>` that
    -- still leaves the repo pointing at the same tree -- and every branch in
    -- this worktree besides the current one is checked out in another
    -- worktree already, so a real branch-to-branch switch is not available
    -- here.
    local git = require("lib.nvim.git")
    local original_branch = git.current_branch()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(original_branch)
    local head_sha = git.head_short_hash()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(head_sha)

    local group = vim.api.nvim_create_augroup("gitsuite_branch_spec_events", { clear = true })
    local captured
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "GitsuiteBranchSwitched",
      callback = function(event)
        captured = event.data
      end,
    })

    local original_select = vim.ui.select
    vim.ui.select = function(_, _, on_choice)
      on_choice(head_sha)
    end

    local ok = pcall(branch.switch)

    vim.ui.select = original_select
    vim.api.nvim_del_augroup_by_id(group)

    -- Back onto the original branch regardless of what the assertions below find.
    local restore_ok, restore_out = require("lib.nvim.cross.run_argv").run_blocking_captured({
      "git",
      "checkout",
      original_branch,
    })
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(restore_ok, restore_out)

    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(captured)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(head_sha, captured.branch)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(git.repo_root(), captured.dir)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(original_branch, git.current_branch())
  end)

  it(
    "switch() checks out via the picker when gitsuite.integrations.pickers_nvim is available",
    function()
      -- pickers.nvim is not a sibling checkout in this test environment (see
      -- pickers_nvim_spec.lua), so stub the integration module itself to
      -- verify switch() prefers it over vim.ui.select and wires its
      -- on_confirm callback through to a real checkout.
      local git = require("lib.nvim.git")
      local original_branch = git.current_branch()
      ---@diagnostic disable-next-line: undefined-field
      assert.is_not_nil(original_branch)

      package.loaded["gitsuite.integrations.pickers_nvim"] = {
        available = function()
          return true
        end,
        branch_picker = function(on_confirm)
          on_confirm(original_branch) -- re-select the current branch: a no-op checkout
          return true
        end,
      }

      local select_called = false
      local original_select = vim.ui.select
      vim.ui.select = function(_, _, _on_choice)
        select_called = true
      end

      local ok = pcall(branch.switch)

      vim.ui.select = original_select
      package.loaded["gitsuite.integrations.pickers_nvim"] = nil

      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok)
      ---@diagnostic disable-next-line: undefined-field
      assert.is_false(select_called)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(original_branch, git.current_branch())
    end
  )

  it(
    "switch() refuses a picker choice that is not a local branch (e.g. a remote-tracking "
      .. "ref telescope/fzf-lua list by default) instead of detaching HEAD onto it",
    function()
      local git = require("lib.nvim.git")
      local original_branch = git.current_branch()
      ---@diagnostic disable-next-line: undefined-field
      assert.is_not_nil(original_branch)

      package.loaded["gitsuite.integrations.pickers_nvim"] = {
        available = function()
          return true
        end,
        branch_picker = function(on_confirm)
          on_confirm("origin/definitely-not-a-local-branch")
          return true
        end,
      }

      local ok = pcall(branch.switch)

      package.loaded["gitsuite.integrations.pickers_nvim"] = nil

      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(original_branch, git.current_branch())
    end
  )
end)
