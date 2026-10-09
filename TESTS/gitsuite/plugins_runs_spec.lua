-- TESTS/gitsuite/plugins_runs_spec.lua -- gitsuite.features.plugins.runs (reflog
-- -> "what did the last update change") and .target (lazy's update target).
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("gitsuite.features.plugins.runs", function()
  local runs = require("gitsuite.features.plugins.runs")

  local ZERO = ("0"):rep(40)
  ---@return string a 40-digit hash made from one hex digit
  local function sha(digit)
    return digit:rep(40)
  end

  ---@return GitSuite.Plugins.ReflogEntry
  local function entry(old, new, time, kind)
    return {
      old = old,
      new = new,
      time = time,
      kind = kind or "checkout",
      message = kind or "checkout",
    }
  end

  local T0 = 1790429896
  local DAY = 86400

  describe("last_update", function()
    it("reads the reference case: install checkout, then a real update", function()
      -- clone -> (5 s) checkout of the pinned commit -> (11 days) checkout of the update
      local result = runs.last_update({
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("b"), T0 + 5),
        entry(sha("b"), sha("c"), T0 + 11 * DAY),
      }, { head = sha("c") })
      assert.equals("updated", result.state)
      assert.equals(sha("b"), result.from)
      assert.equals(sha("c"), result.to)
      assert.equals(T0 + 11 * DAY, result.time)
      assert.equals(T0, result.installed_at)
    end)

    it("does not call an install checkout an update", function()
      local result = runs.last_update({
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("b"), T0 + 5),
      }, { head = sha("b") })
      assert.equals("installed", result.state)
      assert.equals(sha("b"), result.to)
    end)

    it("treats a quick second checkout after the install as part of the install", function()
      local result = runs.last_update({
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("b"), T0 + 5),
        entry(sha("b"), sha("c"), T0 + 9),
      }, { head = sha("c") })
      assert.equals("installed", result.state)
    end)

    it("joins quick checkouts into one update from the last long-lived state", function()
      local result = runs.last_update({
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("b"), T0 + 5),
        entry(sha("b"), sha("c"), T0 + 3 * DAY),
        entry(sha("c"), sha("d"), T0 + 3 * DAY + 10),
      }, { head = sha("d") })
      assert.equals("updated", result.state)
      assert.equals(sha("b"), result.from)
      assert.equals(sha("d"), result.to)
    end)

    it(
      "reports a move back as an update from the newer state (direction comes from the log)",
      function()
        local result = runs.last_update({
          entry(ZERO, sha("a"), T0, "clone"),
          entry(sha("a"), sha("b"), T0 + 2 * DAY),
          entry(sha("b"), sha("a"), T0 + 5 * DAY),
        }, { head = sha("a") })
        assert.equals("updated", result.state)
        assert.equals(sha("b"), result.from)
        assert.equals(sha("a"), result.to)
      end
    )

    it("ignores entries that do not move HEAD", function()
      local result = runs.last_update({
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("a"), T0 + 2 * DAY),
        entry(sha("a"), sha("b"), T0 + 3 * DAY),
        entry(sha("b"), sha("b"), T0 + 4 * DAY),
      }, { head = sha("b") })
      assert.equals("updated", result.state)
      assert.equals(sha("a"), result.from)
      assert.equals(sha("b"), result.to)
    end)

    it(
      "starts from the first entry's old state when the reflog does not begin at a clone",
      function()
        local result = runs.last_update({
          entry(sha("a"), sha("b"), T0 + 2 * DAY),
        }, { head = sha("b") })
        assert.equals("updated", result.state)
        assert.equals(sha("a"), result.from)
        assert.is_nil(result.installed_at)
      end
    )

    it("does not report the user's own commits as an update", function()
      local result = runs.last_update({
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("b"), T0 + 3 * DAY, "commit"),
      }, { head = sha("b") })
      assert.equals("local_work", result.state)
    end)

    it("says so when the reflog does not end where HEAD is", function()
      local result = runs.last_update({
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("b"), T0 + 3 * DAY),
      }, { head = sha("f") })
      assert.equals("stale", result.state)
      assert.equals(sha("b"), result.reflog_head)
    end)

    it("calls A -> B -> A within the dwell time no change at all", function()
      local result = runs.last_update({
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("b"), T0 + 3 * DAY),
        entry(sha("b"), sha("a"), T0 + 3 * DAY + 20),
      }, { head = sha("a") })
      assert.equals("none", result.state)
    end)

    it("looks past a bounce for the last state that really differed", function()
      local result = runs.last_update({
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("b"), T0 + 2 * DAY),
        entry(sha("b"), sha("c"), T0 + 4 * DAY),
        entry(sha("c"), sha("b"), T0 + 4 * DAY + 20),
        entry(sha("b"), sha("c"), T0 + 4 * DAY + 40),
      }, { head = sha("c") })
      assert.equals("updated", result.state)
      assert.equals(sha("b"), result.from)
      assert.equals(sha("c"), result.to)
    end)

    it("clamps an entry from a clock gone wrong so it cannot stay the newest update", function()
      local now = T0 + 20 * DAY
      local result = runs.last_update({
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("b"), T0 + 2 * DAY),
        entry(sha("b"), sha("c"), 4000000000), -- far in the future
      }, { head = sha("c"), now = now })
      assert.equals("updated", result.state)
      assert.equals(now, result.time)
    end)

    it("has nothing to say for an empty reflog", function()
      assert.equals("none", runs.last_update({}).state)
      assert.equals("none", runs.last_update({ entry(sha("a"), sha("a"), T0) }).state)
    end)

    it("uses the file order, not the timestamps", function()
      -- the clock went backwards between the two entries: the later line wins
      local result = runs.last_update({
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("b"), T0 + 3 * DAY),
        entry(sha("b"), sha("c"), T0 + 1 * DAY),
      }, { head = sha("c") })
      assert.equals(sha("c"), result.to)
    end)

    it("honours a different dwell time", function()
      local entries = {
        entry(ZERO, sha("a"), T0, "clone"),
        entry(sha("a"), sha("b"), T0 + 60),
        entry(sha("b"), sha("c"), T0 + 100),
      }
      assert.equals("updated", runs.last_update(entries, { dwell_s = 30 }).state)
      assert.equals("installed", runs.last_update(entries, { dwell_s = 120 }).state)
    end)
  end)

  describe("latest_run", function()
    it("groups the newest updates that follow each other closely", function()
      local run = assert(runs.latest_run({ 100, 130, 5000, 5040, 5200 }, 300))
      assert.same({ 3, 4, 5 }, run.members)
      assert.equals(2, run.older)
      assert.equals(5000, run.first_time)
      assert.equals(5200, run.last_time)
    end)

    it("chains: each gap only needs to be within the window", function()
      local run = assert(runs.latest_run({ 0, 250, 500, 750 }, 300))
      assert.same({ 1, 2, 3, 4 }, run.members)
      assert.equals(0, run.older)
    end)

    it("splits at a gap larger than the window", function()
      local run = assert(runs.latest_run({ 0, 100, 1000, 1100 }, 300))
      assert.same({ 3, 4 }, run.members)
      assert.equals(2, run.older)
    end)

    it("takes unsorted input and keeps indices into it", function()
      local run = assert(runs.latest_run({ 5200, 100, 5000 }, 300))
      assert.same({ 3, 1 }, run.members)
    end)

    it("is a run of one for a single update, and nil for none", function()
      assert.same({ 1 }, assert(runs.latest_run({ 42 })).members)
      assert.is_nil(runs.latest_run({}))
    end)
  end)

  describe("direction", function()
    it("tells forward, rollback, diverged and same from the two sides of the log", function()
      assert.equals("forward", runs.direction(5, 0))
      assert.equals("rollback", runs.direction(0, 3))
      assert.equals("diverged", runs.direction(2, 3))
      assert.equals("same", runs.direction(0, 0))
    end)
  end)
