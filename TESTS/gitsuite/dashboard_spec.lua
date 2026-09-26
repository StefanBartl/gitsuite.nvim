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

    it(
      "normalize_path: a bare separator resolves to the filesystem root, not vim.fn.getcwd()",
      function()
        -- Regression: to_absolute() used to strip a trailing separator
        -- unconditionally before resolving, so a path made of nothing but
        -- separators ("/") stripped down to "" first -- and fnamemodify/
        -- expand resolve "" to the current working directory, not the
        -- drive/filesystem root.
        local root_key = repos.normalize_path("/")
        local cwd_key = repos.normalize_path(vim.fn.getcwd())
        assert.is_not.equal(
          cwd_key,
          root_key,
          "a bare '/' must not silently resolve to whatever directory nvim happened to start in"
        )
      end
    )
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

  describe("status.scan: on_complete always fires, even on a validation failure", function()
    -- Regression: on_complete used to never fire on these paths (a bare
    -- notify() + return), which broke the multi-page dashboard's own
    -- fallback ("the default page failed, fall through to a configured
    -- group page instead") -- that fallback lives in
    -- gitsuite.features.dashboard.init, but the contract it depends on is
    -- this module's, so it belongs here.
    it(
      "an inaccessible directory still invokes on_complete, with the failure as its one error",
      function()
        local result
        status.scan(vim.fn.tempname() .. "-gitsuite-status-scan-missing", function(records, errors)
          result = { records = records, errors = errors }
        end)
        assert.is_not_nil(result, "on_complete fires synchronously on this validation path")
        assert.equals(0, #result.records)
        assert.equals(1, #result.errors)
      end
    )

    it("a directory with no repositories still invokes on_complete", function()
      local empty = vim.fn.tempname() .. "-gitsuite-status-scan-empty"
      vim.fn.mkdir(empty, "p")
      local result
      status.scan(empty, function(records, errors)
        result = { records = records, errors = errors }
      end)
      assert.is_not_nil(result)
      assert.equals(0, #result.records)
      assert.equals(1, #result.errors)
      pcall(vim.fn.delete, empty, "rf")
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

  describe("state.dashboard_pages: normalized path matching, no long-lived cache", function()
    local dashboard_pages
    local original_stdpath, fake_data_dir

    before_each(function()
      package.loaded["gitsuite.state.dashboard_pages"] = nil
      fake_data_dir = vim.fn.tempname() .. "-gitsuite-dashboard-pages-data"
      original_stdpath = vim.fn.stdpath
      -- luacheck: ignore 122 -- deliberately shadowing a vim.* API for the
      -- duration of this describe block, restored in after_each below.
      vim.fn.stdpath = function(what)
        if what == "data" then return fake_data_dir end
        return original_stdpath(what)
      end
      dashboard_pages = require("gitsuite.state.dashboard_pages")
    end)

    after_each(function()
      vim.fn.stdpath = original_stdpath
      pcall(vim.fn.delete, fake_data_dir, "rf")
    end)

    it("remove() matches a raw, unexpanded add() by its resolved form", function()
      local raw = "~/gitsuite-dashboard-pages-test-dir"
      dashboard_pages.add("p", raw)
      local resolved = vim.fn.fnamemodify(vim.fn.expand(raw), ":p"):gsub("[\\/]+$", "")

      local ok = dashboard_pages.remove("p", resolved)
      assert.is_true(ok)
      assert.same(
        {},
        dashboard_pages.apply("p", {}),
        "the added entry is gone under either spelling"
      )
    end)

    it("remove() hides a statically configured entry spelled with a different separator", function()
      local static = "/tmp/gitsuite-dashboard-pages-static"
      local differently_spelled = static:gsub("/", "\\")

      dashboard_pages.remove("p", differently_spelled)
      assert.same(
        {},
        dashboard_pages.apply("p", { static }),
        "the static entry stays hidden even though it was never spelled exactly like this"
      )
    end)

    it(
      "add() recognizes an already-added path under a different spelling as the same entry",
      function()
        dashboard_pages.add("p", "/tmp/gitsuite-dup/")
        dashboard_pages.add("p", "/tmp/gitsuite-dup") -- no trailing slash this time
        assert.equals(1, #dashboard_pages.apply("p", {}), "not added twice")
      end
    )

    it(
      "apply() re-reads the file fresh -- an external write between calls is not shadowed by a stale cache",
      function()
        dashboard_pages.add("p", "/tmp/from-module")

        -- Simulate a second Neovim instance writing to the same file
        -- directly, between this instance's add() and apply().
        local json = require("lib.nvim.fs.json")
        local path = vim.fs.joinpath(fake_data_dir, "gitsuite", "dashboard_pages.json")
        local data = json.read(path)
        table.insert(data.p.added, "/tmp/from-elsewhere")
        json.write(path, data)

        local result = dashboard_pages.apply("p", {})
        table.sort(result)
        assert.same(
          { "/tmp/from-elsewhere", "/tmp/from-module" },
          result,
          "both this instance's own write and the externally-written one are visible"
        )
      end
    )
  end)
end)
