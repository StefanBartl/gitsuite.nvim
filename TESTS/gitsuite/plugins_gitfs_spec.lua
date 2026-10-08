-- TESTS/gitsuite/plugins_gitfs_spec.lua -- gitsuite.features.plugins.gitfs (the
-- process-free reader of a clone's .git directory) and .semver (lazy's version
-- ranges), against real throwaway repositories.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("gitsuite.features.plugins.gitfs", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local gitfs

  before_each(function()
    package.loaded["gitsuite.features.plugins.gitfs"] = nil
    gitfs = require("gitsuite.features.plugins.gitfs")
  end)

  after_each(function()
    F.cleanup()
  end)

  ---A repository with two commits, `a` then `b` (built in one process).
  local function two_commits(suffix)
    local repo = F.init(suffix)
    local shas = F.history(repo, 2)
    return repo, shas[1], shas[2]
  end

  ---The same through real commands, which (unlike fast-import) write a reflog.
  local function real_two_commits(suffix)
    local repo = F.init(suffix)
    F.write(repo .. "/f.txt", "1\n")
    local a = F.commit(repo, "a", 1700000100)
    F.write(repo .. "/f.txt", "2\n")
    local b = F.commit(repo, "b", 1700000200)
    return repo, a, b
  end

  describe("hashes and ref names", function()
    it("accepts 40 and 64 hex digits and nothing else", function()
      assert.is_true(gitfs.valid_sha(("a"):rep(40)))
      assert.is_true(gitfs.valid_sha(("0"):rep(64)))
      assert.is_false(gitfs.valid_sha(("a"):rep(39)))
      assert.is_false(gitfs.valid_sha(("g"):rep(40)))
      assert.is_false(gitfs.valid_sha(nil))
    end)

    it("refuses ref names that could leave .git/", function()
      assert.is_true(gitfs.valid_refname("refs/heads/feature/x-1.2"))
      -- legal for git, and no shell is involved anywhere
      assert.is_true(gitfs.valid_refname("refs/heads/$(x)"))
      for _, bad in ipairs({
        "HEAD",
        "refs/heads/../../x",
        "refs//x",
        "refs/heads/x/",
        "refs/heads/x.lock",
        "refs/heads/a b",
        "/etc/passwd",
        ("refs/" .. ("a"):rep(300)),
      }) do
        assert.is_false(gitfs.valid_refname(bad), bad)
      end
    end)
  end)

  describe("head and refs", function()
    it("reads a branch and its commit", function()
      local repo, _, b = two_commits("-head")
      local head = assert(gitfs.head(repo))
      assert.equals("refs/heads/main", head.ref)
      assert.equals("main", head.branch)
      assert.equals(b, head.sha)
      assert.is_false(head.detached)
      assert.is_true(gitfs.is_clone(repo))
    end)

    it("reads a detached HEAD", function()
      local repo, a = two_commits("-detached")
      F.git(repo, { "checkout", "-q", "--detach", a })
      local head = assert(gitfs.head(repo))
      assert.is_true(head.detached)
      assert.equals(a, head.sha)
      assert.is_nil(head.branch)
    end)

    it("reads an unborn branch as a HEAD without a commit", function()
      local repo = F.init("-unborn")
      local head = assert(gitfs.head(repo))
      assert.equals("main", head.branch)
      assert.is_nil(head.sha)
    end)

    it("finds a ref loose and, after packing, in packed-refs", function()
      local repo, a, b = two_commits("-packed")
      assert.equals(b, gitfs.ref(repo, "refs/heads/main"))
      F.git(repo, { "branch", "side", a })
      F.git(repo, { "pack-refs", "--all", "--prune" })
      assert.equals(b, gitfs.ref(repo, "refs/heads/main"))
      assert.equals(a, gitfs.ref(repo, "refs/heads/side"))
      assert.is_nil(gitfs.ref(repo, "refs/heads/nope"))
    end)

    it("follows a symbolic ref such as origin/HEAD", function()
      local repo, _, b = two_commits("-symref")
      F.git(repo, { "update-ref", "refs/remotes/origin/main", b })
      F.git(repo, { "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" })
      assert.equals("refs/remotes/origin/main", gitfs.symref(repo, "refs/remotes/origin/HEAD"))
      assert.equals(b, gitfs.ref(repo, "refs/remotes/origin/HEAD"))
      assert.is_nil(gitfs.symref(repo, "refs/heads/main"))
    end)

    it("does not follow a HEAD that points outside .git", function()
      local repo = two_commits("-evil-head")
      F.write(repo .. "/.git/HEAD", "ref: refs/heads/../../outside\n")
      local head, err = gitfs.head(repo)
      assert.is_nil(head)
      assert.is_truthy(err)
    end)

    it("refuses an oversized or non-regular HEAD", function()
      local repo = two_commits("-big-head")
      F.write(repo .. "/.git/HEAD", ("x"):rep(gitfs.MAX_SMALL + 1))
      assert.is_nil((gitfs.head(repo)))
      vim.fn.delete(repo .. "/.git/HEAD")
      vim.fn.mkdir(repo .. "/.git/HEAD", "p")
      assert.is_nil((gitfs.head(repo)))
    end)

    it("does not treat a .git file (worktree/submodule) as a clone", function()
      local dir = F.tmpdir("-wt")
      F.write(dir .. "/.git", "gitdir: /elsewhere\n")
      assert.is_false(gitfs.is_clone(dir))
    end)
  end)

  describe("tags", function()
    it("lists loose and packed tags", function()
      local repo, a = two_commits("-tags")
      F.git(repo, { "tag", "v1.0.0", a })
      F.git(repo, { "tag", "-a", "-m", "release", "v2.0.0" })
      F.git(repo, { "tag", "pre/1" })
      assert.same({ "pre/1", "v1.0.0", "v2.0.0" }, gitfs.tag_names(repo))
      F.git(repo, { "pack-refs", "--all", "--prune" })
      assert.same({ "pre/1", "v1.0.0", "v2.0.0" }, gitfs.tag_names(repo))
    end)

    it("resolves a lightweight tag to its commit and an annotated one honestly", function()
      local repo, a, b = two_commits("-tag-commit")
      F.git(repo, { "tag", "light", a })
      F.git(repo, { "tag", "-a", "-m", "m", "note" })
      local light, light_certain = gitfs.tag_commit(repo, "light")
      assert.equals(a, light)
      assert.is_false(light_certain, "a loose tag may be an object: not certain")

      -- loose annotated: the file holds the tag object, not the commit
      local note = gitfs.tag_commit(repo, "note")
      assert.is_not_equal(b, note)

      -- packed: git records the peeled commit
      F.git(repo, { "pack-refs", "--all", "--prune" })
      local packed, certain = gitfs.tag_commit(repo, "note")
      assert.equals(b, packed)
      assert.is_true(certain)
      assert.equals(a, (gitfs.tag_commit(repo, "light")))
    end)

    it("returns nothing for a tag that is not there or has an unsafe name", function()
      local repo = two_commits("-tag-none")
      assert.is_nil((gitfs.tag_commit(repo, "nope")))
      assert.is_nil((gitfs.tag_commit(repo, "../../x")))
    end)

    it("does not hand a rejected ref line's peeled hash to the tag before it", function()
      local repo, a, b = two_commits("-packed-misparse")
      F.write(
        repo .. "/.git/packed-refs",
        table.concat({
          "# pack-refs with: peeled fully-peeled sorted ",
          a .. " refs/tags/v1.0",
          "^" .. a,
          -- a name outside the accepted characters, with a peeled line of its own
          b .. " refs/tags/v1.0=beta",
          "^" .. b,
          "",
        }, "\n")
      )
      local sha, certain = gitfs.tag_commit(repo, "v1.0")
      assert.equals(a, sha, "the rejected line's ^peeled must not overwrite v1.0's")
      assert.is_true(certain)
    end)

    it("re-reads packed-refs when the file changes", function()
      local repo, a = two_commits("-packed-cache")
      F.git(repo, { "tag", "v1", a })
      F.git(repo, { "pack-refs", "--all", "--prune" })
      assert.same({ "v1" }, gitfs.tag_names(repo))
      F.git(repo, { "tag", "v2", a })
      F.git(repo, { "pack-refs", "--all", "--prune" })
      assert.same({ "v1", "v2" }, gitfs.tag_names(repo))
    end)
  end)

  describe("reflog", function()
    it("reads HEAD movements in file order with their kind", function()
      local repo, a, b = real_two_commits("-reflog")
      F.git(repo, { "checkout", "-q", "--detach", a })
      F.git(repo, { "checkout", "-q", "main" })
      local entries = assert(gitfs.reflog(repo))
      local kinds = vim.tbl_map(function(e)
        return e.kind
      end, entries)
      assert.same({ "commit", "commit", "checkout", "checkout" }, kinds)
      assert.is_true(gitfs.is_zero(entries[1].old))
      assert.equals(a, entries[1].new)
      assert.equals(b, entries[2].new)
      assert.equals(a, entries[3].new)
      assert.equals(b, entries[4].new)
      assert.equals(1700000100, entries[1].time)
      assert.is_truthy(entries[3].message:find("moving from", 1, true))
    end)

    it("reads a reflog written the way a clone writes it", function()
      local origin, _, b = two_commits("-clone-origin")
      F.git(origin, { "config", "uploadpack.allowFilter", "true" })
      local parent = F.tmpdir("-clone-parent")
      F.git(parent, { "clone", "-q", vim.uri_from_fname(origin), "c" }, { allow_fail = true })
      local clone = parent .. "/c"
      if not gitfs.is_clone(clone) then return end
      local entries = assert(gitfs.reflog(clone))
      assert.equals("clone", entries[1].kind)
      assert.is_true(gitfs.is_zero(entries[1].old))
      assert.equals(b, entries[1].new)
    end)

    it("clamps a time no clock could have written, so JSON can hold it", function()
      local repo = two_commits("-clamp-time")
      local zero, sha = ("0"):rep(40), ("a"):rep(40)
      F.write(repo .. "/.git/logs/HEAD", table.concat({
        ("%s %s N <n@x> 9999999999 +0000\tcheckout: a"):format(zero, sha),
        ("%s %s N <n@x> %s +0000\tcheckout: b"):format(sha, ("b"):rep(40), ("9"):rep(400)),
      }, "\n") .. "\n")
      local entries = assert(gitfs.reflog(repo))
      assert.equals(2, #entries)
      for _, e in ipairs(entries) do
        assert.equals(gitfs.MAX_TIME, e.time)
        assert.is_true(pcall(vim.json.encode, { time = e.time }))
      end
    end)

    it("has no reflog when the file is missing", function()
      local repo = two_commits("-no-reflog")
      vim.fn.delete(repo .. "/.git/logs", "rf")
      assert.is_nil(gitfs.reflog(repo))
    end)

    it("skips lines it cannot read and reads a too-large file from its tail", function()
      local repo = two_commits("-tail")
      local sha = ("a"):rep(40)
      local zero = ("0"):rep(40)
      local lines = {}
      for i = 1, 40 do
        lines[#lines + 1] = ("%s %s N <n@x> %d +0000\tcheckout: moving %d"):format(
          zero,
          sha,
          1700000000 + i,
          i
        )
      end
      lines[#lines + 1] = "garbage that is not a reflog line"
      F.write(repo .. "/.git/logs/HEAD", table.concat(lines, "\n") .. "\n")
      local original = gitfs.MAX_REFLOG
      gitfs.MAX_REFLOG = 500
      local entries = assert(gitfs.reflog(repo))
      gitfs.MAX_REFLOG = original
      assert.is_true(#entries < 40 and #entries > 0)
      -- the newest end survived, and no half line was parsed
      assert.equals(1700000040, entries[#entries].time)
      for _, e in ipairs(entries) do
        assert.is_true(gitfs.valid_sha(e.new))
      end
    end)
  end)

  describe("fetch time and lock", function()
    it("counts FETCH_HEAD only when it has content", function()
      local repo = two_commits("-fetch-head")
      assert.is_nil(gitfs.fetch_time(repo))
      F.write(repo .. "/.git/FETCH_HEAD", "")
      assert.is_nil(gitfs.fetch_time(repo), "a failed fetch leaves an empty file")
      F.write(repo .. "/.git/FETCH_HEAD", ("a"):rep(40) .. "\t\tbranch 'main' of x\n")
      assert.is_number(gitfs.fetch_time(repo))
    end)

    it("notices index.lock", function()
      local repo = two_commits("-lock")
      assert.is_false(gitfs.index_locked(repo))
      F.write(repo .. "/.git/index.lock", "")
      assert.is_true(gitfs.index_locked(repo))
    end)
  end)

  it("reads 50 clones' state quickly (no process)", function()
    local repo, a = two_commits("-speed")
    F.git(repo, { "tag", "v1", a })
    local started = vim.uv.hrtime()
    for _ = 1, 50 do
      gitfs.head(repo)
      gitfs.reflog(repo)
      gitfs.tag_names(repo)
      gitfs.ref(repo, "refs/heads/main")
      gitfs.fetch_time(repo)
      gitfs.index_locked(repo)
    end
    local ms = (vim.uv.hrtime() - started) / 1e6
    -- budget from the task: 50 clones under 200 ms; generous here for slow CI
    assert.is_true(ms < 1000, ("50 clones took %.0f ms"):format(ms))
  end)
end)

describe("gitsuite.features.plugins.semver (lazy's version ranges)", function()
  local semver = require("gitsuite.features.plugins.semver")

  ---@return string[] the tags of `tags` the range picks, highest first
  local function pick(spec, tags)
    local range = assert(semver.range(spec))
    local list = {}
    for _, tag in ipairs(tags) do
      local v = semver.version(tag)
      if v and semver.matches(range, v) then
        v.tag = tag
        list[#list + 1] = v
      end
    end
    local best = semver.last(list)
    return best and best.tag or nil
  end

  local TAGS =
    { "v0.9.0", "v1.0.0", "v1.5.0", "v1.6.0-rc.1", "v2.0.0-rc.1", "v2.0.0", "nightly", "stable" }

  it("parses tags and refuses what is not a version", function()
    local v = assert(semver.version("v1.2.3-rc.1+b5"))
    assert.same({ 1, 2, 3 }, { v[1], v[2], v[3] })
    assert.equals("rc.1", v.prerelease)
    assert.same(
      { 1, 2, 0 },
      { semver.version("1.2")[1], semver.version("1.2")[2], semver.version("1.2")[3] }
    )
    assert.is_nil(semver.version("nightly"))
    assert.is_nil(semver.version(nil))
  end)

  it("orders versions, a pre-release below its release", function()
    local function v(s)
      return assert(semver.version(s))
    end
    assert.is_true(semver.lt(v("1.0.0"), v("1.0.1")))
    assert.is_true(semver.lt(v("1.9.0"), v("1.10.0")))
    assert.is_true(semver.lt(v("2.0.0-rc.1"), v("2.0.0")))
    assert.is_false(semver.lt(v("2.0.0"), v("2.0.0-rc.1")))
    assert.is_true(semver.eq(v("v1.2.3"), v("1.2.3")))
  end)

  it("picks what lazy picks for the usual specs", function()
    assert.equals("v1.5.0", pick("1.*", TAGS))
    assert.equals("v1.5.0", pick("^1.0.0", TAGS))
    assert.equals("v1.5.0", pick("~1", TAGS))
    assert.equals("v2.0.0", pick(">=1.0.0", TAGS))
    assert.equals("v2.0.0", pick("*", TAGS))
    assert.equals("v1.0.0", pick("~1.0", TAGS))
    assert.equals("v1.0.0", pick("1.0.0", TAGS))
  end)

  it("never selects a pre-release for a range that has none", function()
    -- `vim.version.range("1.*")` would; lazy's matching does not.
    assert.is_not_equal("v2.0.0-rc.1", pick("*", TAGS))
    assert.is_not_equal("v1.6.0-rc.1", pick("1.*", TAGS))
    assert.equals("v2.0.0-rc.1", pick("2.0.0-rc.1", TAGS))
  end)

  it("returns nothing when no tag fits, and nil for an unparseable range", function()
    assert.is_nil(pick("3.*", TAGS))
    assert.is_nil(semver.range("not a range"))
    assert.is_nil(semver.range(false))
  end)

  it("reads hyphen ranges", function()
    assert.equals("v1.5.0", pick("1.0.0 - 1.9.9", TAGS))
  end)
end)
