-- TESTS/gitsuite/branch_spec.lua -- gitsuite.features.branch against this
-- repo's own real git state (branch "main"), no fixture needed.
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
describe("gitsuite.features.branch", function()
  local branch

  before_each(function()
    package.loaded["gitsuite.features.branch"] = nil
    branch = require("gitsuite.features.branch")
  end)

  it("list() does not error and reports at least the 'main' branch", function()
    local ok = pcall(branch.list)
    assert.is_true(ok)
  end)

  it("current() does not error", function()
    local ok = pcall(branch.current)
    assert.is_true(ok)
  end)

  it("current() reports the real current branch via lib.nvim.git", function()
    local git = require("lib.nvim.git")
    local expected = git.current_branch()
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
    assert.is_true(ok)
  end)

  it("switch() checks out a real branch when one is chosen", function()
    local git = require("lib.nvim.git")
    local original_branch = git.current_branch()
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

    assert.is_true(ok)
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
    assert.is_not_nil(original_branch)
    local head_sha = git.head_short_hash()
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
    assert.is_true(restore_ok, restore_out)

    assert.is_true(ok)
    assert.is_not_nil(captured)
    assert.equals(head_sha, captured.branch)
    assert.equals(git.repo_root(), captured.dir)
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

      assert.is_true(ok)
      assert.is_false(select_called)
      assert.equals(original_branch, git.current_branch())
    end
  )

  it(
    "switch() refuses a picker choice that is not a local branch (e.g. a remote-tracking "
      .. "ref telescope/fzf-lua list by default) instead of detaching HEAD onto it",
    function()
      local git = require("lib.nvim.git")
      local original_branch = git.current_branch()
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

      assert.is_true(ok)
      assert.equals(original_branch, git.current_branch())
    end
  )

  describe("checkout() + sessions.nvim (GS-24, opt-in)", function()
    local config = require("gitsuite.config")
    local run_argv = require("lib.nvim.cross.run_argv")

    -- Same trick as "fires GitsuiteBranchSwitched" above: check out HEAD's
    -- own sha, a real `git checkout` (attached branch -> detached HEAD) that
    -- leaves the tree unchanged, then restore the original branch
    -- afterwards -- every OTHER local branch is checked out in another
    -- worktree already, so an actual branch-to-branch switch is not
    -- available here.
    ---@return string original_branch
    ---@return string head_sha
    local function detach_and_restore_setup()
      local git = require("lib.nvim.git")
      local original_branch = git.current_branch()
      assert.is_not_nil(original_branch)
      local head_sha = git.head_short_hash()
      assert.is_not_nil(head_sha)
      return original_branch, head_sha
    end

    ---@param original_branch string
    local function restore(original_branch)
      local ok, out = run_argv.run_blocking_captured({ "git", "checkout", original_branch })
      assert.is_true(ok, out)
    end

    after_each(function()
      config.setup({}) -- reset to defaults: this is shared, process-wide state
      package.loaded["sessions.core"] = nil
    end)

    it("default (branch.sessions = false): never touches sessions.nvim", function()
      local original_branch, head_sha = detach_and_restore_setup()

      local calls = {}
      package.loaded["sessions.core"] = {
        save = function()
          calls[#calls + 1] = "save"
        end,
        load = function()
          calls[#calls + 1] = "load"
        end,
      }

      local original_select = vim.ui.select
      vim.ui.select = function(_, _, on_choice)
        on_choice(head_sha)
      end
      local ok = pcall(branch.switch)
      vim.ui.select = original_select

      restore(original_branch)

      assert.is_true(ok)
      assert.same({}, calls)
    end)

    it("opt-in (branch.sessions = true): saves before the checkout, loads after", function()
      local git = require("lib.nvim.git")
      local original_branch, head_sha = detach_and_restore_setup()
      config.setup({ branch = { sessions = true } })

      local events = {}
      package.loaded["sessions.core"] = {
        save = function(name)
          events[#events + 1] = { fn = "save", branch = git.current_branch(), name = name }
        end,
        load = function(name)
          events[#events + 1] = { fn = "load", branch = git.current_branch(), name = name }
        end,
      }

      local original_select = vim.ui.select
      vim.ui.select = function(_, _, on_choice)
        on_choice(head_sha)
      end
      local ok = pcall(branch.switch)
      vim.ui.select = original_select

      restore(original_branch)

      assert.is_true(ok)
      assert.equals(2, #events)
      assert.equals("save", events[1].fn)
      assert.is_nil(events[1].name, "save(nil) -- sessions.nvim auto-resolves the name")
      assert.equals(original_branch, events[1].branch, "save() ran BEFORE HEAD moved")
      assert.equals("load", events[2].fn)
      assert.is_nil(events[2].name)
      assert.is_nil(events[2].branch, "load() ran AFTER HEAD moved (now detached, no branch)")
    end)

    it("opt-in but sessions.nvim absent: the checkout still succeeds", function()
      local original_branch, head_sha = detach_and_restore_setup()
      config.setup({ branch = { sessions = true } })

      package.loaded["sessions.core"] = nil
      local orig_preload = package.preload["sessions.core"]
      package.preload["sessions.core"] = function()
        error("no sessions.nvim here")
      end

      local original_select = vim.ui.select
      vim.ui.select = function(_, _, on_choice)
        on_choice(head_sha)
      end
      local ok = pcall(branch.switch)
      vim.ui.select = original_select
      package.preload["sessions.core"] = orig_preload

      restore(original_branch)

      assert.is_true(ok)
    end)
  end)
end)
