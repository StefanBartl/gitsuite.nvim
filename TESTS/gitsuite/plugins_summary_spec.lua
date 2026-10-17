-- TESTS/gitsuite/plugins_summary_spec.lua -- gitsuite.features.plugins.summary
-- (the deterministic digest of one plugin's update and its Markdown) and how
-- the report builder feeds it: commits in topological order with their
-- directories, the releases of the range, the convention check.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local function sha(n)
  return ("%040x"):format(n)
end

---A report entry with `subjects` (newest first), forward, in topological order.
local function entry(subjects, extra)
  local commits = {}
  for i, s in ipairs(subjects) do
    commits[i] = {
      sha = sha(i),
      subject = s,
      body = "",
      author = "Alice",
      time = 1790000000 - i * 60,
      side = ">",
    }
  end
  return vim.tbl_extend("force", {
    name = "demo.nvim",
    dir = "/x/demo.nvim",
    status = "forward",
    order = "topo",
    commits = commits,
  }, extra or {})
end

describe("gitsuite.features.plugins.summary", function()
  local S

  before_each(function()
    package.loaded["gitsuite.features.plugins.summary"] = nil
    package.loaded["gitsuite.features.plugins.breaking"] = nil
    S = require("gitsuite.features.plugins.summary")
  end)

  it("counts types, scopes, authors and bots, ties broken by name", function()
    local e =
      entry({ "feat(ui): a", "fix(ui): b", "fix(core): c", "Update readme", "bot(parsers): d" })
    e.commits[5].author = "dependabot[bot]"
    e.commits[4].author = "Bob"
    local s = S.build(e)
    assert.are.same({
      { name = "fix", count = 2 },
      { name = "bot", count = 1 },
      { name = "feat", count = 1 },
      { name = "other", count = 1 },
    }, s.types)
    assert.are.same({ name = "ui", count = 2 }, s.scopes[1])
    assert.are.same({ name = "Alice", count = 3 }, s.authors[1])
    assert.are.equal(1, s.bots)
    assert.are.equal(5, s.count)
  end)

  it("is deterministic: the same entry gives the same lines", function()
    local e = entry({ "feat!: a", "fix: b", "feat(x)!: update parser and queries", "chore: c" })
    local a = S.markdown(S.build(e))
    local b = S.markdown(S.build(vim.deepcopy(e)))
    assert.are.same(a, b)
  end)

  it("numbers only a complete forward update", function()
    local s = S.build(entry({ "feat!: c", "fix: b", "feat!: a" }))
    assert.are.same({ 3, 2, 1 }, s.digest.positions)
    assert.is_true(s.complete)
    s = S.build(entry({ "feat!: c", "fix: b" }, { truncated = true }))
    assert.is_nil(s.digest.positions)
    local old = entry({ "feat!: c", "fix: b" })
    old.order = nil
    s = S.build(old)
    assert.is_nil(s.digest.positions, "a stored entry from before the topological order")
  end)

  it("looks at the new side only: a rollback has nothing new", function()
    local e = entry({ "feat!: a" }, { status = "rollback" })
    assert.are.equal(0, S.build(e).count)
    e = entry({ "feat!: a", "feat!: b" }, { status = "diverged" })
    e.commits[2].side = "<"
    assert.are.equal(1, S.build(e).count)
  end)

  it("counts the changed directories", function()
    local e = entry({ "a", "b" })
    e.commits[1].dirs = { "lua/demo", "queries/kotlin" }
    e.commits[2].dirs = { "lua/demo" }
    local s = S.build(e)
    assert.are.same({ name = "lua/demo", count = 2 }, s.dirs[1])
  end)

  describe("release", function()
    it("calls a new major a major jump and leaves pre-releases out", function()
      local r = S.release({
        range = { { name = "v2.0.0-rc.1" }, { name = "v2.0.0" }, { name = "v1.9.2" } },
        before = { { name = "v1.9.1" } },
      })
      assert.are.same({ kind = "major", from = "v1.9.1", to = "v2.0.0", count = 2 }, r)
      assert.are.equal("MAJOR v1.9.1 → v2.0.0 (2 releases)", S.release_line(r))
    end)

    it("knows minor, patch and first releases", function()
      assert.are.equal(
        "minor",
        S.release({ range = { { name = "v1.2.0" } }, before = { { name = "v1.1.9" } } }).kind
      )
      assert.are.equal(
        "patch",
        S.release({ range = { { name = "1.1.10" } }, before = { { name = "1.1.9" } } }).kind
      )
      assert.are.equal("first", S.release({ range = { { name = "v0.1.0" } }, before = {} }).kind)
    end)

    it("says when the range has no release, and which one was the last", function()
      local r = S.release({
        range = { { name = "nightly" }, { name = "v1.0.0-beta" } },
        before = { { name = "v0.9.3" } },
      })
      assert.are.equal("none", r.kind)
      assert.are.equal("no release tag in this update (last v0.9.3)", S.release_line(r))
      assert.is_nil(S.release(nil), "no tags read")
    end)
  end)

  describe("convention", function()
    it("takes the stored count of the project's newest subjects", function()
      local s = S.build(entry({ "a" }, { convention = { conventional = 10, total = 100 } }))
      assert.is_false(s.convention.recognized)
      local lines = table.concat(S.markdown(s), "\n")
      assert.matches("No marker convention recognized %(10 of 100", lines)
    end)

    it("falls back to the range and honours style overrides", function()
      local subjects = { "Add a", "Fix b", "Tweak c", "Polish d", "Move e" }
      assert.is_false(S.build(entry(subjects)).convention.recognized)
      local s = S.build(entry(subjects), { style = "conventional" })
      assert.is_true(s.convention.recognized)
      s =
        S.build(entry({ "feat: a", "fix: b", "feat: c", "fix: d", "feat: e" }), { style = "none" })
      assert.is_false(s.convention.recognized)
      assert.matches("plugins.breaking.plugins", table.concat(S.markdown(s), "\n"))
    end)
  end)

  describe("options", function()
    it("merges the global and the plugin's own settings", function()
      local o = S.options({
        breaking = {
          collapse_repeats = 3,
          ignore = { "a" },
          plugins = {
            ["nvim-treesitter"] = { ignore = { "b" }, force = { "abcdef1" }, style = "none" },
          },
        },
        nvim = { major = 0, minor = 12, patch = 2 },
      }, "nvim-treesitter")
      assert.are.same({ "a", "b" }, o.ignore)
      assert.are.same({ "abcdef1" }, o.force)
      assert.are.equal("none", o.style)
      assert.are.equal(3, o.collapse_repeats)
      assert.is_true(o.parser_plugin)
      assert.is_false(S.options(nil, "telescope.nvim").parser_plugin)
    end)
  end)

  describe("markdown", function()
    it("starts the breaking part with the heuristic note and lists what was found", function()
      local subjects = { "feat!: drop support for Nvim 0.11", "fix: a" }
      for _ = 1, 5 do
        table.insert(subjects, 1, "feat(kdl)!: update parser and queries")
      end
      local s =
        S.build(entry(subjects), { nvim = { major = 0, minor = 12, patch = 2 }, parsers = {} })
      local out = table.concat(S.markdown(s), "\n")
      assert.is_truthy(out:find(S.HEURISTIC_NOTE, 1, true))
      assert.is_truthy(out:find("**Breaking (1)**", 1, true))
      assert.is_truthy(out:find("2/7", 1, true), "commit i of n")
      assert.is_truthy(out:find("does not affect you", 1, true))
      assert.is_truthy(out:find([[~ 5 × feat(\<lang\>)!: update parser and queries]], 1, true))
      assert.is_truthy(out:find("5 marked breaking", 1, true))
    end)

    it("says when nothing was found", function()
      local out = table.concat(S.markdown(S.build(entry({ "fix: a" }))), "\n")
      assert.is_truthy(out:find("No commit is marked breaking", 1, true))
    end)

    it("cleans and escapes text from the plugin's repository", function()
      local s = S.build(entry({ "feat!: ![x](http://h/t.png) \27[31mred <b>" }))
      local out = table.concat(S.markdown(s), "\n")
      assert.is_nil(out:find("\27", 1, true), "no escape sequence")
      assert.is_nil(out:find("![x](", 1, true), "no image")
      assert.is_nil(out:find("<b>", 1, true), "no html")
    end)

    it("shows only the top hints and says how many more there are", function()
      local subjects = {}
      for i = 1, 7 do
        subjects[i] = "fix: remove thing " .. i
      end
      local out = S.markdown(S.build(entry(subjects)), { top_hints = 3 })
      local joined = table.concat(out, "\n")
      assert.is_truthy(joined:find("Hints (7, top 3 by score)", 1, true))
      assert.is_truthy(joined:find("4 more with a lower score", 1, true))
    end)
  end)
end)

describe("gitsuite.features.plugins.report (breaking data)", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local report_mod, summary
  local root

  local ZERO = ("0"):rep(40)
  local T0 = 1789000000
  local TU = 1790000000

  local function line(old, new, time)
    return ("%s %s T <t@example.invalid> %d +0000\tcheckout: moving"):format(old, new, time)
  end

  ---A clone whose history is `commits` ({ msg, files = { [path] = text|false } }),
  ---tagged by `tags` ({ [n] = { name, message? } }), detached at the last commit,
  ---updated from commit `from` in the run at TU.
  local function clone(name, commits, tags, from)
    local dir = root .. "/" .. name
    vim.fn.mkdir(dir, "p")
    F.git(dir, { "init", "-q", "-b", "main" })
    local parts = {}
    for i, c in ipairs(commits) do
      local p = ("commit refs/heads/main\nmark :%d\ncommitter T <t@example.invalid> %d +0000\n"):format(
        i,
        T0 + 100 * i
      ) .. F.data(c.msg) .. (i > 1 and ("from :%d\n"):format(i - 1) or "")
      local paths = vim.tbl_keys(c.files or {})
      table.sort(paths)
      for _, path in ipairs(paths) do
        local content = c.files[path]
        if content then
          p = p .. ("M 100644 inline %s\n"):format(path) .. F.data(content)
        else
          p = p .. ("D %s\n"):format(path)
        end
      end
      parts[#parts + 1] = p .. "\n"
    end
    for n, t in pairs(tags or {}) do
      if t.message then
        parts[#parts + 1] = ("tag %s\nfrom :%d\ntagger T <t@example.invalid> %d +0000\n"):format(
          t.name,
          n,
          T0 + 100 * n
        ) .. F.data(t.message) -- (no blank line after a tag: fast-import refuses it)
      else
        parts[#parts + 1] = ("reset refs/tags/%s\nfrom :%d\n\n"):format(t.name, n)
      end
    end
    local marks = F.fast_import(dir, table.concat(parts))
    local last = marks[#commits]
    F.write(dir .. "/.git/HEAD", last .. "\n")
    vim.fn.delete(dir .. "/.git/logs", "rf")
    F.write(dir .. "/.git/logs/HEAD", table.concat({
      line(ZERO, marks[1], T0),
      line(marks[1], marks[from], T0 + 5),
      line(marks[from], last, TU),
    }, "\n") .. "\n")
    return dir, marks
  end

  local function build(names)
    local refs = {}
    for _, name in ipairs(names) do
      refs[#refs + 1] = {
        name = name,
        dir = root .. "/" .. name,
        managed_by = "clones",
        is_local = false,
        spec = { pin = false },
      }
    end
    local box
    report_mod.build({ mode = "updated", refs = refs, persist = false }, function(report)
      box = report
    end)
    vim.wait(30000, function()
      return box ~= nil
    end, 10)
    assert.is_not_nil(box, "report.build called back")
    local by = {}
    for _, e in ipairs(box.plugins) do
      by[e.name] = e
    end
    return by, box
  end

  before_each(function()
    for _, name in ipairs({
      "gitsuite.features.plugins.report",
      "gitsuite.features.plugins.gitlog",
      "gitsuite.features.plugins.summary",
    }) do
      package.loaded[name] = nil
    end
    require("gitsuite.config").setup({})
    report_mod = require("gitsuite.features.plugins.report")
    summary = require("gitsuite.features.plugins.summary")
    root = F.tmpdir("-breaking-clones")
  end)

  after_each(function()
    F.cleanup()
  end)

  it("reads the releases of the range, the directories and the removed modules", function()
    clone("released", {
      { msg = "feat: one", files = { ["lua/demo/old.lua"] = "x", ["README.md"] = "r" } },
      { msg = "feat: two", files = { ["lua/demo/init.lua"] = "1" } },
      { msg = "fix: three", files = { ["lua/demo/init.lua"] = "2" } },
      { msg = "feat!: four", files = { ["lua/demo/old.lua"] = false } },
      { msg = "fix: five", files = { ["queries/kotlin/highlights.scm"] = "q" } },
      { msg = "feat: six", files = { ["doc/demo.txt"] = "d" } },
      { msg = "chore: seven", files = { ["README.md"] = "s" } },
    }, {
      [2] = { name = "v1.0.0" },
      [5] = { name = "v2.0.0-rc.1" },
      [6] = { name = "v2.0.0", message = "Release 2.0.0\n\nBig one." },
    }, 3)
    local by = build({ "released" })
    local e = by.released
    assert.are.equal("forward", e.status)
    assert.are.equal("topo", e.order)
    assert.are.equal(4, #e.commits)

    local names = vim.tbl_map(function(t)
      return t.name
    end, e.tags.range)
    table.sort(names)
    assert.are.same({ "v2.0.0", "v2.0.0-rc.1" }, names)
    assert.are.same(
      { "v1.0.0" },
      vim.tbl_map(function(t)
        return t.name
      end, e.tags.before)
    )
    for _, t in ipairs(e.tags.range) do
      if t.name == "v2.0.0" then assert.are.equal("Release 2.0.0", t.subject) end
    end

    local four
    for _, c in ipairs(e.commits) do
      if c.subject == "feat!: four" then four = c end
    end
    assert.are.same({ "lua/demo/old.lua" }, four.gone)
    assert.are.same({ "lua/demo" }, four.dirs)
    assert.is_not_nil(e.convention)
    assert.are.equal(7, e.convention.total)

    local s = summary.build(e)
    assert.are.equal("major", s.release.kind)
    assert.are.equal("MAJOR v1.0.0 → v2.0.0", summary.release_line(s.release))
    -- feat!: four is commit 1 of 4 in the update (4th of the clone)
    for k, i in ipairs(s.digest.sure) do
      assert.are.equal(1, k)
      assert.are.equal(1, s.digest.positions[i])
    end
    local md = table.concat(summary.markdown(s), "\n")
    assert.is_truthy(md:find("Big one", 1, true) == nil, "only the tag message's first line")
    assert.is_truthy(md:find("Release 2.0.0", 1, true))
  end)

  it("says there is no release tag in the range, and the last one before", function()
    clone("untagged", {
      { msg = "feat: one" },
      { msg = "feat: two" },
      { msg = "fix: three" },
      { msg = "fix: four" },
    }, { [1] = { name = "v0.9.3" } }, 2)
    local e = build({ "untagged" }).untagged
    assert.are.same({}, e.tags.range)
    local s = summary.build(e)
    assert.are.equal("no release tag in this update (last v0.9.3)", summary.release_line(s.release))
  end)

  it("asks for no tags at all in a clone without any", function()
    clone("plain", { { msg = "a" }, { msg = "b" }, { msg = "c" } }, nil, 2)
    local e = build({ "plain" }).plain
    assert.is_nil(e.tags)
    assert.is_nil(summary.build(e).release)
  end)

  it("puts the Breaking column into the rendered report", function()
    clone("marked", { { msg = "feat: a" }, { msg = "feat: b" }, { msg = "feat!: c" } }, nil, 2)
    local _, report = build({ "marked" })
    local md = require("gitsuite.features.plugins.markdown").render(report, TU)
    local joined = table.concat(md, "\n")
    assert.is_truthy(joined:find("| Breaking |", 1, true))
    assert.is_truthy(joined:find("| !1 |", 1, true))
    assert.is_truthy(joined:find(summary.HEURISTIC_NOTE, 1, true))
  end)
end)

describe("gitsuite.features.plugins.state (breaking fields)", function()
  it("keeps order, tags, convention, dirs and removed modules, checked field by field", function()
    local state = require("gitsuite.features.plugins.state")
    local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
    local path = F.tmpdir("-breaking-store") .. "/plugins_reports.json"
    local report = {
      version = state.VERSION,
      id = "r1",
      at = os.time() - 10,
      mode = "updated",
      host = state.host(),
      sources = { "given" },
      plugins = {
        {
          name = "p",
          dir = "/x/p",
          status = "forward",
          source = "reflog",
          confidence = "exact",
          from = sha(1),
          to = sha(2),
          order = "topo",
          tags = {
            range = { { name = "v2.0.0", subject = "x", time = 1 } },
            before = { { name = 5 } },
          },
          convention = { conventional = 3, total = 2 },
          commits = {
            { sha = sha(2), subject = "s", dirs = { "lua/p", 7 }, gone = { "lua/p/x.lua" } },
          },
        },
      },
      heads = {},
      counts = { checked = 1, changed = 1, commits = 1, unchanged = 0 },
      errors = {},
    }
    local ok, err = state.add(report, require("gitsuite.config").get().plugins, path)
    assert(ok, err)
    local store = state.load(path)
    local e = store.reports[1].plugins[1]
    assert.are.equal("topo", e.order)
    assert.are.same({ { name = "v2.0.0", subject = "x", time = 1 } }, e.tags.range)
    assert.are.same({}, e.tags.before, "a tag without a usable name is dropped")
    assert.is_nil(e.convention, "more conventional subjects than subjects is not kept")
    assert.are.same({ "lua/p" }, e.commits[1].dirs)
    assert.are.same({ "lua/p/x.lua" }, e.commits[1].gone)
    F.cleanup()
  end)
end)

describe("gitsuite.config (plugins.breaking)", function()
  local config = require("gitsuite.config")

  after_each(function()
    config.setup({})
  end)

  it("takes valid settings", function()
    local cfg = config.setup({
      plugins = {
        breaking = {
          collapse_repeats = 3,
          ignore = { [[\v^chore]] },
          plugins = { neogit = { style = "none", force = { "abcdef1" }, ignore = { "x" } } },
        },
      },
    })
    assert.are.same({}, config.issues())
    assert.are.equal(3, cfg.plugins.breaking.collapse_repeats)
    assert.are.equal("none", cfg.plugins.breaking.plugins.neogit.style)
  end)

  it("refuses broken patterns, bad hashes and unknown keys", function()
    for _, bad in ipairs({
      { ignore = { [[\v(]] } },
      { collapse_repeats = 0 },
      { plugins = { x = { force = { "xyz" } } } },
      { plugins = { x = { style = "angular" } } },
      { plugins = { x = { colour = true } } },
    }) do
      local cfg = config.setup({ plugins = { breaking = bad } })
      assert.are.equal(1, #config.issues(), vim.inspect(bad))
      assert.are.equal(5, cfg.plugins.breaking.collapse_repeats)
    end
  end)
end)
