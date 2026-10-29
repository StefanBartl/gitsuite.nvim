-- TESTS/gitsuite/dashboard_sync_spec.lua -- `gS`: bringing a repository level with its upstream in
-- whichever direction it is off (gitsuite.features.dashboard.actions.sync).
--
-- Real git on throw-away repositories under a temp folder, the remote being a bare repository
-- next to them: no network, nothing outside the temp folder is read or written. Each case builds its
-- own state (behind, ahead, diverged, ...) and checks what happened to both sides.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.

describe("gitsuite.features.dashboard.actions.sync (real git, local remote)", function()
  local actions = require("gitsuite.features.dashboard.actions")

  -- A commit needs an identity, and a user's own git config must not leak into the test.
  local ENV = {
    GIT_AUTHOR_NAME = "t",
    GIT_AUTHOR_EMAIL = "t@example.invalid",
    GIT_COMMITTER_NAME = "t",
    GIT_COMMITTER_EMAIL = "t@example.invalid",
    GIT_CONFIG_GLOBAL = vim.fn.has("win32") == 1 and "NUL" or "/dev/null",
    GIT_CONFIG_SYSTEM = vim.fn.has("win32") == 1 and "NUL" or "/dev/null",
  }

  local root, remote, a, b

  ---Runs `git -C dir ...`, fails the test when it fails, returns its trimmed stdout.
  ---@param dir string
  ---@param ... string
  ---@return string
  local function git(dir, ...)
    local args = { "git", "-C", dir, ... }
    local res = vim.system(args, { text = true, env = ENV }):wait()
    assert.equals(0, res.code, table.concat(args, " ") .. ": " .. (res.stderr or ""))
    return vim.trim(res.stdout or "")
  end

  ---Commits a new file in `dir` (a distinct file per call, so two sides never conflict).
  ---@param dir string
  ---@param name string
  local function commit(dir, name)
    local fd = assert(io.open(dir .. "/" .. name, "w"))
    fd:write(name, "\n")
    fd:close()
    git(dir, "add", name)
    git(dir, "commit", "-q", "-m", name)
  end

  ---Runs `actions.sync` on `dir` and waits for its answer.
  ---@param dir string
  ---@return boolean ok
  ---@return string|nil err
  ---@return string|nil detail What the batch summary lists as changed
  ---@return string|nil skipped Why there was nothing to work on
  local function sync(dir)
    local done, ok, err, detail, skipped = false, nil, nil, nil, nil
    actions.sync(dir, function(o, e, d, s)
      done, ok, err, detail, skipped = true, o, e, d, s
    end)
    assert.is_true(
      vim.wait(20000, function()
        return done
      end, 20),
      "sync did not answer"
    )
    return ok, err, detail, skipped
  end

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    remote = root .. "/remote.git"
    a, b = root .. "/a", root .. "/b"
    git(root, "init", "-q", "--bare", "-b", "main", "remote.git")
    git(root, "clone", "-q", "remote.git", "a")
    git(a, "checkout", "-q", "-b", "main")
    commit(a, "seed")
    git(a, "push", "-q", "-u", "origin", "main")
    git(root, "clone", "-q", "remote.git", "b")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("does nothing more than the fetch for a repository that is level", function()
    local before = git(a, "rev-parse", "HEAD")
    local ok, err, detail, skipped = sync(a)
    assert.is_true(ok, err)
    assert.is_nil(detail, "a level repository is reported as unchanged")
    assert.is_nil(skipped)
    assert.equals(before, git(a, "rev-parse", "HEAD"))
    assert.equals(before, git(remote, "rev-parse", "main"))
  end)

  it("pulls a repository that is behind", function()
    commit(b, "from-b")
    commit(b, "from-b2")
    git(b, "push", "-q")
    local ok, err, detail = sync(a)
    assert.is_true(ok, err)
    assert.equals("pulled 2 commits", detail)
    assert.equals(git(remote, "rev-parse", "main"), git(a, "rev-parse", "HEAD"))
    assert.equals(1, vim.fn.filereadable(a .. "/from-b"), "the file arrived in the working tree")
  end)

  it("pushes a repository that is ahead", function()
    commit(a, "from-a")
    local ok, err, detail = sync(a)
    assert.is_true(ok, err)
    assert.equals("pushed 1 commit", detail)
    assert.equals(git(a, "rev-parse", "HEAD"), git(remote, "rev-parse", "main"))
  end)

  it("touches neither side of a repository that diverged, and says how far", function()
    commit(b, "from-b")
    git(b, "push", "-q")
    commit(a, "from-a")
    local mine, theirs = git(a, "rev-parse", "HEAD"), git(remote, "rev-parse", "main")

    local ok, err = sync(a)
    assert.is_false(ok)
    assert.truthy((err or ""):find("diverged: 1 ahead, 1 behind", 1, true), err)
    assert.equals(mine, git(a, "rev-parse", "HEAD"), "no pull")
    assert.equals(theirs, git(remote, "rev-parse", "main"), "no push")
  end)

  it("counts a repository without an upstream as fetched, not as failed", function()
    local lone = root .. "/lone"
    git(root, "init", "-q", "-b", "main", "lone")
    commit(lone, "only")
    local ok, err, detail, skipped = sync(lone)
    assert.is_true(ok, err)
    assert.is_nil(detail)
    assert.equals("no upstream or detached HEAD", skipped, "the summary lists it as skipped")
  end)

  it("counts a detached HEAD as nothing to bring level", function()
    git(a, "checkout", "-q", "--detach")
    local ok, err = sync(a)
    assert.is_true(ok, err)
  end)

  it("reports a failed fetch and does not go on", function()
    commit(a, "from-a")
    local ahead = git(a, "rev-parse", "HEAD")
    vim.fn.delete(remote, "rf")
    local ok, err = sync(a)
    assert.is_false(ok)
    assert.truthy(err and err ~= "", "the reason is given")
    assert.equals(ahead, git(a, "rev-parse", "HEAD"))
  end)

  it("push (p/gp) reports how many commits it pushed, and nothing for a level branch", function()
    ---@param dir string
    ---@return boolean|nil ok
    ---@return string|nil err
    ---@return string|nil detail
    local function push(dir)
      local done, ok, err, detail = false, nil, nil, nil
      actions.push(dir, function(o, e, d)
        done, ok, err, detail = true, o, e, d
      end)
      assert.is_true(vim.wait(20000, function()
        return done
      end, 20))
      return ok, err, detail
    end

    local ok, err, detail = push(a)
    assert.is_true(ok, err)
    assert.is_nil(detail, "nothing to push is unchanged")
    commit(a, "p1")
    commit(a, "p2")
    ok, err, detail = push(a)
    assert.is_true(ok, err)
    assert.equals("pushed 2 commits", detail)
    assert.equals(git(a, "rev-parse", "HEAD"), git(remote, "rev-parse", "main"))
  end)

  it("push and sync count against the push destination, not the upstream (triangular)", function()
    ---@param dir string
    ---@return boolean|nil ok
    ---@return string|nil err
    ---@return string|nil detail
    local function push(dir)
      local done, ok, err, detail = false, nil, nil, nil
      actions.push(dir, function(o, e, d)
        done, ok, err, detail = true, o, e, d
      end)
      assert.is_true(vim.wait(20000, function()
        return done
      end, 20))
      return ok, err, detail
    end

    -- Upstream stays origin/main, pushes go to the fork; the fork already has both new commits.
    git(root, "init", "-q", "--bare", "-b", "main", "fork.git")
    git(a, "remote", "add", "fork", root .. "/fork.git")
    git(a, "config", "remote.pushDefault", "fork")
    commit(a, "t1")
    commit(a, "t2")
    git(a, "push", "-q", "fork", "main")
    assert.equals("2\t0", git(a, "rev-list", "--left-right", "--count", "HEAD...@{u}"))

    local ok, err, detail = push(a)
    assert.is_true(ok, err)
    assert.is_nil(detail, "the fork was level: nothing was pushed")

    ok, err, detail = sync(a)
    assert.is_true(ok, err)
    assert.is_nil(detail, "sync's push sent nothing either")

    commit(a, "t3")
    ok, err, detail = sync(a)
    assert.is_true(ok, err)
    assert.equals("pushed 1 commit", detail, "one commit went to the fork, not three")
    assert.equals(git(a, "rev-parse", "HEAD"), git(root .. "/fork.git", "rev-parse", "main"))
  end)

  it("reads the counts after the fetch, not from the last time", function()
    -- a is level when b pushes; only a fetch inside sync can show that a is now behind.
    assert.equals("0\t0", git(a, "rev-list", "--left-right", "--count", "HEAD...@{u}"))
    commit(b, "from-b")
    git(b, "push", "-q")
    assert.equals(
      "0\t0",
      git(a, "rev-list", "--left-right", "--count", "HEAD...@{u}"),
      "stale until fetched"
    )
    local ok, err = sync(a)
    assert.is_true(ok, err)
    assert.equals(git(remote, "rev-parse", "main"), git(a, "rev-parse", "HEAD"))
  end)
end)
