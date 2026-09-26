-- TESTS/gitsuite/dashboard_spec.lua -- gitsuite.features.dashboard.{repos,status}
-- and the actions wrapper, moved here from reposcope.nvim's own
-- utils/{repos,repo_dashboard,repo_actions}.lua.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
describe("gitsuite.features.dashboard", function()
  local repos, status, actions

  local function tmpdir(suffix)
    local dir = vim.fn.tempname() .. suffix
    vim.fn.mkdir(dir, "p")
    return dir
  end

  ---@param dir string
  ---@param args string[]
  local function git(dir, args)
    local argv =
      { "git", "-c", "user.name=spec", "-c", "user.email=spec@example.invalid", "-C", dir }
    vim.list_extend(argv, args)
    local res = vim.system(argv, { text = true }):wait()
    assert.equals(
      0,
      res.code,
      ("fixture: git %s failed: %s"):format(table.concat(args, " "), res.stderr)
    )
  end

  before_each(function()
    package.loaded["gitsuite.features.dashboard.repos"] = nil
    package.loaded["gitsuite.features.dashboard.status"] = nil
    package.loaded["gitsuite.features.dashboard.actions"] = nil
    repos = require("gitsuite.features.dashboard.repos")
    status = require("gitsuite.features.dashboard.status")
    actions = require("gitsuite.features.dashboard.actions")
  end)

  describe("repos: is_git_repo / collect_repos / resolve_group_repos", function()
    local root

    before_each(function()
      root = tmpdir("-gitsuite-dashboard-repos")
      vim.fn.mkdir(root .. "/a/.git", "p")
      vim.fn.mkdir(root .. "/b/.git", "p")
      vim.fn.mkdir(root .. "/not-a-repo", "p")
    end)

    after_each(function()
      pcall(vim.fn.delete, root, "rf")
    end)

    it("is_git_repo: true for a directory with .git, false otherwise", function()
      assert.is_true(repos.is_git_repo(root .. "/a"))
      assert.is_false(repos.is_git_repo(root .. "/not-a-repo"))
      assert.is_false(repos.is_git_repo(root .. "/does-not-exist"))
    end)

    it("collect_repos: only immediate git-repository children, non-recursive", function()
      local found = repos.collect_repos(root)
      table.sort(found)
      assert.equals(2, #found)
      assert.is_not_nil(found[1]:find("/a$"))
      assert.is_not_nil(found[2]:find("/b$"))
    end)

    it("resolve_group_repos: a repo entry resolves to itself", function()
      local out = repos.resolve_group_repos({ root .. "/a" })
      assert.equals(1, #out)
      assert.is_not_nil(out[1]:find("/a$"))
    end)

    it("resolve_group_repos: a plain-directory entry resolves to its repo children", function()
      local out = repos.resolve_group_repos({ root })
      table.sort(out)
      assert.equals(2, #out)
    end)

    it("resolve_group_repos: dedupes against `existing`", function()
      local out = repos.resolve_group_repos({ root .. "/a", root .. "/b" }, { root .. "/a" })
      assert.equals(1, #out)
      assert.is_not_nil(out[1]:find("/b$"))
    end)
  end)

  describe("status.scan_group", function()
    local root

    before_each(function()
      root = tmpdir("-gitsuite-dashboard-status")
      vim.fn.mkdir(root .. "/repo1", "p")
      git(root .. "/repo1", { "init", "-q", "-b", "main" })
      vim.fn.writefile({ "x" }, root .. "/repo1/f.txt")
      git(root .. "/repo1", { "add", "-A" })
      git(root .. "/repo1", { "commit", "-q", "-m", "first" })
    end)

    after_each(function()
      pcall(vim.fn.delete, root, "rf")
    end)

    it("reads a group's paths into records, one per repository", function()
      local result
      status.scan_group({ root .. "/repo1" }, function(records, errors)
        result = { records = records, errors = errors }
      end)
      vim.wait(2000, function()
        return result ~= nil
      end)

      assert.is_not_nil(result)
      assert.equals(1, #result.records)
      assert.equals(0, #result.errors)
      assert.equals("repo1", result.records[1].name)
      assert.equals("clean", result.records[1].state)
    end)

    it("an empty resolved path list completes immediately with no records", function()
      local result
      status.scan_group({ root .. "/does-not-exist" }, function(records, errors)
        result = { records = records, errors = errors }
      end)
      assert.is_not_nil(result, "scan_group calls on_complete synchronously when nothing resolves")
      assert.equals(0, #result.records)
    end)
  end)

  describe("actions: adapt lib.nvim.git's async primitives to (repo, on_done)", function()
    local bare, clone

    before_each(function()
      bare = tmpdir("-gitsuite-dashboard-actions-bare")
      git(bare, { "init", "-q", "--bare", "-b", "main" })
      clone = tmpdir("-gitsuite-dashboard-actions-clone")
      local res = vim.system({ "git", "clone", "-q", bare, clone }):wait()
      assert.equals(0, res.code)
      vim.fn.writefile({ "x" }, clone .. "/f.txt")
      git(clone, { "add", "-A" })
      git(clone, { "commit", "-q", "-m", "first" })
    end)

    after_each(function()
      pcall(vim.fn.delete, bare, "rf")
      pcall(vim.fn.delete, clone, "rf")
    end)

    it("push() reports success against a real remote", function()
      local ok, err
      actions.push(clone, function(ok_, err_)
        ok, err = ok_, err_
      end)
      vim.wait(5000, function()
        return ok ~= nil
      end)
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("fetch() reports success with nothing new", function()
      local ok
      actions.fetch(clone, function(ok_)
        ok = ok_
      end)
      vim.wait(5000, function()
        return ok ~= nil
      end)
      assert.is_true(ok)
    end)
  end)
end)