end)

describe("gitsuite.features.plugins.target", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local target

  before_each(function()
    package.loaded["gitsuite.features.plugins.target"] = nil
    package.loaded["gitsuite.features.plugins.gitfs"] = nil
    target = require("gitsuite.features.plugins.target")
  end)

  after_each(function()
    F.cleanup()
  end)

  ---A repository standing in for a lazy clone: a long `main` (the remote branch
  ---far ahead), tags on early commits, `origin/HEAD` -> `origin/main`.
  ---@return string dir, table commits
  local function clone_like()
    local repo = F.init("-target")
    -- one process: six commits, lightweight tags on 1-4, an annotated one on 5,
    -- the remote branch at the tip
    local tags = { { "v0.9.0", 1 }, { "v1.0.0", 2 }, { "v1.1.0", 3 }, { "v2.0.0-rc.1", 4 } }
    local extra = {}
    for _, t in ipairs(tags) do
      extra[#extra + 1] = ("reset refs/tags/%s\nfrom :%d\n\n"):format(t[1], t[2])
    end
    -- (a `tag` takes no blank line after its message, unlike `commit`/`reset`)
    extra[#extra + 1] = "tag v2.0.0\nfrom :5\ntagger T <t@example.invalid> 1700000999 +0000\n"
      .. F.data("two")
    extra[#extra + 1] = "reset refs/remotes/origin/main\nfrom :6\n\n"
    local c = F.history(repo, 6, { extra = table.concat(extra) })
    F.write(repo .. "/.git/refs/remotes/origin/HEAD", "ref: refs/remotes/origin/main\n")
    F.write(repo .. "/.git/HEAD", c[2] .. "\n") -- detached, like lazy leaves it
    return repo, c
  end

  local function ref(dir, spec, extra)
    return vim.tbl_extend("force", {
      name = "p",
      dir = dir,
      managed_by = "lazy",
      is_local = false,
      spec = vim.tbl_extend("force", { pin = false }, spec or {}),
    }, extra or {})
  end

  it("follows the default branch when the spec says nothing", function()
    local dir, c = clone_like()
    local got = target.resolve(ref(dir))
    assert.equals("branch", got.tier)
    assert.equals(c[6], got.sha)
    assert.equals(c[6], got.rev)
    assert.equals("main", got.branch)
  end)

  it(
    "takes the highest matching tag for a version spec, not the branch (the 315-commit bug)",
    function()
      local dir, c = clone_like()
      local got = target.resolve(ref(dir, { version = "1.*" }))
      assert.equals("version", got.tier)
      assert.equals("v1.1.0", got.tag)
      assert.equals("refs/tags/v1.1.0^{commit}", got.rev)
      assert.equals(c[3], got.sha)
      assert.is_not_equal(c[6], got.sha, "must never be the remote branch tip")
    end
  )

  it(
    "says unknown, not the branch tip, when the tag list is incomplete and nothing matches",
    function()
      local dir = clone_like()
      local gitfs = require("gitsuite.features.plugins.gitfs")
      local f = assert(io.open(dir .. "/.git/packed-refs", "wb"))
      f:write(("%s refs/tags/v9.0.0\n"):format(("a"):rep(40)):rep(5))
      f:close()
      local original = gitfs.MAX_PACKED
      gitfs.MAX_PACKED = 64
      local got = target.resolve(ref(dir, { version = "7.*" }))
      gitfs.MAX_PACKED = original
      assert.equals("unknown", got.tier)
      assert.is_truthy(got.reason:find("tag list", 1, true))
    end
  )

  it("does not pick a pre-release for a version range", function()
    local dir = clone_like()
    local got = target.resolve(ref(dir, { version = "*" }))
    assert.equals("v2.0.0", got.tag)
  end)

  it("applies lazy's defaults.version only when the spec has neither version nor branch", function()
    local dir, c = clone_like()
    local opts = { defaults_version = "1.*" }
    assert.equals("v1.1.0", target.resolve(ref(dir), opts).tag)
    assert.equals("branch", target.resolve(ref(dir, { branch = "main" }), opts).tier)
    assert.equals("branch", target.resolve(ref(dir, { version = false }), opts).tier)
    assert.equals(c[6], target.resolve(ref(dir, { version = false }), opts).sha)
  end)

  it("falls through to the branch when no tag fits the range", function()
    local dir, c = clone_like()
    local got = target.resolve(ref(dir, { version = "7.*" }))
    assert.equals("branch", got.tier)
    assert.equals(c[6], got.sha)
  end)

  it("honours tag and commit specs before anything else", function()
    local dir, c = clone_like()
    local by_tag = target.resolve(ref(dir, { tag = "v1.0.0", version = "2.*", branch = "x" }))
    assert.equals("tag", by_tag.tier)
    assert.equals(c[2], by_tag.sha)

    local by_commit = target.resolve(ref(dir, { commit = c[4], tag = "v1.0.0" }))
    assert.equals("commit", by_commit.tier)
    assert.equals(c[4], by_commit.rev)

    local short = target.resolve(ref(dir, { commit = c[4]:sub(1, 8) }))
    assert.equals(c[4]:sub(1, 8), short.rev)
    assert.is_nil(short.sha, "a short hash is not resolved without git")
  end)

  it("is honest about an annotated tag that only git can peel", function()
    local dir, c = clone_like()
    local loose = target.resolve(ref(dir, { tag = "v2.0.0" }))
    assert.is_false(loose.certain)
    assert.equals("refs/tags/v2.0.0^{commit}", loose.rev) -- git does the peeling

    F.git(dir, { "pack-refs", "--all", "--prune" })
    local packed = target.resolve(ref(dir, { tag = "v2.0.0" }))
    assert.is_true(packed.certain)
    assert.equals(c[5], packed.sha)
  end)

  it("reads an empty version string as lazy does: any version", function()
    local dir = clone_like()
    local got = target.resolve(ref(dir, { version = "" }))
    assert.equals("version", got.tier)
    assert.equals("v2.0.0", got.tag)
  end)

  it("lets a dir-mode plugin on a detached HEAD follow its spec's branch", function()
    local dir, c = clone_like() -- HEAD is detached here
    local got = target.resolve(ref(dir, { branch = "main" }, { is_local = true }))
    assert.equals("branch", got.tier)
    assert.equals(c[6], got.sha)
  end)

  it("does not move a pinned plugin", function()
    local dir = clone_like()
    local got = target.resolve(ref(dir, { pin = true, version = "1.*" }))
    assert.equals("pin", got.tier)
    assert.is_nil(got.rev)
  end)

  it("answers 'unknown' instead of guessing", function()
    local dir = clone_like()
    for _, case in ipairs({
      { { tag = "v9.9.9" }, "not in the clone" },
      { { tag = "../../x" }, "not a usable tag" },
      { { commit = "zzzz" }, "not a hash" },
      { { version = true }, "not supported" },
      { { branch = "gone" }, "not known locally" },
    }) do
      local got = target.resolve(ref(dir, case[1]))
      assert.equals("unknown", got.tier, vim.inspect(case[1]))
      assert.is_truthy(got.reason:find(case[2], 1, true), got.reason)
      assert.is_nil(got.rev)
    end
  end)

  it("never falls back to origin/HEAD when the branch cannot be told", function()
    local dir, c = clone_like()
    -- no origin/HEAD, detached HEAD: there is no branch to follow
    vim.fn.delete(dir .. "/.git/refs/remotes/origin/HEAD")
    local got = target.resolve(ref(dir))
    assert.equals("unknown", got.tier)
    assert.is_nil(got.sha)
    assert.is_not_equal(c[6], got.sha)
  end)

  it("reads a dir-mode plugin's own branch", function()
    local dir, c = clone_like()
    F.write(dir .. "/.git/HEAD", "ref: refs/heads/main\n")
    local got = target.resolve(ref(dir, { version = "1.*" }, { is_local = true }))
    assert.equals("branch", got.tier)
    assert.equals("main", got.branch)
    assert.equals(c[6], got.sha, "origin/main is ahead of the local branch")
  end)

  it("cannot target a directory without a .git directory", function()
    local dir = F.tmpdir("-no-git")
    assert.equals("unknown", target.resolve(ref(dir)).tier)
  end)
end)
