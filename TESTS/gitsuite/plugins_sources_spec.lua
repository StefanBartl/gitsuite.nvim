-- TESTS/gitsuite/plugins_sources_spec.lua -- gitsuite.util.repos and the plugin
-- source adapters (lazy / pack / clones) plus gitsuite.features.plugins.sources.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("gitsuite plugin sources", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local sources, adapter

  local saved_lazy, saved_preload, saved_pack_get
  before_each(function()
    saved_lazy = package.loaded["lazy.core.config"]
    saved_preload = package.preload["lazy"]
    saved_pack_get = vim.pack and vim.pack.get
    for _, name in ipairs({
      "gitsuite.features.plugins.sources",
      "gitsuite.adapter",
      "gitsuite.adapter.lazy",
      "gitsuite.adapter.pack",
      "gitsuite.adapter.clones",
    }) do
      package.loaded[name] = nil
    end
    package.loaded["lazy.core.config"] = nil
    adapter = require("gitsuite.adapter")
    sources = require("gitsuite.features.plugins.sources")
    require("gitsuite.config").setup({})
  end)

  after_each(function()
    package.loaded["lazy.core.config"] = saved_lazy
    package.preload["lazy"] = saved_preload
    if vim.pack then vim.pack.get = saved_pack_get end
    F.cleanup()
  end)

  ---A fake `lazy.core.config` whose plugins inherit through a metatable, like
  ---lazy's. A plugin's `__inherit` table holds the fields that exist ONLY on the
  ---inherited side (invisible to `rawget`/`pairs`).
  local function install_fake_lazy(plugins, version)
    local super = { lazy = true }
    local map = {}
    for name, fields in pairs(plugins) do
      local inherited = fields.__inherit
      fields.__inherit = nil
      map[name] = setmetatable(fields, { __index = inherited or super })
    end
    package.loaded["lazy.core.config"] = { version = version or "11.17.5", plugins = map }
  end

  ---A directory of three clones: two real (`.git` directory), one worktree
  ---(`.git` file) and one plain folder.
  local function clone_root()
    local root = F.tmpdir("-clones")
    for _, name in ipairs({ "alpha.nvim", "beta.nvim" }) do
      local repo = root .. "/" .. name
      vim.fn.mkdir(repo, "p")
      F.git(repo, { "init", "-q", "-b", "main" })
    end
    F.git(root .. "/alpha.nvim", {
      "remote",
      "add",
      "origin",
      "https://github.com/someone/alpha.nvim.git",
    })
    vim.fn.mkdir(root .. "/worktree.nvim", "p")
    F.write(root .. "/worktree.nvim/.git", "gitdir: /elsewhere/.git/worktrees/x\n")
    vim.fn.mkdir(root .. "/plain-folder", "p")
    return root
  end

  describe("util.repos", function()
    local repos = require("gitsuite.util.repos")

    it("tells a .git directory, a .git file and no .git apart", function()
      local root = clone_root()
      assert.equals("directory", repos.git_marker(root .. "/alpha.nvim"))
      assert.equals("file", repos.git_marker(root .. "/worktree.nvim"))
      assert.is_nil(repos.git_marker(root .. "/plain-folder"))
      assert.is_true(repos.is_git_repo(root .. "/worktree.nvim"))
      assert.is_false(repos.is_git_dir(root .. "/worktree.nvim"))
      assert.is_true(repos.is_git_dir(root .. "/alpha.nvim"))
    end)

    it("is what the dashboard's repos module re-exports", function()
      local dashboard = require("gitsuite.features.dashboard.repos")
      assert.equals(repos.is_git_repo, dashboard.is_git_repo)
      assert.equals(repos.collect_repos, dashboard.collect_repos)
      assert.equals(repos.normalize_path, dashboard.normalize_path)
    end)

    it("collects the worktree-style checkout too (the dashboard accepts a .git file)", function()
      local root = clone_root()
      table.sort(repos.collect_repos(root))
      assert.equals(3, #repos.collect_repos(root))
    end)
  end)

  describe("adapter.lazy", function()
    it("is available exactly when lazy.core.config is loaded, and never requires lazy", function()
      package.preload["lazy"] = function()
        error("adapter.lazy must not require('lazy')")
      end
      local lazy = require("gitsuite.adapter.lazy")
      assert.is_false(lazy.is_available())
      install_fake_lazy({})
      assert.is_true(lazy.is_available())
      assert.equals("11.17.5", lazy.version())
      assert.is_true(pcall(lazy.list))
    end)

    it("reads plugins through lazy's metatable inheritance, sorted, with their pins", function()
      install_fake_lazy({
        ["b.nvim"] = {
          name = "b.nvim",
          dir = "/p/b.nvim",
          url = "https://github.com/o/b.nvim.git",
          __inherit = { version = "1.*" },
          _ = { installed = true },
        },
        ["a.nvim"] = {
          name = "a.nvim",
          dir = "/p/a.nvim",
          __inherit = { branch = "v3.x", pin = true },
          _ = { is_local = true },
        },
      })
      local refs = assert(require("gitsuite.adapter.lazy").list())
      assert.equals(2, #refs)
      assert.equals("a.nvim", refs[1].name)
      assert.is_true(refs[1].is_local)
      assert.equals("v3.x", refs[1].spec.branch)
      assert.is_true(refs[1].spec.pin)
      assert.equals("lazy", refs[1].managed_by)
      assert.equals("1.*", refs[2].spec.version)
      assert.equals("https://github.com/o/b.nvim.git", refs[2].url)
    end)

    it("leaves out virtual plugins and ones lazy knows are not installed", function()
      install_fake_lazy({
        ["real"] = { name = "real", dir = "/p/real", _ = {} },
        ["virtual"] = { name = "virtual", dir = "/dev/null/virtual", _ = {} },
        ["flagged"] = { name = "flagged", dir = "/p/flagged", virtual = true, _ = {} },
        ["missing"] = { name = "missing", dir = "/p/missing", _ = { installed = false } },
        ["no-dir"] = { name = "no-dir", _ = {} },
      })
      local refs = assert(require("gitsuite.adapter.lazy").list())
      assert.equals(1, #refs)
      assert.equals("real", refs[1].name)
    end)

    it("reports an unexpected structure instead of guessing", function()
      package.loaded["lazy.core.config"] = { plugins = "not a table" }
      local refs, err = require("gitsuite.adapter.lazy").list()
      assert.is_nil(refs)
      assert.is_truthy(err:find("lazy.nvim", 1, true))
    end)
  end)

  describe("adapter.pack", function()
    ---Point `stdpath("config")` / `stdpath("data")` at throwaway folders for one test.
    ---@return string config, string data, fun() restore
    local function fake_stdpath()
      local config, data = F.tmpdir("-pack-config"), F.tmpdir("-pack-data")
      local original = vim.fn.stdpath
      vim.fn.stdpath = function(what)
        if what == "config" then return config end
        if what == "data" then return data end
        return original(what)
      end
      return config, data, function()
        vim.fn.stdpath = original
      end
    end

    it("reads the lockfile and the folders on disk, without calling vim.pack.get", function()
      local config, data, restore = fake_stdpath()
      local calls = 0
      local original_get = vim.pack and vim.pack.get
      if vim.pack then
        vim.pack.get = function()
          calls = calls + 1
          return {}
        end
      end
      local ok, err = pcall(function()
        local pack = require("gitsuite.adapter.pack")
        assert.is_false(pack.is_available(), "no lockfile: nothing is managed")

        local lock = config .. "/nvim-pack-lock.json"
        F.write(
          lock,
          vim.json.encode({
            plugins = {
              ["x.nvim"] = { rev = "abc", src = "https://github.com/o/x.nvim", version = "'main'" },
              ["y.nvim"] = { rev = "def", src = "https://github.com/o/y.nvim" },
              ["gone.nvim"] = { rev = "123", src = "https://github.com/o/gone.nvim" },
              ["../escape"] = { rev = "456" },
            },
          })
        )
        local before = table.concat(vim.fn.readfile(lock, "b"), "\n")
        vim.fn.mkdir(data .. "/site/pack/core/opt/x.nvim", "p")
        vim.fn.mkdir(data .. "/site/pack/core/opt/y.nvim", "p")

        assert.is_true(pack.is_available())
        local refs = assert(pack.list())
        assert.equals(2, #refs, "only plugins that are on disk")
        assert.equals("x.nvim", refs[1].name)
        assert.equals("main", refs[1].spec.branch)
        assert.equals("https://github.com/o/x.nvim", refs[1].url)
        assert.is_nil(refs[2].spec.branch)
        assert.equals("pack", refs[1].managed_by)
        assert.equals(
          vim.fs.normalize(data .. "/site/pack/core/opt/x.nvim"),
          vim.fs.normalize(refs[1].dir)
        )

        assert.equals(before, table.concat(vim.fn.readfile(lock, "b"), "\n"), "lockfile untouched")
        assert.is_nil(vim.uv.fs_stat(data .. "/site/pack/core/opt/gone.nvim"), "nothing was cloned")
      end)
      restore()
      if vim.pack then vim.pack.get = original_get end
      assert(ok, err)
      assert.equals(0, calls, "vim.pack.get synchronises the lockfile and must not be called")
    end)

    it("treats an oversized or malformed lockfile as 'not managed'", function()
      local config, _, restore = fake_stdpath()
      local ok, err = pcall(function()
        local pack = require("gitsuite.adapter.pack")
        F.write(config .. "/nvim-pack-lock.json", "{ not json")
        assert.is_false(pack.is_available())
        local refs, why = pack.list()
        assert.is_nil(refs)
        assert.is_truthy(why)
      end)
      restore()
      assert(ok, err)
    end)
  end)

  describe("adapter.clones", function()
    it("lists clones with a .git directory and skips worktrees and plain folders", function()
      local root = clone_root()
      local refs = require("gitsuite.adapter.clones").list({ roots = { root } })
      local names = vim.tbl_map(function(r)
        return r.name
      end, refs)
      assert.same({ "alpha.nvim", "beta.nvim" }, names)
      assert.equals("https://github.com/someone/alpha.nvim.git", refs[1].url)
      assert.is_nil(refs[2].url)
      assert.is_false(refs[1].dir:find("\\", 1, true) ~= nil, "paths use forward slashes")
    end)

    it("is always available and has default roots under stdpath('data')", function()
      local clones = require("gitsuite.adapter.clones")
      assert.is_true(clones.is_available())
      local roots = clones.roots()
      assert.is_true(#roots >= 1)
      assert.is_truthy(roots[1]:find("lazy", 1, true))
    end)
  end)

  describe("sources.list", function()
    it("auto: takes lazy when it is loaded (resolve_first)", function()
      install_fake_lazy({ ["only"] = { name = "only", dir = "/p/only", _ = {} } })
      local refs, used = sources.list({ roots = { F.tmpdir() } })
      assert.same({ "lazy" }, used)
      assert.equals("only", refs[1].name)
    end)

    it("auto: falls back to the clones when lazy is not loaded", function()
      local root = clone_root()
      local refs, used = sources.list({ roots = { root } })
      assert.same({ "clones" }, used)
      assert.equals(2, #refs)
    end)

    it("auto: moves on to the next source when lazy's data has an unexpected shape", function()
      package.loaded["lazy.core.config"] = { plugins = 42 }
      local root = clone_root()
      local refs, used, errors = sources.list({ roots = { root } })
      assert.same({ "clones" }, used)
      assert.equals(2, #refs)
      assert.equals(1, #errors)
      assert.is_truthy(errors[1]:find("^lazy:"))
    end)

    it("auto: an empty list from lazy does not hide the clones the next source finds", function()
      install_fake_lazy({})
      local root = clone_root()
      local refs, used = sources.list({ roots = { root } })
      assert.same({ "clones" }, used)
      assert.equals(2, #refs)
    end)

    it("auto: no source with anything gives an empty list, not an error", function()
      install_fake_lazy({})
      local refs, used, errors = sources.list({ roots = { F.tmpdir() } })
      assert.same({}, refs)
      assert.same({}, errors)
      assert.is_table(used)
    end)

    it("an explicit list naming nothing available uses no source", function()
      local _, used = sources.list({ sources = { "lazy" } })
      assert.same({}, used)
    end)

    it("an explicit list is the union of the available sources, deduplicated by path", function()
      local root = clone_root()
      install_fake_lazy({
        ["alpha.nvim"] = { name = "alpha.nvim", dir = root .. "/alpha.nvim", _ = {} },
        ["extra"] = { name = "extra", dir = "/elsewhere/extra", _ = {} },
      })
      local refs, used = sources.list({ sources = { "lazy", "clones" }, roots = { root } })
      assert.same({ "lazy", "clones" }, used)
      local names = vim.tbl_map(function(r)
        return r.name
      end, refs)
      assert.same({ "alpha.nvim", "beta.nvim", "extra" }, names)
    end)

    it("include_local = false drops the dir-mode plugins", function()
      install_fake_lazy({
        a = { name = "a", dir = "/p/a", _ = {} },
        mine = { name = "mine", dir = "/r/mine", _ = { is_local = true } },
      })
      local refs = sources.list({ include_local = false })
      assert.equals(1, #refs)
      assert.equals("a", refs[1].name)
    end)

    it("the registry's resolve_first has its first real caller", function()
      local used_adapters = {}
      local original = adapter.resolve_first
      adapter.resolve_first = function(candidates)
        used_adapters[#used_adapters + 1] = table.concat(candidates, ",")
        return original(candidates)
      end
      sources.list({ roots = { F.tmpdir() } })
      adapter.resolve_first = original
      assert.equals("lazy,pack,clones", used_adapters[1])
    end)
  end)

  describe("sources.resolve", function()
    local root

    before_each(function()
      root = clone_root()
      require("gitsuite.config").setup({ plugins = { roots = { root } } })
    end)

    it("resolves an installed plugin by name", function()
      local target = assert(sources.resolve("alpha.nvim"))
      assert.equals("plugin", target.kind)
      assert.equals("alpha.nvim", target.name)
      assert.is_not_nil(target.ref)
    end)

    it("resolves the name in another case when that is unambiguous", function()
      assert.equals("beta.nvim", assert(sources.resolve("BETA.nvim")).name)
    end)

    it("resolves owner/repo against the remote of an installed plugin", function()
      assert.equals("alpha.nvim", assert(sources.resolve("someone/alpha.nvim")).name)
    end)

    it("resolves a path to a clone", function()
      local target = assert(sources.resolve(root .. "/beta.nvim"))
      assert.equals("path", target.kind) -- by name it would have been the plugin
      assert.is_truthy(target.dir:find("beta.nvim", 1, true))
    end)

    it("resolves a clone outside every source as a path target", function()
      local lone = F.init("-lone")
      local target = assert(sources.resolve(lone))
      assert.equals("path", target.kind)
    end)

    it("refuses a well-formed owner/repo that is not installed, saying why", function()
      local target, err = sources.resolve("someone/not-installed")
      assert.is_nil(target)
      assert.is_truthy(err:find("not an installed plugin", 1, true))
      assert.is_truthy(err:find("never fetches", 1, true))
    end)

    it("suggests names for a typo", function()
      local target, err = sources.resolve("alph")
      assert.is_nil(target)
      assert.is_truthy(err:find("did you mean alpha.nvim", 1, true))
    end)

    it("refuses a .git file (worktree) with the reason, and a non-repository", function()
      local _, wt_err = sources.resolve(root .. "/worktree.nvim")
      assert.is_truthy(wt_err:find(".git is a file", 1, true))
      local _, plain_err = sources.resolve(root .. "/plain-folder")
      assert.is_truthy(plain_err:find("not a git repository", 1, true))
    end)

    it("refuses an empty target and one with a NUL byte", function()
      assert.is_nil((sources.resolve("")))
      local target, err = sources.resolve("alpha\0nvim")
      assert.is_nil(target)
      assert.is_truthy(err:find("NUL", 1, true))
    end)

    it("does not pick one of two plugins whose names differ only in case", function()
      install_fake_lazy({
        Foo = { name = "Foo", dir = "/p/Foo", _ = {} },
        foo = { name = "foo", dir = "/p/foo", _ = {} },
      })
      assert.equals("Foo", assert(sources.resolve("Foo")).name) -- exact name wins
      local target, err = sources.resolve("FOO")
      assert.is_nil(target)
      assert.is_truthy(err:find("differ only in case", 1, true))
    end)

    it("completes without surprises: no duplicates, no shell expansion, no error", function()
      local all = sources.complete("")
      local seen = {}
      for _, name in ipairs(all) do
        assert.is_nil(seen[name], "duplicate candidate " .. name)
        seen[name] = true
      end
      -- a backtick or wildcard is never handed to getcompletion()
      local original = vim.fn.getcompletion
      local asked = {}
      vim.fn.getcompletion = function(lead, ...)
        asked[#asked + 1] = lead
        return original(lead, ...)
      end
      assert.is_table(sources.complete("`echo hi`/x"))
      assert.is_table(sources.complete("*/x"))
      assert.is_table(sources.complete("./"))
      vim.fn.getcompletion = original
      assert.same({ "./" }, asked)
    end)

    it("completes names and starts no process", function()
      local spawned = 0
      local original = vim.system
      vim.system = function(...)
        spawned = spawned + 1
        return original(...)
      end
      local names = sources.complete("al")
      vim.system = original
      assert.same({ "alpha.nvim" }, names)
      assert.equals(0, spawned)
    end)

    it("finds the plugin of a buffer whose path reaches it through a symlink", function()
      local real_root = clone_root()
      local link_parent = F.tmpdir("-link-parent")
      local link = link_parent .. "/plugins"
      local linked = vim.uv.fs_symlink(real_root, link, { dir = true })
      if not linked then
        print("skip  plugins_sources_spec.lua: no permission to create symlinks here")
        return
      end
      require("gitsuite.config").setup({ plugins = { roots = { link } } })
      F.write(real_root .. "/alpha.nvim/lua/a.lua", "return 1\n")
      -- the manager knows the plugin under the link, the buffer under the real path
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, real_root .. "/alpha.nvim/lua/a.lua")
      local target = assert(sources.of_buffer(buf))
      assert.equals("alpha.nvim", target.name)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("finds the installed plugin that contains a buffer's file", function()
      F.write(root .. "/alpha.nvim/lua/a.lua", "return 1\n")
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, root .. "/alpha.nvim/lua/a.lua")
      local target = assert(sources.of_buffer(buf))
      assert.equals("alpha.nvim", target.name)
      vim.api.nvim_buf_delete(buf, { force = true })
      local other = vim.api.nvim_create_buf(false, true)
      assert.is_nil(sources.of_buffer(other))
      vim.api.nvim_buf_delete(other, { force = true })
    end)
  end)

  describe("review fixes", function()
    it("resolves a buffer to the DEEPEST plugin folder that contains it", function()
      local base = F.tmpdir("-nested")
      local outer, inner = base .. "/outer", base .. "/outer/inner"
      for _, dir in ipairs({ outer, inner }) do
        vim.fn.mkdir(dir, "p")
        F.git(dir, { "init", "-q", "-b", "main" })
      end
      require("gitsuite.config").setup({
        plugins = { roots = { base, outer }, sources = { "clones" } },
      })
      F.write(inner .. "/a.lua", "return 1\n")
      F.write(outer .. "/b.lua", "return 2\n")
      local function owner(file)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, file)
        local target = sources.of_buffer(buf)
        vim.api.nvim_buf_delete(buf, { force = true })
        return target and target.name
      end
      assert.equals("inner", owner(inner .. "/a.lua"))
      assert.equals("outer", owner(outer .. "/b.lua"))
    end)

    it("takes a source whose adapter throws for a failed source, not a crashed list", function()
      local root = clone_root()
      require("gitsuite.config").setup({ plugins = { roots = { root } } })
      package.loaded["lazy.core.config"] = {
        plugins = {
          bad = setmetatable({}, {
            __index = function()
              error("boom from lazy internals")
            end,
          }),
        },
      }
      local ok, refs, used, errors = pcall(function()
        return sources.list()
      end)
      assert.is_true(ok, tostring(refs))
      assert.same({ "clones" }, used)
      assert.equals(2, #refs)
      assert.is_truthy(errors[1] and errors[1]:find("^lazy"))
    end)

    it("expands a typed path once: a $ in a variable's value stays literal", function()
      local base = F.tmpdir("-literal")
      local literal = base .. "/lit$NAMEX"
      vim.fn.mkdir(literal .. "/repo", "p")
      F.git(literal .. "/repo", { "init", "-q", "-b", "main" })
      local saved = { vim.env.GS_BASE, vim.env.NAMEX }
      vim.env.GS_BASE = literal
      vim.env.NAMEX = "other"
      local target = sources.resolve("$GS_BASE/repo")
      vim.env.GS_BASE, vim.env.NAMEX = saved[1], saved[2]
      assert.is_not_nil(target)
      assert.is_truthy(target.dir:find("lit$NAMEX/repo", 1, true))
    end)

    it("reaches a repository through a UNC path (Windows)", function()
      if not require("lib.nvim.cross.platform.is_windows")() then
        -- elsewhere "//host/share" is just a path that does not exist
        local target = sources.resolve("//localhost/c$/nowhere")
        assert.is_nil(target)
        return
      end
      local repo = F.init("-unc-target")
      local drive, rest = repo:match("^(%a):[/\\](.*)$")
      if not drive then return end
      local unc = ("//localhost/%s$/%s"):format(drive, rest:gsub("\\", "/"))
      if not vim.uv.fs_stat(unc) then
        print("skip  plugins_sources_spec.lua: the admin share is not reachable here")
        return
      end
      local target, err = sources.resolve(unc)
      assert.is_not_nil(target, err)
      assert.equals("path", target.kind)
      assert.is_truthy(target.dir:find("^//localhost/"))
    end)

    it("completes names without reading any clone's configuration", function()
      local root = clone_root()
      require("gitsuite.config").setup({ plugins = { roots = { root }, sources = { "clones" } } })
      local opened = 0
      local original = io.open
      io.open = function(...)
        opened = opened + 1
        return original(...)
      end
      local names = sources.complete("al")
      io.open = original
      assert.same({ "alpha.nvim" }, names)
      assert.equals(0, opened)
    end)
  end)
end)
