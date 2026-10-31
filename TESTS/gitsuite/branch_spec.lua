-- TESTS/gitsuite/branch_spec.lua -- gitsuite.features.branch against a
-- throwaway repository (branches "main" and "other" on one commit). Never
-- against the live checkout: a checkout there rewrites its HEAD, index and
-- reflog while the suite runs (`testing stamp` then sees an input of the
-- run change and refuses the stamp), and a shared checkout must not move
-- under another session.
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
describe("gitsuite.features.branch", function()
  local G = dofile(dir_of_spec .. "spec_guard.lua")()
  G.install({
    { vim.ui, "select" },
    { package.preload, "sessions.core" },
  })

  local branch

  -- The live checkout's reflog of HEAD, read once before any test: the last
  -- test proves no test checked the live checkout out. Only checkout entries
  -- count: in a shared checkout another session may commit, amend or
  -- `pull --rebase` while the suite runs, which appends reflog lines too.
  local live_root = vim.fs.normalize(vim.fn.fnamemodify(dir_of_spec, ":p") .. "../..")
  ---@return string reflog the reflog of HEAD ("" when there is none)
  local function live_reflog()
    local r = vim.system({ "git", "-C", live_root, "rev-parse", "--git-path", "logs/HEAD" }):wait()
    local path = vim.trim(r.stdout or "")
    if path ~= "" and not path:match("^%a:") and not path:match("^/") then
      path = live_root .. "/" .. path
    end
    local fh = r.code == 0 and io.open(path, "rb") or nil
    local text = fh and fh:read("*a") or ""
    if fh then fh:close() end
    return text
  end
  --- Checkout entries in `after` that `before` does not have. A line counts
  --- as old when `before` holds it, so a reflog that was expired or
  --- rewritten in between does not report its kept lines again.
  ---@param before string
  ---@param after string
  ---@return string[] lines
  local function new_checkouts(before, after)
    local seen = {}
    for line in before:gmatch("[^\n]+") do
      seen[line] = true
    end
    local found = {}
    for line in after:gmatch("[^\n]+") do
      if not seen[line] and line:find("\tcheckout: moving from ", 1, true) then
        found[#found + 1] = line
      end
    end
    return found
  end
  local live_before = live_reflog()

  local original_cwd, repo

  ---@param args string[]
  local function git_in_repo(args)
    local argv = {
      "git",
      "-C",
      repo,
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "-c",
      "commit.gpgsign=false",
    }
    vim.list_extend(argv, args)
    local r = vim.system(argv):wait()
    assert.equals(0, r.code, ("fixture: git %s failed: %s"):format(args[1], tostring(r.stderr)))
  end

  before_each(function()
    original_cwd = vim.fn.getcwd()
    repo = vim.fn.tempname() .. "-gitsuite-branch"
    vim.fn.mkdir(repo, "p")
    git_in_repo({ "init", "-q", "-b", "main" })
    vim.fn.writefile({ "x" }, repo .. "/a.txt")
    git_in_repo({ "add", "a.txt" })
    git_in_repo({ "commit", "-q", "-m", "init" })
    git_in_repo({ "branch", "other" })
    vim.api.nvim_set_current_dir(repo)
    package.loaded["gitsuite.features.branch"] = nil
    branch = require("gitsuite.features.branch")
  end)

  after_each(function()
    vim.api.nvim_set_current_dir(original_cwd)
    pcall(vim.fn.delete, repo, "rf")
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
    assert.equals("main", git.current_branch(), "the throwaway repo starts on main")
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
    -- so this switches the throwaway repo to its second branch.
    local git = require("lib.nvim.git")
    assert.equals("main", git.current_branch())

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
      on_choice("other")
    end

    local ok = pcall(branch.switch)

    vim.ui.select = original_select
    vim.api.nvim_del_augroup_by_id(group)

    assert.is_true(ok)
    assert.is_not_nil(captured)
    assert.equals("other", captured.branch)
    assert.equals(git.repo_root(), captured.dir)
    assert.equals("other", git.current_branch())
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

    -- Like "fires GitsuiteBranchSwitched" above: a real checkout of the
    -- throwaway repo's second branch.

    after_each(function()
      config.setup({}) -- reset to defaults: this is shared, process-wide state
      package.loaded["sessions.core"] = nil
    end)

    it("default (branch.sessions = false): never touches sessions.nvim", function()
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
        on_choice("other")
      end
      local ok = pcall(branch.switch)
      vim.ui.select = original_select

      assert.is_true(ok)
      assert.same({}, calls)
    end)

    it("opt-in (branch.sessions = true): saves before the checkout, loads after", function()
      local git = require("lib.nvim.git")
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
        on_choice("other")
      end
      local ok = pcall(branch.switch)
      vim.ui.select = original_select

      assert.is_true(ok)
      assert.equals(2, #events)
      assert.equals("save", events[1].fn)
      assert.is_nil(events[1].name, "save(nil) -- sessions.nvim auto-resolves the name")
      assert.equals("main", events[1].branch, "save() ran BEFORE HEAD moved")
      assert.equals("load", events[2].fn)
      assert.is_nil(events[2].name)
      assert.equals("other", events[2].branch, "load() ran AFTER HEAD moved")
    end)

    it("opt-in but sessions.nvim absent: the checkout still succeeds", function()
      config.setup({ branch = { sessions = true } })

      package.loaded["sessions.core"] = nil
      local orig_preload = package.preload["sessions.core"]
      package.preload["sessions.core"] = function()
        error("no sessions.nvim here")
      end

      local original_select = vim.ui.select
      vim.ui.select = function(_, _, on_choice)
        on_choice("other")
      end
      local ok = pcall(branch.switch)
      vim.ui.select = original_select
      package.preload["sessions.core"] = orig_preload

      assert.is_true(ok)
      assert.equals("other", require("lib.nvim.git").current_branch())
    end)
  end)

  describe("live checkout guard", function()
    local id =
      "0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 t <t@t> 1 +0000\t"
    it("ignores commits, amends and rebases another session appends", function()
      local before = id .. "commit: one\n"
      local after = before
        .. id
        .. "commit (amend): one\n"
        .. id
        .. "pull --rebase (start): checkout origin/main\n"
        .. id
        .. "pull --rebase (finish): returning to refs/heads/main\n"
      assert.same({}, new_checkouts(before, after))
    end)

    it("reports a checkout appended since the snapshot", function()
      local before = id .. "checkout: moving from main to other\n"
      local line = id .. "checkout: moving from other to main"
      assert.same({ line }, new_checkouts(before, before .. id .. "commit: x\n" .. line .. "\n"))
    end)

    -- Last on purpose: the snapshot was taken before the first test.
    it("no test checked out the live checkout", function()
      local moved = new_checkouts(live_before, live_reflog())
      assert.same({}, moved, "a test checked out the live repository")
    end)
  end)
end)
