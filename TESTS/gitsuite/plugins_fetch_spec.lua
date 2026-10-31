-- TESTS/gitsuite/plugins_fetch_spec.lua -- `:Git plugins report --mode=pending --fetch`.
-- Every remote is a local bare repository reached through `file://`: no network.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local F = dofile(dir_of_spec .. "plugins_fixture.lua")()

describe("gitsuite.features.plugins report --fetch", function()
  local plugins, fetch, gitlog, state
  local root, store_path, original_state_path

  ---`file://` URL of a local path (`file:///C:/...` on Windows).
  local function url_of(path)
    path = path:gsub("\\", "/")
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return "file://" .. path
  end

  ---A bare upstream with `n` commits on main, and a work repository pushing to it.
  ---@return string bare
  ---@return string work
  local function upstream(n)
    local work = F.init("-work")
    F.history(work, n)
    F.git(work, { "reset", "-q", "--hard", "main" })
    local bare = F.tmpdir("-bare")
    F.git(bare, { "init", "-q", "--bare", "-b", "main" })
    F.git(work, { "push", "-q", url_of(bare), "main" })
    return bare, work
  end

  ---A clone of `bare` below `root`, named `name`.
  local function clone_of(bare, name)
    F.git(root, { "clone", "-q", url_of(bare), name })
    return root .. "/" .. name
  end

  ---One more commit upstream (made in `work`, pushed to `bare`).
  local function advance(bare, work, subject)
    F.write(work .. "/f.txt", subject .. "\n")
    F.commit(work, subject, 1800000000)
    F.git(work, { "push", "-q", url_of(bare), "main" })
  end

  local function by_name(report)
    local map = {}
    for _, entry in ipairs(report.plugins) do
      map[entry.name] = entry
    end
    return map
  end

  ---Run `plugins.report` and wait for its `on_done`.
  local function report(opts)
    local box
    opts.on_done = function(r, err)
      box = { report = r, err = err }
    end
    opts.out = opts.out or "clipboard"
    plugins.report(opts)
    vim.wait(30000, function()
      return box ~= nil
    end, 10)
    assert.is_not_nil(box, "report called back")
    return box.report, box.err
  end

  ---Run `fn` with `package.loaded[name]` replaced.
  local function with_module(name, value, fn)
    local original = package.loaded[name]
    package.loaded[name] = value
    local ok, err = pcall(fn)
    package.loaded[name] = original
    if not ok then error(err, 0) end
  end

  before_each(function()
    for _, name in ipairs({
      "gitsuite.features.plugins",
      "gitsuite.features.plugins.fetch",
      "gitsuite.features.plugins.report",
      "gitsuite.features.plugins.state",
      "gitsuite.features.plugins.gitlog",
    }) do
      package.loaded[name] = nil
    end
    root = F.tmpdir("-fetch-clones")
    require("gitsuite.config").setup({ plugins = { roots = { root }, sources = { "clones" } } })
    state = require("gitsuite.features.plugins.state")
    gitlog = require("gitsuite.features.plugins.gitlog")
    fetch = require("gitsuite.features.plugins.fetch")
    plugins = require("gitsuite.features.plugins")
    store_path = F.tmpdir("-fetch-store") .. "/plugins_reports.json"
    original_state_path = state.path
    state.path = function()
      return store_path
    end
  end)

  after_each(function()
    state.path = original_state_path
    F.cleanup()
  end)

  it("fetches first, then reports what is new upstream and how old the remote state is", function()
    local bare, work = upstream(2)
    local dir = clone_of(bare, "alpha")
    clone_of(bare, "beta")
    advance(bare, work, "feat: new upstream commit")

    local r, err = report({ mode = "pending", fetch = true, yes = true })
    assert.is_nil(err)
    local by = by_name(r)
    assert.equals("forward", by.alpha.status)
    assert.same(
      { "feat: new upstream commit" },
      vim.tbl_map(function(c)
        return c.subject
      end, by.alpha.commits)
    )
    assert.equals(2, r.fetched.clones)
    assert.equals(2, r.fetched.fetched)
    assert.equals(2, r.fetched.changed)
    assert.same({}, r.fetched.failed)
    assert.is_number(by.alpha.fetched_at, "FETCH_HEAD is fresh after the fetch")
    assert.equals(2, r.fetch.known)
    assert.is_true(vim.uv.fs_stat(dir .. "/.git/FETCH_HEAD").size > 0)

    -- HEAD and the work tree did not move: only the remote-tracking ref did
    assert.equals(F.git(bare, { "rev-parse", "main~1" }), F.git(dir, { "rev-parse", "HEAD" }))

    -- the fetch result is part of the stored report and of its text
    local stored = state.load(store_path).reports[1]
    assert.equals(2, stored.fetched.fetched)
    local text = table.concat(require("gitsuite.features.plugins.markdown").render(stored), "\n")
    assert.is_truthy(text:find("Fetched for this report", 1, true))
  end)

  it("goes on past a clone whose remote is gone, and never counts it as fetched", function()
    local bare, work = upstream(2)
    clone_of(bare, "good")
    local broken = clone_of(bare, "broken")
    -- a successful fetch first: FETCH_HEAD is non-empty before the failing one
    F.git(broken, { "fetch", "-q" })
    assert.is_true(vim.uv.fs_stat(broken .. "/.git/FETCH_HEAD").size > 0)
    F.git(broken, { "remote", "set-url", "origin", url_of(root .. "/does-not-exist") })
    advance(bare, work, "fix: upstream moved")

    local r = report({ mode = "pending", fetch = true, yes = true })
    local by = by_name(r)
    assert.equals(1, r.fetched.fetched)
    assert.equals(1, #r.fetched.failed)
    assert.equals("broken", r.fetched.failed[1].name)
    assert.equals("forward", by.good.status, "the other clone was fetched and reported")
    assert.equals(
      0,
      vim.uv.fs_stat(broken .. "/.git/FETCH_HEAD").size,
      "a failed fetch empties FETCH_HEAD"
    )
    assert.equals(1, r.fetch.known, "the failed clone is not a recorded fetch")
    local text = table.concat(require("gitsuite.features.plugins.markdown").render(r), "\n")
    assert.is_truthy(text:find("failed broken", 1, true))
  end)

  it("skips a clone whose index.lock is held", function()
    local bare = upstream(1)
    local dir = clone_of(bare, "locked")
    clone_of(bare, "free")
    F.write(dir .. "/.git/index.lock", "")
    local r = report({ mode = "pending", fetch = true, yes = true })
    assert.equals(1, #r.fetched.skipped)
    assert.equals("locked", r.fetched.skipped[1].name)
    assert.is_truthy(r.fetched.skipped[1].reason:find("index.lock", 1, true))
    assert.equals(1, r.fetched.fetched)
  end)

  it("refuses while lazy.nvim is working on plugins", function()
    local bare = upstream(1)
    clone_of(bare, "one")
    local calls = 0
    local original = gitlog.fetch
    gitlog.fetch = function(...)
      calls = calls + 1
      return original(...)
    end
    with_module(
      "lazy.core.config",
      { plugins = { x = { name = "x", _ = { working = true } } } },
      function()
        local r, err = report({ mode = "pending", fetch = true, yes = true })
        assert.is_nil(r)
        assert.is_truthy(err:find("lazy.nvim is working", 1, true))
      end
    )
    gitlog.fetch = original
    assert.equals(0, calls)
  end)

  it("is only for --mode=pending and not with --last", function()
    local _, err = report({ mode = "updated", fetch = true, yes = true })
    assert.is_truthy(err:find("--mode=pending", 1, true))
    _, err = report({ mode = "pending", last = true, fetch = true })
    assert.is_truthy(err:find("--last", 1, true))
  end)

  it("asks from plugins.fetch_confirm clones on; no fetch when the answer is no", function()
    local bare = upstream(1)
    clone_of(bare, "a")
    clone_of(bare, "b")
    require("gitsuite.config").setup({
      plugins = { roots = { root }, sources = { "clones" }, fetch_confirm = 2 },
    })
    local calls, asked = 0, nil
    local original = gitlog.fetch
    gitlog.fetch = function(...)
      calls = calls + 1
      return original(...)
    end
    with_module("ui.kit", {
      confirm = function(o)
        asked = o.question
        o.on_answer(false)
        return {} -- a dialog that opened (nil would mean the float could not be created)
      end,
    }, function()
      local r, err = report({ mode = "pending", fetch = true })
      assert.is_nil(r)
      assert.equals("cancelled", err)
    end)
    assert.is_truthy(asked:find("Fetch 2 plugin clones", 1, true))
    assert.equals(0, calls)

    -- below the threshold nothing is asked
    require("gitsuite.config").setup({
      plugins = { roots = { root }, sources = { "clones" }, fetch_confirm = 3 },
    })
    asked = nil
    with_module("ui.kit", {
      confirm = function(o)
        asked = o.question
        o.on_answer(false)
        return {} -- a dialog that opened (nil would mean the float could not be created)
      end,
    }, function()
      local r = report({ mode = "pending", fetch = true })
      assert.is_not_nil(r)
    end)
    gitlog.fetch = original
    assert.is_nil(asked)
    assert.equals(2, calls)
  end)

  it("never prompts, keeps the timeout and runs fetch_jobs at a time", function()
    local git = require("lib.nvim.git")
    local seen, in_flight, peak = {}, 0, 0
    local original = git.fetch_async
    git.fetch_async = function(opts, on_done)
      seen[#seen + 1] = opts
      in_flight = in_flight + 1
      peak = math.max(peak, in_flight)
      vim.defer_fn(function()
        in_flight = in_flight - 1
        on_done(true, nil, false)
      end, 50)
      return { stop = function() end }
    end
    local bare = upstream(1)
    for _, name in ipairs({ "p1", "p2", "p3", "p4", "p5" }) do
      clone_of(bare, name)
    end
    local ok, err = pcall(report, { mode = "pending", fetch = true, yes = true })
    git.fetch_async = original
    assert.is_true(ok, err)
    assert.equals(5, #seen)
    assert.equals(2, peak, "plugins.fetch_jobs = 2")
    for _, opts in ipairs(seen) do
      assert.equals("0", opts.env.GIT_TERMINAL_PROMPT)
      assert.equals("never", opts.env.GCM_INTERACTIVE)
      assert.equals(60000, opts.timeout_ms)
      assert.is_false(opts.no_lazy_fetch, "the transport is not blocked for the fetch itself")
    end
  end)

  it("kills a hung fetch and its children at the deadline @spawn", function()
    local bare, work = upstream(1)
    clone_of(bare, "fast")
    local slow = clone_of(bare, "slow")
    advance(bare, work, "feat: more")
    -- the transport helper sleeps, then leaves a marker: a surviving process tree
    -- would write it after the deadline. The deadline leaves the fast clone's fetch
    -- room under load (it took ~3 s on a busy machine), the helper sleeps far longer.
    local deadline_ms, helper_s = 5000, 12
    local marker = (F.tmpdir("-marker") .. "/survived"):gsub("\\", "/")
    F.git(slow, {
      "config",
      "remote.origin.uploadpack",
      ("sleep %d; echo x > '%s'; git-upload-pack"):format(helper_s, marker),
    })
    require("gitsuite.config").setup({
      plugins = { roots = { root }, sources = { "clones" }, fetch_timeout_ms = deadline_ms },
    })
    local started = vim.uv.hrtime()
    local r = report({ mode = "pending", fetch = true, yes = true })
    local took = (vim.uv.hrtime() - started) / 1e6
    assert.is_true(
      took < helper_s * 1000 - 2000,
      ("answered at the deadline (took %d ms)"):format(took)
    )
    local failed = vim.tbl_map(function(f)
      return ("%s: %s"):format(f.name, f.reason)
    end, r.fetched.failed or {})
    local detail = ("took %d ms, fetched %d, failed { %s }"):format(
      took,
      r.fetched.fetched,
      table.concat(failed, "; ")
    )
    assert.equals(1, r.fetched.fetched, "only the fast clone fetched (" .. detail .. ")")
    assert.equals(1, #failed, "only the slow clone failed (" .. detail .. ")")
    assert.equals("slow", r.fetched.failed[1].name, detail)
    assert.is_truthy(r.fetched.failed[1].reason:find("timed out", 1, true), detail)
    local fast = by_name(r).fast
    assert.is_not_nil(fast, "the fast clone is in the report (" .. detail .. ")")
    assert.equals("forward", fast.status)
    -- wait past the helper's sleep: a survivor would have written the marker by then
    vim.wait((helper_s + 1.5) * 1000 - took, function()
      return false
    end, 100)
    assert.is_nil(vim.uv.fs_stat(marker), "the helper process was killed with git")
  end)

  it("stop() during the fetch ends the run without building a report", function()
    local git = require("lib.nvim.git")
    local stopped = 0
    local original = git.fetch_async
    git.fetch_async = function()
      return {
        stop = function()
          stopped = stopped + 1
        end,
      }
    end
    local bare = upstream(1)
    clone_of(bare, "one")
    local box
    local handle = plugins.report({
      mode = "pending",
      fetch = true,
      yes = true,
      out = "clipboard",
      on_done = function(r, err)
        box = { report = r, err = err }
      end,
    })
    handle.stop()
    vim.wait(200, function()
      return false
    end, 10)
    git.fetch_async = original
    assert.equals("stopped", box.err)
    assert.equals(1, stopped)
    -- the slot is free again: a new build (not `--last`, which never checks the
    -- slot) starts instead of answering "already running"
    local r, err = report({ mode = "pending" })
    assert.is_nil(err)
    assert.is_not_nil(r)
  end)

  it("checks for a working lazy.nvim again once the question is answered", function()
    local bare = upstream(1)
    clone_of(bare, "a")
    clone_of(bare, "b")
    require("gitsuite.config").setup({
      plugins = { roots = { root }, sources = { "clones" }, fetch_confirm = 2 },
    })
    local calls = 0
    local original = gitlog.fetch
    gitlog.fetch = function(...)
      calls = calls + 1
      return original(...)
    end
    local busy_lazy = { plugins = { x = { name = "x", _ = { working = true } } } }
    with_module("ui.kit", {
      confirm = function(o)
        -- lazy.nvim starts an update while the question is open
        package.loaded["lazy.core.config"] = busy_lazy
        o.on_answer(true)
        return {} -- a dialog that opened
      end,
    }, function()
      with_module("lazy.core.config", nil, function()
        local r, err = report({ mode = "pending", fetch = true })
        assert.is_nil(r)
        assert.is_truthy(err:find("lazy.nvim is working", 1, true))
      end)
    end)
    gitlog.fetch = original
    assert.equals(0, calls)
  end)

  it("busy() and skip_reason() name what they found", function()
    assert.is_nil(fetch.busy())
    assert.is_truthy(fetch.skip_reason({ name = "x", dir = root }):find(".git", 1, true))
  end)
end)
