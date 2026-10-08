-- TESTS/gitsuite/plugins_gitlog_spec.lua -- gitsuite.features.plugins.gitlog:
-- the read-only runner (verb allowlist, no network) and the commit reader,
-- against real throwaway repositories including a blobless clone.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("gitsuite.features.plugins.gitlog", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local gitlog

  before_each(function()
    package.loaded["gitsuite.features.plugins.gitlog"] = nil
    require("gitsuite.config").setup({})
    gitlog = require("gitsuite.features.plugins.gitlog")
  end)

  after_each(function()
    F.cleanup()
  end)

  ---Run `gitlog.run` and wait for its answer.
  local function run(args, dir)
    local box
    gitlog.run(args, dir, function(res, err)
      box = { res = res, err = err }
    end)
    vim.wait(20000, function()
      return box ~= nil
    end, 10)
    assert.is_not_nil(box, "gitlog.run called back")
    return box.res, box.err
  end

  describe("check (the verb allowlist)", function()
    it("lets the read-only verbs through", function()
      for _, verb in ipairs({ "log", "rev-parse", "for-each-ref", "merge-base", "diff-tree" }) do
        assert.is_true((gitlog.check({ verb })), verb)
      end
    end)

    it("refuses every verb that writes or talks to a remote", function()
      for _, verb in ipairs({
        "fetch",
        "pull",
        "push",
        "checkout",
        "switch",
        "reset",
        "clean",
        "gc",
        "commit",
        "merge",
        "rebase",
        "clone",
        "remote",
        "config",
        "stash",
        "apply",
        "am",
        "init",
        "update-ref",
        "pack-refs",
      }) do
        local ok, err = gitlog.check({ verb })
        assert.is_false(ok, verb)
        assert.is_truthy(err:find("not a read-only verb", 1, true), verb)
      end
    end)

    it("refuses options that write a file or run a program of the repo's choosing", function()
      for _, arg in ipairs({
        "--output=x",
        "--ext-diff",
        "--textconv",
        "--upload-pack=evil",
        "--exec=evil",
        "--paginate",
      }) do
        local ok = gitlog.check({ "log", arg })
        assert.is_false(ok, arg)
      end
    end)

    it("refuses patch and statistics output, which reads file contents", function()
      for _, arg in ipairs({
        "-p",
        "-u",
        "-c",
        "--cc",
        "--patch",
        "--patch-with-stat",
        "--patch-with-raw",
        "--stat",
        "--stat=80",
        "--numstat",
        "--shortstat",
        "--dirstat",
        "--filters",
        "-S",
        "-G",
        "--pickaxe-regex",
        "--pickaxe-all",
      }) do
        assert.is_false((gitlog.check({ "log", arg })), arg)
        assert.is_false((gitlog.check({ "diff-tree", arg })), arg)
      end
      -- names and messages stay possible
      assert.is_true((gitlog.check({ "log", "--name-status", "--no-renames", "--format=%H" })))
      assert.is_true((gitlog.check({ "diff-tree", "--name-status", "--no-renames", "-r", "HEAD" })))
    end)

    it("refuses an option smuggled in as the verb, and malformed arguments", function()
      assert.is_false((gitlog.check({ "-c", "core.pager=evil", "log" })))
      assert.is_false((gitlog.check({ "--git-dir=x", "log" })))
      assert.is_false((gitlog.check({})))
      assert.is_false((gitlog.check("log")))
      assert.is_false((gitlog.check({ "log", 5 })))
      assert.is_false((gitlog.check({ "log", "a\nb" })))
    end)

    it("does not read what follows a bare -- as an option", function()
      assert.is_true((gitlog.check({ "log", "--", "--output=x" })))
    end)
  end)

  describe("argv (the second lock)", function()
    it("adds --no-textconv --no-ext-diff to the verbs that make a diff", function()
      assert.same({ "log", "-n1", "--no-textconv", "--no-ext-diff" }, gitlog.argv({ "log", "-n1" }))
      assert.same(
        { "diff-tree", "-r", "--no-textconv", "--no-ext-diff", "--", "p" },
        gitlog.argv({ "diff-tree", "-r", "--", "p" })
      )
    end)

    it("leaves the other verbs alone and does not change its input", function()
      local args = { "rev-parse", "HEAD" }
      assert.same({ "rev-parse", "HEAD" }, gitlog.argv(args))
      local diffy = { "log", "-n1" }
      gitlog.argv(diffy)
      assert.same({ "log", "-n1" }, diffy)
    end)

    it("keeps a repository's textconv program from ever starting", function()
      local repo = F.init("-textconv")
      local marker = (F.tmpdir("-marker") .. "/started"):gsub("\\", "/")
      F.write(repo .. "/.gitattributes", "*.txt diff=evil\n")
      F.git(repo, { "config", "diff.evil.textconv", "touch " .. marker })
      F.write(repo .. "/a.txt", "1\n")
      F.commit(repo, "one")
      F.write(repo .. "/a.txt", "2\n")
      F.commit(repo, "two")

      -- Control: without the lock this repository does start the program ...
      F.git(repo, { "log", "-p", "-n1" }, { allow_fail = true })
      local armed = vim.uv.fs_stat(marker) ~= nil
      vim.fn.delete(marker)
      if not armed then return end -- no `touch`/`sh` here: nothing to prove

      -- ... and with the lock `argv` adds, it does not -- even for the one
      -- option the allowlist would otherwise have to catch.
      local locked = gitlog.argv({ "log", "-n1" })
      vim.list_extend(locked, { "-p" })
      F.git(repo, locked, { allow_fail = true })
      assert.is_nil(vim.uv.fs_stat(marker), "textconv ran although --no-textconv was given")
    end)
  end)

  describe("run", function()
    it("refuses a write verb without starting a process", function()
      local repo = F.init("-run-refuse")
      local spawned = 0
      local original = vim.system
      vim.system = function(...)
        spawned = spawned + 1
        return original(...)
      end
      local res, err = run({ "checkout", "-b", "evil" }, repo)
      vim.system = original
      assert.is_nil(res)
      assert.is_truthy(err:find("not a read-only verb", 1, true))
      assert.equals(0, spawned)
      -- ... and the repository is untouched
      assert.equals("main", F.git(repo, { "symbolic-ref", "--short", "HEAD" }))
    end)

    it("runs an allowed verb", function()
      local repo = F.init("-run-ok")
      local sha = F.commit(repo, "one")
      local res = assert(run({ "rev-parse", "HEAD" }, repo))
      assert.is_true(res.ok)
      assert.equals(sha, vim.trim(res.stdout))
    end)

    it("starts every process offline, bounded and without a prompt", function()
      local opts = gitlog.opts("/some/clone")
      assert.is_true(opts.no_lazy_fetch)
      assert.equals(require("gitsuite.config").get().plugins.timeout_ms, opts.timeout_ms)
      assert.equals("0", opts.env.GIT_TERMINAL_PROMPT)
      assert.equals("never", opts.env.GCM_INTERACTIVE)
      assert.equals("/some/clone", opts.dir)
    end)

    it("pins git to the clone, whatever GIT_DIR the editor itself inherited", function()
      local opts = gitlog.opts("/some/clone")
      assert.equals("/some/clone/.git", opts.env.GIT_DIR)
      assert.equals("/some/clone", opts.env.GIT_WORK_TREE)

      local wanted = F.init("-pinned")
      local want_sha = F.commit(wanted, "wanted")
      local other = F.init("-other")
      F.commit(other, "other")
      local previous = vim.env.GIT_DIR
      vim.env.GIT_DIR = other .. "/.git"
      local res = run({ "rev-parse", "HEAD" }, wanted)
      vim.env.GIT_DIR = previous
      assert.equals(want_sha, vim.trim(assert(res).stdout))
    end)
  end)

  describe("log", function()
    ---@return Lib.Git.LogEntry[]|nil, string|nil
    local function read(dir, n)
      local box
      gitlog.log(dir, n, function(entries, err)
        box = { entries = entries, err = err }
      end)
      vim.wait(20000, function()
        return box ~= nil
      end, 10)
      assert.is_not_nil(box, "gitlog.log called back")
      return box.entries, box.err
    end

    it("reads the newest commits, newest first, with message and files, in one go", function()
      local repo = F.init("-log")
      F.write(repo .. "/a b.txt", "1\n")
      F.write(repo .. "/dir/ü.txt", "1\n")
      F.commit(repo, "feat!: first\n\nbody line\nBREAKING CHANGE: gone\n", 1700000100)
      F.write(repo .. "/a b.txt", "2\n")
      local second = F.commit(repo, "second", 1700000200)
      F.write(repo .. "/c.txt", "3\n")
      F.commit(repo, "third", 1700000300)

      local entries = assert(read(repo, 2))
      assert.equals(2, #entries)
      assert.equals("third", entries[1].subject)
      assert.equals(second, entries[2].sha)
      assert.equals("c.txt", entries[1].files[1].path)
      assert.equals("A", entries[1].files[1].status)
      assert.is_true(vim.tbl_contains(entries[1].refs, "HEAD -> main"))

      local all = assert(read(repo, 50))
      assert.equals(3, #all)
      assert.equals("body line\nBREAKING CHANGE: gone", all[3].body)
      local paths = vim.tbl_map(function(f)
        return f.path
      end, all[3].files)
      table.sort(paths)
      assert.same({ "a b.txt", "dir/ü.txt" }, paths)
    end)

    it("reports a directory that is not a repository", function()
      local entries, err = read(F.tmpdir("-not-a-repo"), 5)
      assert.is_nil(entries)
      assert.is_truthy(err and err ~= "")
    end)

    it("does not run when git is told the repository is somewhere else", function()
      -- `dir` goes in as the value of `-C`, never as an option of its own.
      local entries = read("--output=" .. F.tmpdir("-x") .. "/out", 5)
      assert.is_nil(entries)
    end)

    it("reads a blobless clone offline: commits, bodies and file names without blobs", function()
      local origin = F.init("-blobless-origin")
      F.git(origin, { "config", "uploadpack.allowFilter", "true" })
      F.write(origin .. "/f.txt", "1\n")
      F.commit(origin, "one", 1700000100)
      F.write(origin .. "/f.txt", "2\n")
      F.write(origin .. "/g.txt", "g\n")
      F.commit(origin, "two", 1700000200)
      F.write(origin .. "/f.txt", "3\n")
      local tip = F.commit(origin, "three", 1700000300)

      local parent = F.tmpdir("-blobless-parent")
      local clone = parent .. "/clone"
      local _, code = F.git(parent, {
        "clone",
        "-q",
        "--filter=blob:none",
        vim.uri_from_fname(origin),
        clone,
      }, { allow_fail = true })
      if code ~= 0 then
        -- No clone over file:// here; on CI that must not pass unnoticed.
        assert.is_falsy(vim.env.CI, "the blobless file:// clone failed on CI")
        return
      end
      assert.equals("blob:none", F.git(clone, { "config", "remote.origin.partialclonefilter" }))

      local entries = assert(read(clone, 10))
      assert.equals(3, #entries)
      assert.equals(tip, entries[1].sha)
      assert.equals(2, #entries[2].files, "the file names of an older commit, without its blobs")

      -- A command that needs a missing blob fails instead of fetching it into
      -- the clone ...
      local function in_pack()
        return F.git(clone, { "count-objects", "-v" }):match("in%-pack: (%d+)")
      end
      local before = in_pack()
      -- the first commit's blob is not part of a blobless clone's checkout
      local blob = F.git(origin, { "rev-parse", "HEAD~2:f.txt" })
      local missing = assert(run({ "cat-file", "blob", blob }, clone))
      assert.is_false(missing.ok)
      -- ... and leaves the object store as it was.
      assert.equals(before, in_pack())
    end)
  end)
end)
