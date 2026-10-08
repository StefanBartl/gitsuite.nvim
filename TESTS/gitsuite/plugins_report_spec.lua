-- TESTS/gitsuite/plugins_report_spec.lua -- `:Git plugins report`: the report
-- store (state), the Markdown rendering, and the report builder end to end
-- against throwaway clones whose reflogs are written by hand (a real update
-- cannot be timed in a spec).
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("gitsuite.features.plugins.state (the report store)", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local state, path
  local CFG = { keep_reports = 20, max_age_days = 365 }
  local NOW = 1790000000

  local function report(id, at, extra)
    return vim.tbl_extend("force", {
      version = 1,
      id = id,
      at = at,
      mode = "updated",
      plugins = {},
      heads = {},
      counts = { checked = 0, changed = 0, commits = 0, unchanged = 0 },
      errors = {},
    }, extra or {})
  end

  before_each(function()
    package.loaded["gitsuite.features.plugins.state"] = nil
    state = require("gitsuite.features.plugins.state")
    path = F.tmpdir("-store") .. "/gitsuite/plugins_reports.json"
  end)

  after_each(function()
    F.cleanup()
  end)

  it("starts empty when there is no file", function()
    local store, info = state.load(path)
    assert.same({}, store.reports)
    assert.same({}, info)
  end)

  it("stores a report atomically and reads it back, newest first", function()
    assert.is_true((state.add(report("a", NOW - 100), CFG, path)))
    assert.is_true((state.add(report("b", NOW), CFG, path)))
    local store = state.load(path)
    assert.same(
      { "b", "a" },
      vim.tbl_map(function(r)
        return r.id
      end, store.reports)
    )
    assert.equals(state.host(), store.host)
    -- the atomic write leaves no temp file behind
    local left = vim.fn.glob(vim.fs.dirname(path) .. "/*", false, true)
    assert.same(
      { (path:gsub("\\", "/")) },
      vim.tbl_map(function(p)
        return (p:gsub("\\", "/"))
      end, left)
    )
  end)

  it("replaces a report with the same id", function()
    state.add(report("a", NOW, { mode = "updated" }), CFG, path)
    state.add(report("a", NOW, { mode = "pending" }), CFG, path)
    local store = state.load(path)
    assert.equals(1, #store.reports)
    assert.equals("pending", store.reports[1].mode)
  end)

  it("moves an unreadable file aside instead of overwriting it", function()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    F.write(path, "{ this is not json")
    local store, info = state.load(path)
    assert.same({}, store.reports)
    assert.is_truthy(info.recovered)
    assert.is_nil(vim.uv.fs_stat(path), "the broken file is no longer in the way")
    local f = assert(io.open(info.recovered, "rb"))
    assert.equals("{ this is not json", f:read("*a"))
    f:close()
  end)

  it("treats valid JSON of the wrong shape as unreadable too", function()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    F.write(path, '{"hello":"world"}')
    local _, info = state.load(path)
    assert.is_truthy(info.recovered)
  end)

  it("leaves a store from a newer gitsuite alone and refuses to write it", function()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local content =
      vim.json.encode({ version = state.VERSION + 1, host = state.host(), reports = {} })
    F.write(path, content)
    local ok, err, info = state.add(report("a", NOW), CFG, path)
    assert.is_false(ok)
    assert.is_truthy(err:find("newer gitsuite", 1, true))
    assert.is_truthy(info.readonly)
    local f = assert(io.open(path, "rb"))
    assert.equals(content, f:read("*a"))
    f:close()
  end)

  it("keeps another machine's store aside and starts its own", function()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local theirs = vim.json.encode({
      version = state.VERSION,
      host = "OTHER-PC",
      reports = { report("theirs", NOW - 10) },
    })
    F.write(path, theirs)
    local _, info = state.load(path)
    assert.equals("OTHER-PC", info.foreign)

    assert.is_true((state.add(report("mine", NOW), CFG, path)))
    local store = state.load(path)
    assert.same(
      { "mine" },
      vim.tbl_map(function(r)
        return r.id
      end, store.reports)
    )
    assert.equals(state.host(), store.host)
    local backup = vim.fn.glob(vim.fs.dirname(path) .. "/*.foreign-OTHER-PC.bak", false, true)
    assert.equals(1, #backup)
    local f = assert(io.open(backup[1], "rb"))
    assert.equals(theirs, f:read("*a"))
    f:close()
  end)

  it("leaves out reports it cannot use and says how many", function()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    F.write(
      path,
      vim.json.encode({
        version = state.VERSION,
        host = state.host(),
        reports = { report("ok", NOW), { id = 5 }, "junk", { id = "x", at = "y", plugins = {} } },
      })
    )
    local store, info = state.load(path)
    assert.equals(1, #store.reports)
    assert.equals(3, info.dropped)
  end)

  describe("retention", function()
    it("keeps at most keep_reports and nothing older than max_age_days", function()
      local store = { reports = {} }
      for i = 1, 30 do
        store.reports[i] = report("r" .. i, NOW - i * 86400)
      end
      state.prune(store, { keep_reports = 5, max_age_days = 365 }, NOW)
      assert.equals(5, #store.reports)
      assert.equals("r1", store.reports[1].id)

      store = { reports = { report("new", NOW - 86400), report("old", NOW - 40 * 86400) } }
      state.prune(store, { keep_reports = 20, max_age_days = 30 }, NOW)
      assert.same(
        { "new" },
        vim.tbl_map(function(r)
          return r.id
        end, store.reports)
      )
    end)

    it("never rotates out the newest report, however old", function()
      local store = { reports = { report("only", NOW - 900 * 86400) } }
      state.prune(store, { keep_reports = 20, max_age_days = 30 }, NOW)
      assert.equals(1, #store.reports)
    end)

    it("drops the oldest reports when the file would get too big, but keeps one", function()
      local original = state.MAX_BYTES
      state.MAX_BYTES = 2000
      local fat = {}
      for i = 1, 40 do
        fat[i] = { name = "p" .. i, text = ("x"):rep(50) }
      end
      for i = 1, 5 do
        assert.is_true((state.add(report("r" .. i, NOW + i, { plugins = fat }), CFG, path)))
      end
      state.MAX_BYTES = original
      local store = state.load(path)
      assert.equals(1, #store.reports)
      assert.equals("r5", store.reports[1].id)
    end)
  end)

  it("indexes stored ranges by dir@from...to and remembers where a plugin stood", function()
    local from, to = ("a"):rep(40), ("b"):rep(40)
    state.add(
      report("a", NOW, {
        plugins = { { dir = "/p/x", from = from, to = to, commits = {}, status = "forward" } },
        heads = { ["/p/x"] = to, ["/p/y"] = from },
      }),
      CFG,
      path
    )
    local store = state.load(path)
    assert.is_not_nil(state.cache_index(store)[state.cache_key("/p/x", from, to)])
    assert.is_nil(state.cache_index(store)[state.cache_key("/p/x", to, from)])
    assert.equals(to, state.snapshot(store, "/p/x"))
    assert.equals(from, state.snapshot(store, "/p/y"))
    assert.is_nil(state.snapshot(store, "/p/z"))
  end)
end)

describe("gitsuite.features.plugins.markdown", function()
  local markdown = require("gitsuite.features.plugins.markdown")
  local NOW = 1790000000

  local function base(mode, plugins)
    return {
      version = 1,
      id = "x",
      at = NOW,
      mode = mode,
      host = "HOST",
      lazy = "11.17.5",
      sources = { "lazy" },
      plugins = plugins,
      counts = { checked = #plugins, changed = #plugins, commits = 2, unchanged = 0 },
      errors = {},
    }
  end

  local function commit(sha, subject, side)
    return {
      sha = sha:rep(40),
      subject = subject,
      body = "",
      author = "Ann",
      time = NOW,
      side = side,
    }
  end

  local function joined(lines)
    return table.concat(lines, "\n")
  end

  it("renders a header, a summary table and a section per changed plugin", function()
    local report = base("updated", {
      {
        name = "alpha.nvim",
        status = "forward",
        source = "reflog",
        confidence = "exact",
        from = ("a"):rep(40),
        to = ("b"):rep(40),
        time = NOW,
        commits = { commit("b", "feat: one"), commit("c", "fix: two") },
      },
    })
    report.run = { first = NOW, last = NOW + 5, older = 2, plugins = 1 }
    local out = joined(markdown.render(report, NOW))
    assert.is_truthy(out:find("# Plugin changes — updated", 1, true))
    assert.is_truthy(out:find("| alpha.nvim | updated |", 1, true))
    assert.is_truthy(out:find("`aaaaaaaa → bbbbbbbb`", 1, true))
    assert.is_truthy(out:find("## alpha.nvim", 1, true))
    assert.is_truthy(out:find("feat: one (Ann)", 1, true))
    assert.is_truthy(out:find("2 earlier updates not shown", 1, true))
    assert.is_truthy(out:find("reflog", 1, true))
  end)

  it("marks an approximate source and a pending update", function()
    local out = joined(markdown.render(
      base("pending", {
        {
          name = "p",
          status = "forward",
          source = "snapshot",
          confidence = "approx",
          from = ("a"):rep(40),
          to_label = "v1.1.0",
          fetched_at = NOW - 3 * 86400,
          commits = { commit("b", "x") },
        },
      }),
      NOW
    ))
    assert.is_truthy(out:find("snapshot ~", 1, true))
    assert.is_truthy(out:find("update available", 1, true))
    assert.is_truthy(out:find("→ v1.1.0", 1, true))
    assert.is_truthy(out:find("last fetched 3 days ago", 1, true))
    assert.is_truthy(out:find("Commits not installed yet", 1, true))
  end)

  it("says so when no clone has a recorded fetch", function()
    local out = joined(markdown.render(base("pending", {}), NOW))
    assert.is_truthy(out:find("No fetch is recorded", 1, true))
    assert.is_truthy(out:find("Nothing to report", 1, true))
  end)

  it("lists a rollback and a divergence honestly, not as new commits", function()
    local out = joined(markdown.render(
      base("updated", {
        {
          name = "back",
          status = "rollback",
          source = "reflog",
          from = ("a"):rep(40),
          to = ("b"):rep(40),
          commits = { commit("c", "undone", "<") },
        },
        {
          name = "split",
          status = "diverged",
          source = "reflog",
          from = ("a"):rep(40),
          to = ("b"):rep(40),
          commits = { commit("d", "only new", ">"), commit("e", "only old", "<") },
        },
      }),
      NOW
    ))
    assert.is_truthy(out:find("rolled back", 1, true))
    assert.is_truthy(out:find("Commits no longer installed", 1, true))
    assert.is_truthy(out:find("diverged", 1, true))
    assert.is_truthy(out:find("Only in the new state", 1, true))
    assert.is_truthy(out:find("Only in the old state", 1, true))
    assert.is_nil(out:find("Commits in this update", 1, true))
  end)

  it("gives a row without commits its reason", function()
    local out = joined(markdown.render(
      base("pending", {
        {
          name = "pinned.nvim",
          status = "pinned",
          source = "pending",
          reason = "pinned in the plugin spec",
        },
        {
          name = "gone",
          status = "from_missing",
          source = "reflog",
          reason = "the previous state is no longer in the clone",
        },
      }),
      NOW
    ))
    assert.is_truthy(out:find("## pinned.nvim", 1, true))
    assert.is_truthy(out:find("pinned in the plugin spec", 1, true))
    assert.is_truthy(out:find("old state gone", 1, true))
  end)

  it("cleans hostile text and keeps a table cell intact", function()
    local out = joined(markdown.render(
      base("updated", {
        {
          name = "evil|name\27[2J",
          status = "forward",
          source = "reflog",
          from = ("a"):rep(40),
          to = ("b"):rep(40),
          commits = { commit("b", "subject \27[31mred\r\nsecond line", nil) },
        },
      }),
      NOW
    ))
    assert.is_nil(out:find("\27", 1, true))
    assert.is_nil(out:find("\r", 1, true))
    assert.is_truthy(out:find("evil\\|name?", 1, true))
    assert.is_nil(out:find("second line", 1, true), "only the first line of a subject")
  end)

  it("lists at most MAX_LISTED commits and says how many more", function()
    local commits = {}
    for i = 1, markdown.MAX_LISTED + 7 do
      commits[i] = commit("b", "c" .. i)
    end
    local out = joined(markdown.render(
      base("updated", {
        {
          name = "big",
          status = "forward",
          source = "reflog",
          from = ("a"):rep(40),
          to = ("b"):rep(40),
          commits = commits,
          truncated = true,
        },
      }),
      NOW
    ))
    assert.is_truthy(out:find("… 7 more", 1, true))
    assert.is_truthy(out:find("plugins.max_commits", 1, true))
  end)
end)

describe("gitsuite.features.plugins.report", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local report_mod, state, gitlog, plugins
  local root, store_path, original_state_path

  local ZERO = ("0"):rep(40)
  local T0 = 1789000000 -- the clones were made
  local TU = 1790000000 -- the update run

  local function line(old, new, time, message)
    return ("%s %s T <t@example.invalid> %d +0000\t%s"):format(old, new, time, message)
  end

  ---A clone under `root`: `n` linear commits on main, HEAD detached at commit
  ---`head`, and a hand-written HEAD reflog built from the commit hashes.
  ---@param reflog fun(s: string[]): string[]|nil  `nil` = no reflog file.
  local function clone(name, n, head, reflog)
    local dir = root .. "/" .. name
    vim.fn.mkdir(dir, "p")
    F.git(dir, { "init", "-q", "-b", "main" })
    local s = F.history(dir, n)
    F.write(dir .. "/.git/HEAD", s[head] .. "\n")
    vim.fn.delete(dir .. "/.git/logs", "rf")
    local lines = reflog and reflog(s)
    if lines then F.write(dir .. "/.git/logs/HEAD", table.concat(lines, "\n") .. "\n") end
    return dir, s
  end

  local function by_name(report)
    local map = {}
    for _, entry in ipairs(report.plugins) do
      map[entry.name] = entry
    end
    return map
  end

  ---Run the builder and wait for its report.
  local function build(opts)
    local box
    report_mod.build(opts, function(report, info)
      box = { report = report, info = info }
    end)
    vim.wait(30000, function()
      return box ~= nil
    end, 10)
    assert.is_not_nil(box, "report.build called back")
    return box.report, box.info
  end

  ---The scenario of the reference case, in miniature: one run (alpha, rollbk,
  ---diverged, forced), an earlier update (gamma), an install in the run
  ---(newcomer), a plugin only installed long ago (beta).
  local function build_scenario()
    clone("alpha", 6, 5, function(s)
      return {
        line(ZERO, s[1], T0, "clone: from https://example.invalid/alpha"),
        line(s[1], s[2], T0 + 5, "checkout: moving from main to " .. s[2]),
        line(s[2], s[5], TU, "checkout: moving from " .. s[2] .. " to " .. s[5]),
      }
    end)
    clone("beta", 3, 2, function(s)
      return {
        line(ZERO, s[1], T0, "clone: from https://example.invalid/beta"),
        line(s[1], s[2], T0 + 5, "checkout: moving from main to " .. s[2]),
      }
    end)
    clone("gamma", 4, 4, function(s)
      return {
        line(ZERO, s[1], T0, "clone: from https://example.invalid/gamma"),
        line(s[1], s[2], T0 + 5, "checkout: moving"),
        line(s[2], s[4], TU - 86400, "checkout: moving"),
      }
    end)
    clone("rollbk", 5, 3, function(s)
      return {
        line(ZERO, s[1], T0, "clone: from https://example.invalid/rollbk"),
        line(s[1], s[2], T0 + 5, "checkout: moving"),
        line(s[2], s[5], TU - 200000, "checkout: moving"),
        line(s[5], s[3], TU + 20, "checkout: moving"),
      }
    end)
    -- two unrelated histories: main (3 commits) and side (2 commits)
    local div_dir = root .. "/diverged"
    vim.fn.mkdir(div_dir, "p")
    F.git(div_dir, { "init", "-q", "-b", "main" })
    local main_shas = F.history(div_dir, 3)
    local side_shas = F.history(div_dir, 2, { branch = "side", first = 1800000000 })
    F.write(div_dir .. "/.git/HEAD", side_shas[2] .. "\n")
    vim.fn.delete(div_dir .. "/.git/logs", "rf")
    F.write(div_dir .. "/.git/logs/HEAD", table.concat({
      line(ZERO, main_shas[3], T0, "clone: from https://example.invalid/diverged"),
      line(main_shas[3], side_shas[2], TU + 40, "checkout: moving from main to side"),
    }, "\n") .. "\n")
    local missing = ("e"):rep(40)
    clone("forced", 3, 2, function(s)
      return {
        line(ZERO, missing, T0, "clone: from https://example.invalid/forced"),
        line(missing, s[2], TU + 60, "checkout: moving"),
      }
    end)
    clone("newcomer", 2, 2, function(s)
      return {
        line(ZERO, s[1], TU + 95, "clone: from https://example.invalid/newcomer"),
        line(s[1], s[2], TU + 100, "checkout: moving"),
      }
    end)
  end

  ---The scenario's clones, built once for the whole file (a spawn is expensive,
  ---and nothing here changes them). Lives in its own fixture, so the
  ---per-test cleanup leaves it alone.
  local SF = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local scen
  local function scenario()
    if not scen then
      local saved = root
      scen = SF.tmpdir("-scenario")
      root = scen
      build_scenario()
      root = saved
    end
    return scen
  end

  local function refs_of(names, base)
    local refs = {}
    for _, name in ipairs(names) do
      refs[#refs + 1] = {
        name = name,
        dir = (base or root) .. "/" .. name,
        managed_by = "clones",
        is_local = false,
        spec = { pin = false },
      }
    end
    return refs
  end

  local ALL = { "alpha", "beta", "diverged", "forced", "gamma", "newcomer", "rollbk" }

  before_each(function()
    for _, name in ipairs({
      "gitsuite.features.plugins",
      "gitsuite.features.plugins.report",
      "gitsuite.features.plugins.state",
      "gitsuite.features.plugins.gitlog",
      "gitsuite.features.plugins.view",
    }) do
      package.loaded[name] = nil
    end
    require("gitsuite.config").setup({})
    state = require("gitsuite.features.plugins.state")
    gitlog = require("gitsuite.features.plugins.gitlog")
    report_mod = require("gitsuite.features.plugins.report")
    plugins = require("gitsuite.features.plugins")
    root = F.tmpdir("-report-clones")
    store_path = F.tmpdir("-report-store") .. "/plugins_reports.json"
    original_state_path = state.path
    state.path = function()
      return store_path
    end
  end)

  after_each(function()
    state.path = original_state_path
    F.cleanup()
  end)

  describe("mode updated", function()
    it("reports exactly the plugins of the latest run, each with its direction", function()
      local sroot = scenario()
      local report = build({ mode = "updated", refs = refs_of(ALL, sroot), persist = false })
      local by = by_name(report)

      assert.same(
        { "alpha", "diverged", "forced", "newcomer", "rollbk" },
        vim.tbl_map(function(e)
          return e.name
        end, report.plugins)
      )
      assert.equals("forward", by.alpha.status)
      assert.equals("rollback", by.rollbk.status)
      assert.equals("diverged", by.diverged.status)
      assert.equals("from_missing", by.forced.status)
      assert.equals("new", by.newcomer.status)

      assert.same({ first = TU, last = TU + 60, older = 1, plugins = 4 }, report.run)
      assert.same({ checked = 7, changed = 3, commits = 10, unchanged = 2 }, report.counts)
    end)

    it("lists the commits that changed, newest first, and only those", function()
      local sroot = scenario()
      local by = by_name(build({ mode = "updated", refs = refs_of(ALL, sroot), persist = false }))
      assert.same(
        { "c5", "c4", "c3" },
        vim.tbl_map(function(c)
          return c.subject
        end, by.alpha.commits)
      )
      assert.equals(3, by.alpha.ahead)
      assert.equals(0, by.alpha.behind)
      assert.equals("reflog", by.alpha.source)
      assert.equals("exact", by.alpha.confidence)
      assert.equals(TU, by.alpha.time)

      -- a rollback lists what is no longer installed
      assert.same(
        { "c5", "c4" },
        vim.tbl_map(function(c)
          return c.subject
        end, by.rollbk.commits)
      )
      assert.equals(2, by.rollbk.behind)

      -- a divergence lists both sides, marked
      local sides = { [">"] = 0, ["<"] = 0 }
      for _, c in ipairs(by.diverged.commits) do
        sides[c.side] = sides[c.side] + 1
      end
      assert.same({ [">"] = 2, ["<"] = 3 }, sides)
    end)

    it("does not report an install checkout as an update", function()
      local sroot = scenario()
      local by = by_name(build({ mode = "updated", refs = refs_of(ALL, sroot), persist = false }))
      assert.is_nil(by.beta, "installed long ago, never updated")
      assert.is_nil(by.gamma, "its update is from an earlier run")
      assert.equals("new", by.newcomer.status)
      assert.is_nil(by.newcomer.commits)
    end)

    it("explains a force-pushed-away previous state instead of an error or a count", function()
      local sroot = scenario()
      local by = by_name(build({ mode = "updated", refs = refs_of(ALL, sroot), persist = false }))
      assert.is_truthy(by.forced.reason:find("no longer in the clone", 1, true))
      assert.is_nil(by.forced.commits)
    end)

    it("says when nothing was updated", function()
      clone("lonely", 2, 2, function(s)
        return {
          line(ZERO, s[1], T0, "clone: from x"),
          line(s[1], s[2], T0 + 5, "checkout: moving"),
        }
      end)
      local report = build({ mode = "updated", refs = refs_of({ "lonely" }), persist = false })
      assert.same({}, report.plugins)
      assert.is_nil(report.run)
      assert.equals(1, report.counts.checked)
    end)

    it("cuts a long list at max_commits and says so", function()
      local sroot = scenario()
      require("gitsuite.config").setup({ plugins = { max_commits = 2 } })
      local by =
        by_name(build({ mode = "updated", refs = refs_of({ "alpha" }, sroot), persist = false }))
      assert.equals(2, #by.alpha.commits)
      assert.is_true(by.alpha.truncated)
      assert.equals("c5", by.alpha.commits[1].subject)
    end)

    it("leaves merge commits out unless asked", function()
      local dir = root .. "/merger"
      vim.fn.mkdir(dir, "p")
      F.git(dir, { "init", "-q", "-b", "main" })
      local stream =
        table.concat({
          "commit refs/heads/main\nmark :1\ncommitter T <t@x.y> 1700000100 +0000\n" .. F.data(
            "base"
          ) .. "M 100644 inline f\n" .. F.data("1\n") .. "\n",
          "commit refs/heads/main\nmark :2\ncommitter T <t@x.y> 1700000200 +0000\n" .. F.data(
            "main work"
          ) .. "from :1\nM 100644 inline f\n" .. F.data("2\n") .. "\n",
          "commit refs/heads/side\nmark :3\ncommitter T <t@x.y> 1700000250 +0000\n" .. F.data(
            "side work"
          ) .. "from :1\nM 100644 inline g\n" .. F.data("3\n") .. "\n",
          "commit refs/heads/main\nmark :4\ncommitter T <t@x.y> 1700000300 +0000\n" .. F.data(
            "Merge side"
          ) .. "from :2\nmerge :3\nM 100644 inline g\n" .. F.data("3\n") .. "\n",
        })
      local marks = F.fast_import(dir, stream)
      F.write(dir .. "/.git/HEAD", marks[4] .. "\n")
      vim.fn.delete(dir .. "/.git/logs", "rf")
      F.write(dir .. "/.git/logs/HEAD", table.concat({
        line(ZERO, marks[1], T0, "clone: from x"),
        line(marks[1], marks[4], TU, "checkout: moving"),
      }, "\n") .. "\n")
      local refs = refs_of({ "merger" })
      local without = by_name(build({ mode = "updated", refs = refs, persist = false })).merger
      local function subjects(entry)
        return vim.tbl_map(function(c)
          return c.subject
        end, entry.commits)
      end
      assert.is_false(vim.tbl_contains(subjects(without), "Merge side"))
      assert.is_true(vim.tbl_contains(subjects(without), "side work"))
      require("gitsuite.config").setup({ plugins = { merges = true } })
      local with = by_name(build({ mode = "updated", refs = refs, persist = false })).merger
      assert.is_true(vim.tbl_contains(subjects(with), "Merge side"))
    end)
  end)

  describe("the store", function()
    it("persists the report and reads it back", function()
      local sroot = scenario()
      local report = build({ mode = "updated", refs = refs_of(ALL, sroot) })
      assert.is_nil(report.save_error)
      local store = state.load(store_path)
      assert.equals(1, #store.reports)
      assert.equals(report.id, store.reports[1].id)
      local alpha = by_name(store.reports[1]).alpha
      assert.equals("c5", alpha.commits[1].subject)
      assert.equals(7, vim.tbl_count(store.reports[1].heads))
    end)

    it("takes a range seen before from the store instead of asking git again", function()
      local sroot = scenario()
      build({ mode = "updated", refs = refs_of(ALL, sroot) })

      local asked = {}
      local original = gitlog.range
      gitlog.range = function(dir, from, to, opts, on_done)
        asked[#asked + 1] = vim.fs.basename(dir)
        return original(dir, from, to, opts, on_done)
      end
      local report = build({ mode = "updated", refs = refs_of(ALL, sroot) })
      gitlog.range = original

      -- only the range that has no stored commits (the force-pushed one) is retried
      assert.same({ "forced" }, asked)
      assert.equals(10, report.counts.commits)
      assert.equals("c5", by_name(report).alpha.commits[1].subject)
    end)

    it("falls back to the last report's state when the reflog says nothing", function()
      local dir, s = clone("snap", 4, 2, nil)
      local refs = refs_of({ "snap" })
      local first = build({ mode = "updated", refs = refs })
      assert.same({}, first.plugins, "no reflog, no earlier report: nothing to compare")

      F.write(dir .. "/.git/HEAD", s[4] .. "\n")
      local second = build({ mode = "updated", refs = refs })
      local entry = assert(by_name(second).snap)
      assert.equals("snapshot", entry.source)
      assert.equals("approx", entry.confidence)
      assert.equals("forward", entry.status)
      assert.equals(s[2], entry.from)
      assert.same(
        { "c4", "c3" },
        vim.tbl_map(function(c)
          return c.subject
        end, entry.commits)
      )
      assert.is_nil(second.run, "a snapshot has no update time to cluster")
    end)

    it("does not lose the report when the store cannot be written", function()
      local sroot = scenario()
      state.path = function()
        return store_path .. "/in-a-file/x.json"
      end
      F.write(store_path, "I am a file, not a folder")
      local report = build({ mode = "updated", refs = refs_of(ALL, sroot) })
      assert.is_truthy(report.save_error)
      assert.equals(3, report.counts.changed)
    end)
  end)

  describe("mode pending", function()
    ---A clone standing in for a lazy one: tags v1.0.0/v1.1.0 early, v2.0.0 late,
    ---the remote branch at the tip, HEAD detached at the first commit.
    local function pending_clone(name, head)
      local dir = root .. "/" .. name
      vim.fn.mkdir(dir, "p")
      F.git(dir, { "init", "-q", "-b", "main" })
      local extra = {
        "reset refs/tags/v1.0.0\nfrom :2\n\n",
        "reset refs/tags/v1.1.0\nfrom :3\n\n",
        "reset refs/tags/v2.0.0\nfrom :5\n\n",
        "reset refs/remotes/origin/main\nfrom :6\n\n",
      }
      local s = F.history(dir, 6, { extra = table.concat(extra) })
      F.write(dir .. "/.git/refs/remotes/origin/HEAD", "ref: refs/remotes/origin/main\n")
      F.write(dir .. "/.git/HEAD", s[head] .. "\n")
      F.write(dir .. "/.git/FETCH_HEAD", s[6] .. "\t\tbranch 'main' of x\n")
      return dir, s
    end

    local function ref(name, spec)
      return {
        name = name,
        dir = root .. "/" .. name,
        managed_by = "lazy",
        is_local = false,
        spec = vim.tbl_extend("force", { pin = false }, spec or {}),
      }
    end

    it("compares with lazy's target -- the version range, not the branch tip", function()
      local _, s = pending_clone("versioned", 1)
      pending_clone("tracking", 4)
      pending_clone("current", 6)
      pending_clone("pinned", 1)
      pending_clone("mystery", 1)
      local report = build({
        mode = "pending",
        persist = false,
        refs = {
          ref("versioned", { version = "1.*" }),
          ref("tracking"),
          ref("current"),
          ref("pinned", { pin = true, version = "1.*" }),
          ref("mystery", { tag = "v9" }),
        },
      })
      local by = by_name(report)

      -- version 1.*: v1.1.0 (3 commits ahead of c1 are c2,c3) -- NOT the 5 of the branch tip
      assert.equals("forward", by.versioned.status)
      assert.equals("v1.1.0", by.versioned.to_label)
      assert.same(
        { "c3", "c2" },
        vim.tbl_map(function(c)
          return c.subject
        end, by.versioned.commits)
      )
      assert.equals(s[1], by.versioned.from)

      assert.same(
        { "c6", "c5" },
        vim.tbl_map(function(c)
          return c.subject
        end, by.tracking.commits)
      )

      assert.is_nil(by.current, "already at the target: no row, no process")
      assert.equals("pinned", by.pinned.status)
      assert.equals("unknown_target", by.mystery.status)
      assert.is_truthy(by.mystery.reason:find("not in the clone", 1, true))
      assert.equals("pending", by.versioned.source)
      assert.is_number(by.versioned.fetched_at)
      assert.equals("pending", report.mode)
    end)

    it("keeps unchanged plugins free of any git process", function()
      pending_clone("current", 6)
      local spawned = 0
      local original = gitlog.range
      gitlog.range = function(...)
        spawned = spawned + 1
        return original(...)
      end
      build({ mode = "pending", persist = false, refs = { ref("current") } })
      gitlog.range = original
      assert.equals(0, spawned)
    end)
  end)

  describe("the command", function()
    it("builds, shows and announces a report", function()
      local sroot = scenario()
      require("gitsuite.config").setup({ plugins = { roots = { sroot } } })

      local event
      local group = vim.api.nvim_create_augroup("gitsuite_report_spec", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "GitsuitePluginsReported",
        callback = function(e)
          event = e.data
        end,
      })

      local box
      plugins.report({
        mode = "updated",
        out = "clipboard",
        on_done = function(report, err)
          box = { report = report, err = err }
        end,
      })
      vim.wait(30000, function()
        return box ~= nil
      end, 10)
      pcall(vim.api.nvim_del_augroup_by_id, group)

      assert.is_not_nil(box)
      assert.is_nil(box.err)
      assert.equals(3, box.report.counts.changed)
      assert.is_truthy(vim.fn.getreg('"'):find("# Plugin changes — updated", 1, true))
      assert.is_truthy(vim.fn.getreg('"'):find("## alpha", 1, true))
      assert.is_not_nil(event)
      assert.equals(box.report.id, event.id)
      assert.equals(3, event.plugins)
      assert.equals(10, event.commits)
      assert.is_true(event.saved)
    end)

    it("writes the report to the file --to names", function()
      local sroot = scenario()
      require("gitsuite.config").setup({ plugins = { roots = { sroot } } })
      local target = F.tmpdir("-out") .. "/sub/report.md"
      local box
      plugins.report({
        mode = "updated",
        out = "path",
        to = target,
        on_done = function(report)
          box = report
        end,
      })
      vim.wait(30000, function()
        return box ~= nil
      end, 10)
      local f = assert(io.open(target, "rb"))
      local body = f:read("*a")
      f:close()
      assert.is_truthy(body:find("## rollbk", 1, true))
    end)

    it("shows the newest stored report with --last, without scanning", function()
      local sroot = scenario()
      require("gitsuite.config").setup({ plugins = { roots = { sroot } } })
      local stored = build({ mode = "updated", refs = refs_of(ALL, sroot) })

      local spawned = 0
      local original = gitlog.range
      gitlog.range = function(...)
        spawned = spawned + 1
        return original(...)
      end
      vim.fn.setreg('"', "")
      local shown
      plugins.report({
        last = true,
        out = "clipboard",
        on_done = function(report)
          shown = report
        end,
      })
      gitlog.range = original
      assert.equals(stored.id, shown.id)
      assert.equals(0, spawned)
      assert.is_truthy(vim.fn.getreg('"'):find("## alpha", 1, true))
    end)

    it("says so when there is no stored report", function()
      local notices = {}
      local notify = require("gitsuite.util.notify")
      local original = notify.error
      notify.error = function(msg)
        notices[#notices + 1] = msg
      end
      local got = "unset"
      plugins.report({
        last = true,
        on_done = function(report, err)
          got = err
          assert.is_nil(report)
        end,
      })
      notify.error = original
      assert.equals("no stored report", got)
      assert.is_truthy(notices[1]:find("no stored report", 1, true))
    end)

    it("takes --last and --all as plain switches, not as flags with a value", function()
      local sroot = scenario()
      require("gitsuite.config").setup({ plugins = { roots = { sroot } } })
      require("gitsuite.bindings.usrcmds").register(require("gitsuite.config").get())
      -- build one report first, so --last has something to show
      local stored = build({ mode = "updated", refs = refs_of(ALL, sroot) })
      vim.fn.setreg('"', "")
      vim.cmd("Git plugins report --last --out=clipboard")
      assert.is_truthy(vim.fn.getreg('"'):find(stored.id, 1, true))

      -- a switch with a value is refused by the composer, with the reason
      local messages = {}
      local original = vim.notify
      vim.notify = function(msg)
        messages[#messages + 1] = tostring(msg)
      end
      vim.cmd("Git plugins report --last=yes")
      vim.wait(2000, function()
        return #messages > 0
      end, 10)
      vim.notify = original
      assert.is_truthy(table.concat(messages, " "):find("takes no value", 1, true))
    end)

    it("is a registered route with described flags", function()
      local sroot = scenario()
      require("gitsuite.config").setup({ plugins = { roots = { sroot } } })
      require("gitsuite.bindings.usrcmds").register(require("gitsuite.config").get())
      vim.fn.setreg('"', "")
      vim.cmd("Git plugins report --mode=updated --out=clipboard")
      vim.wait(30000, function()
        return vim.fn.getreg('"'):find("Plugin changes", 1, true) ~= nil
      end, 10)
      assert.is_truthy(vim.fn.getreg('"'):find("## alpha", 1, true))
    end)
  end)
end)
