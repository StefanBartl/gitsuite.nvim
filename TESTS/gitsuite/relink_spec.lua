-- TESTS/gitsuite/relink_spec.lua -- gitsuite.features.status.relink
-- (`:Git status relink`), against real throwaway git repos. filetree.nvim
-- is not a sibling checkout of this test environment (like hunk_spec.lua's
-- gitsigns), so it is faked via `package.loaded["filetree.refs"]` -- this
-- suite is about what relink() computes and calls, not filetree.nvim's own
-- reference engine (that belongs to filetree.nvim's own test suite).
describe("gitsuite.features.status.relink", function()
  local relink
  local git = require("lib.nvim.git")

  before_each(function()
    package.loaded["gitsuite.features.status.relink"] = nil
    relink = require("gitsuite.features.status.relink")
  end)

  it("without filetree.nvim: reports it is not installed, no error", function()
    local real_refs = package.loaded["filetree.refs"]
    package.loaded["filetree.refs"] = nil
    local orig_preload = package.preload["filetree.refs"]
    package.preload["filetree.refs"] = function()
      error("no filetree.nvim here")
    end

    local seen = {}
    local original_notify = vim.notify
    vim.notify = function(msg)
      seen[#seen + 1] = tostring(msg)
    end
    local ok = pcall(relink.relink)
    vim.notify = original_notify

    package.preload["filetree.refs"] = orig_preload
    package.loaded["filetree.refs"] = real_refs

    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok, "must not raise, just report an error")
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(1, #seen)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_truthy(seen[1]:find("filetree.nvim is not installed", 1, true))
  end)

  describe("against a real throwaway git repo (filetree.nvim faked)", function()
    local original_cwd, repo, captured

    before_each(function()
      original_cwd = vim.fn.getcwd()
      repo = vim.fn.tempname() .. "-gitsuite-relink"
      vim.fn.mkdir(repo, "p")
      local init = vim.system({ "git", "-C", repo, "init", "-q" }):wait()
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(0, init.code, "fixture: git init failed: " .. tostring(init.stderr))
      vim.system({ "git", "-C", repo, "config", "user.email", "test@example.com" }):wait()
      vim.system({ "git", "-C", repo, "config", "user.name", "Test" }):wait()

      captured = { scan = nil, handle_result = nil }
      package.loaded["filetree.refs"] = {
        scan = function(paths, opts, cb)
          captured.scan = { paths = paths, opts = opts }
          cb({ refs = {}, plans = {} })
        end,
        handle_result = function(result, moves, opts, done)
          captured.handle_result = { result = result, moves = moves, opts = opts }
          done(0)
        end,
      }

      vim.api.nvim_set_current_dir(repo)
    end)

    after_each(function()
      vim.api.nvim_set_current_dir(original_cwd)
      package.loaded["filetree.refs"] = nil
      pcall(vim.fn.delete, repo, "rf")
    end)

    it("no renamed files: reports so, never reaches filetree.refs", function()
      vim.fn.writefile({ "content" }, repo .. "/plain.md")
      relink.relink()

      ---@diagnostic disable-next-line: undefined-field
      assert.is_nil(captured.scan, "scan() was never called")
    end)

    it("a renamed file: scans the old path and hands scan/handle_result the right moves", function()
      vim.fn.writefile({ "# Hello" }, repo .. "/old.md")
      vim.system({ "git", "-C", repo, "add", "old.md" }):wait()
      local commit = vim.system({ "git", "-C", repo, "commit", "-q", "-m", "init" }):wait()
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(0, commit.code, "fixture: git commit failed: " .. tostring(commit.stderr))

      local mv = vim.system({ "git", "-C", repo, "mv", "old.md", "new.md" }):wait()
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(0, mv.code, "fixture: git mv failed: " .. tostring(mv.stderr))

      relink.relink()

      local root = git.repo_root()
      ---@diagnostic disable-next-line: undefined-field
      assert.is_not_nil(root)
      local old_abs = vim.fs.joinpath(root, "old.md")
      local new_abs = vim.fs.joinpath(root, "new.md")

      ---@diagnostic disable-next-line: undefined-field
      assert.is_not_nil(captured.scan, "scan() was called")
      ---@diagnostic disable-next-line: undefined-field
      assert.same({ old_abs }, captured.scan.paths)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals("rename", captured.scan.opts.op)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals("ask", captured.scan.opts.mode)

      ---@diagnostic disable-next-line: undefined-field
      assert.is_not_nil(captured.handle_result, "handle_result() was called")
      ---@diagnostic disable-next-line: undefined-field
      assert.same({ [old_abs] = new_abs }, captured.handle_result.moves)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals("ask", captured.handle_result.opts.mode)
    end)
  end)
end)
