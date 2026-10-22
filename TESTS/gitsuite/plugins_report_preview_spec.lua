-- TESTS/gitsuite/plugins_report_preview_spec.lua -- the file list of the report's preview:
-- report_ui.preview (parser, loader with cache, debounce and stale guard), gitfs.partial_clone,
-- the diff-tree allowance in gitlog, the rendering of the files, the preview window waiting for
-- them, and one run against a real repository.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local function sha(c)
  return string.rep(c, 40)
end

local RAW_M = ":100644 100644 " .. sha("1") .. " " .. sha("2") .. " M"
local RAW_A = ":000000 100644 " .. sha("0") .. " " .. sha("3") .. " A"
local RAW_D = ":100644 000000 " .. sha("4") .. " " .. sha("0") .. " D"

---`-z` output: tokens joined by NUL, ending with one.
local function z(tokens)
  return table.concat(tokens, "\0") .. "\0"
end

describe("gitsuite.features.plugins.report_ui.preview", function()
  local preview

  before_each(function()
    package.loaded["gitsuite.features.plugins.report_ui.preview"] = nil
    preview = require("gitsuite.features.plugins.report_ui.preview")
  end)

  after_each(function()
    -- Cases here lower MAX_FILES / CACHE_MAX: later blocks get a fresh module.
    package.loaded["gitsuite.features.plugins.report_ui.preview"] = nil
  end)

  it("asks for --numstat only when the contents are there", function()
    local full = preview.args(sha("a"), true)
    local partial = preview.args(sha("a"), false)
    assert.equals("diff-tree", full[1])
    assert.is_true(vim.tbl_contains(full, "--numstat"))
    assert.is_false(vim.tbl_contains(partial, "--numstat"))
    for _, a in ipairs({ "--raw", "-z", "--no-renames", "--root", "-r" }) do
      assert.is_true(vim.tbl_contains(partial, a), a)
    end
    assert.equals(sha("a"), partial[#partial])
  end)

  it("parses raw entries in order and matches the numstat lines by path", function()
    local out = z({
      RAW_M,
      "lua/a.lua",
      RAW_A,
      "docs/with space.md",
      RAW_D,
      "img/logo.png",
      "12\t3\tlua/a.lua",
      "7\t0\tdocs/with space.md",
      "-\t-\timg/logo.png",
    })
    local files, more = preview.parse(out)
    assert.equals(0, more)
    assert.same({ status = "M", path = "lua/a.lua", adds = 12, dels = 3 }, files[1])
    assert.same({ status = "A", path = "docs/with space.md", adds = 7, dels = 0 }, files[2])
    assert.same({ status = "D", path = "img/logo.png", binary = true }, files[3])
  end)

  it("parses raw-only output (a partial clone) and cuts at MAX_FILES", function()
    preview.MAX_FILES = 2
    local files, more = preview.parse(z({ RAW_M, "a", RAW_A, "b", RAW_D, "c" }))
    assert.same({ { status = "M", path = "a" }, { status = "A", path = "b" } }, files)
    assert.equals(1, more)
    assert.same({}, (preview.parse("")))
  end)

  describe("loader", function()
    local runs, pending, deferred

    ---A fake runner: records the call; `answer(i, res)` completes call i.
    local function fake_run(args, dir, on_done)
      runs[#runs + 1] = { args = args, dir = dir }
      pending[#runs] = on_done
      return { stop = function() end }
    end

    local function answer(i, res)
      local cb = pending[i]
      pending[i] = nil
      cb(res, nil)
    end

    local function flush()
      local list = deferred
      deferred = {}
      for _, fn in ipairs(list) do
        fn()
      end
    end

    local function loader(partial)
      return preview.new({
        run = fake_run,
        partial = function()
          return partial
        end,
        defer = function(fn)
          deferred[#deferred + 1] = fn
        end,
      })
    end

    before_each(function()
      runs, pending, deferred = {}, {}, {}
    end)

    it("runs nothing until the wait is over, and only the newest of a burst", function()
      local l = loader(false)
      local got = {}
      for _, c in ipairs({ "a", "b", "c" }) do
        l:request("/clone", sha(c), function(v)
          got[#got + 1] = { c, v }
        end)
      end
      assert.equals(0, #runs, "debounced: nothing ran yet")
      flush()
      assert.equals(1, #runs, "one process for three requests")
      assert.equals(sha("c"), runs[1].args[#runs[1].args])
      answer(1, { code = 0, stdout = z({ RAW_M, "x.lua", "1\t1\tx.lua" }) })
      assert.equals(1, #got)
      assert.equals("c", got[1][1])
      assert.is_true(got[1][2].counts)
      assert.equals(1, got[1][2].files[1].adds)
    end)

    it("an answer that arrives after a newer request is cached, not shown", function()
      local l = loader(false)
      local shown = {}
      l:request("/clone", sha("a"), function()
        shown[#shown + 1] = "a"
      end)
      flush()
      l:request("/clone", sha("b"), function()
        shown[#shown + 1] = "b"
      end)
      answer(1, { code = 0, stdout = z({ RAW_M, "a.lua" }) })
      assert.same({}, shown, "a is stale: b was asked for since")
      assert.is_not_nil(l:cached("/clone", sha("a")), "but a is kept")
      flush()
      answer(2, { code = 0, stdout = z({ RAW_M, "b.lua" }) })
      assert.same({ "b" }, shown)
    end)

    it("answers from the cache without a process, and forgets the oldest past CACHE_MAX", function()
      preview.CACHE_MAX = 2
      local l = loader(false)
      for _, c in ipairs({ "a", "b", "c" }) do
        l:request("/clone", sha(c), function() end)
        flush()
        answer(#runs, { code = 0, stdout = z({ RAW_M, c }) })
      end
      assert.equals(3, #runs)
      local hit
      l:request("/clone", sha("c"), function(v)
        hit = v
      end)
      assert.equals(3, #runs, "a cache hit starts nothing")
      assert.equals("c", hit.files[1].path)
      assert.is_nil(l:cached("/clone", sha("a")), "the oldest was dropped")
      assert.is_not_nil(l:cached("/clone", sha("b")))
    end)

    it("a partial clone gets the files without counts, and says why", function()
      local l = loader(true)
      local v
      l:request("/clone", sha("a"), function(x)
        v = x
      end)
      flush()
      assert.is_false(vim.tbl_contains(runs[1].args, "--numstat"))
      answer(1, { code = 0, stdout = z({ RAW_M, "a.lua" }) })
      assert.is_false(v.counts)
      assert.is_true(v.partial)
    end)

    it("a failed git names the reason; a bad hash never reaches git", function()
      local l = loader(false)
      local v
      l:request("/clone", sha("a"), function(x)
        v = x
      end)
      flush()
      answer(
        1,
        { code = 128, stdout = "", stderr = "warning: x\nfatal: bad object " .. sha("a") .. "\n" }
      )
      assert.equals("not available locally (fatal: bad object " .. sha("a") .. ")", v.error)

      local bad
      l:request("/clone", "--output=/tmp/x", function(x)
        bad = x
      end)
      flush()
      assert.equals(1, #runs, "no process for a value that is no hash")
      assert.equals("not a commit hash", bad.error)
    end)
  end)
end)

describe("gitsuite.features.plugins.gitfs.partial_clone", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local gitfs = require("gitsuite.features.plugins.gitfs")

  after_each(function()
    F.cleanup()
  end)

  local function clone_with(config)
    local dir = F.tmpdir("-partial")
    vim.fn.mkdir(dir .. "/.git", "p")
    if config then F.write(dir .. "/.git/config", config) end
    return dir
  end

  it("tells a blobless clone from a full one by its config", function()
    assert.is_true(gitfs.partial_clone(clone_with('[remote "origin"]\n\tpromisor = true\n')))
    assert.is_true(gitfs.partial_clone(clone_with("[extensions]\n\tpartialClone = origin\n")))
    assert.is_true(gitfs.partial_clone(clone_with('[remote "origin"]\n\tpromisor\n')))
    assert.is_false(gitfs.partial_clone(clone_with('[remote "origin"]\n\tpromisor = false\n')))
    assert.is_false(gitfs.partial_clone(clone_with('[remote "origin"]\n\turl = x\n')))
    assert.is_nil(gitfs.partial_clone(clone_with(nil)), "no config: unknown")
  end)
end)

describe("gitsuite.features.plugins.gitlog allows diff-tree", function()
  local gitlog = require("gitsuite.features.plugins.gitlog")
  local preview = require("gitsuite.features.plugins.report_ui.preview")

  it("passes the preview's arguments and locks out external diff programs", function()
    assert.is_true((gitlog.check(preview.args(sha("a"), true))))
    local argv = gitlog.argv(preview.args(sha("a"), true))
    assert.is_true(vim.tbl_contains(argv, "--no-ext-diff"))
    assert.is_true(vim.tbl_contains(argv, "--no-textconv"))
    assert.is_false((gitlog.check({ "diff-tree", "-p", sha("a") })), "no patch output")
    assert.is_false((gitlog.check({ "diff-tree", "--ext-diff", sha("a") })))
  end)
end)

describe("gitsuite.features.plugins.report_ui.render preview files", function()
  local model = require("gitsuite.features.plugins.report_ui.model")
  local render = require("gitsuite.features.plugins.report_ui.render")
  local report

  before_each(function()
    report = dofile(dir_of_spec .. "../fixtures/report_ui_report.lua")
  end)

  local function text_of(files)
    local m = model.new(report)
    return table.concat(render.render_preview(m, "telescope.nvim", sha("a"), files).lines, "\n")
  end

  it("lists the files with their line counts and a total", function()
    local t = text_of({
      counts = true,
      files = {
        { status = "M", path = "lua/a.lua", adds = 12, dels = 3 },
        { status = "D", path = "img/logo.png", binary = true },
      },
    })
    assert.truthy(t:find("Files (2)  +12 -3", 1, true), t)
    assert.truthy(t:find("  M +12 -3  lua/a.lua", 1, true), t)
    assert.truthy(t:find("  D bin     img/logo.png", 1, true), t)
  end)

  it("says why a blobless clone has no counts, and how many files are not listed", function()
    local t = text_of({
      counts = false,
      partial = true,
      more = 4,
      files = { { status = "M", path = "lua/a.lua" } },
    })
    assert.truthy(t:find("Files (5)\n  M lua/a.lua\n  ... and 4 more", 1, true), t)
    assert.truthy(t:find("blobless", 1, true), t)
    assert.is_nil(t:find("+", 1, true), t)
  end)

  it("names an empty file list", function()
    assert.truthy(text_of({ counts = true, files = {} }):find("No file changes", 1, true))
  end)
end)

describe("gitsuite.features.plugins.report_ui window waits for the files", function()
  local ui, window, report
  local requests

  before_each(function()
    for _, mod in ipairs({ "", ".window", ".keys", ".render", ".model" }) do
      package.loaded["gitsuite.features.plugins.report_ui" .. mod] = nil
    end
    ui = require("gitsuite.features.plugins.report_ui")
    window = require("gitsuite.features.plugins.report_ui.window")
    -- Never the real stdpath("state"): marks go to a file of this spec.
    window.set_seen_path(vim.fn.tempname() .. "/plugins_seen.json")
    report = dofile(dir_of_spec .. "../fixtures/report_ui_report.lua")
    requests = {}
    local cache = {}
    window.set_loader({
      cached = function(_, dir, s)
        return cache[dir .. "@" .. s]
      end,
      request = function(_, dir, s, on_done)
        requests[#requests + 1] = {
          sha = s,
          answer = function(v)
            cache[dir .. "@" .. s] = v
            on_done(v)
          end,
        }
      end,
      stop = function() end,
    })
  end)

  after_each(function()
    window.reset()
    pcall(vim.cmd, "silent! tabonly")
  end)

  local function goto_sha(s)
    local st = window.state()
    local line = require("gitsuite.features.plugins.report_ui.render").find(
      st.rendered,
      { name = "telescope.nvim", sha = s }
    )
    vim.api.nvim_set_current_win(st.list_win)
    vim.api.nvim_win_set_cursor(st.list_win, { line, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = st.list_buf })
  end

  local function preview_text()
    local st = window.state()
    return table.concat(vim.api.nvim_buf_get_lines(st.preview_buf, 0, -1, false), "\n")
  end

  it(
    "shows loading, then the files; a late answer for a commit left behind is not shown",
    function()
      ui.open(report)
      local st = window.state()
      st.model = require("gitsuite.features.plugins.report_ui.model").show(
        st.model,
        { kind = "detail", name = "telescope.nvim" }
      )
      window.redraw()
      goto_sha(sha("a"))
      assert.truthy(preview_text():find("Files: loading...", 1, true))
      local a = requests[#requests]
      assert.equals(sha("a"), a.sha)

      goto_sha(sha("b"))
      local asked = #requests
      a.answer({ counts = false, files = { { status = "M", path = "only-a.lua" } } })
      assert.is_nil(preview_text():find("only-a.lua", 1, true), "a's answer must not land on b")
      assert.equals(asked, #requests, "a late answer for a does not ask for b again")
      assert.truthy(preview_text():find("fix: keep the cursor in the prompt", 1, true))

      requests[#requests].answer({ counts = false, files = { { status = "A", path = "b.lua" } } })
      assert.truthy(preview_text():find("  A b.lua", 1, true), preview_text())

      local n = #requests
      goto_sha(sha("a"))
      assert.equals(n, #requests, "a is cached now: no new request")
      assert.truthy(preview_text():find("only-a.lua", 1, true))
    end
  )
end)

describe("gitsuite.features.plugins.report_ui.preview against a real repository", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local preview = require("gitsuite.features.plugins.report_ui.preview")

  after_each(function()
    F.cleanup()
  end)

  it("lists the files of a commit with their counts, the root commit too", function()
    local dir = F.init("-preview")
    F.write(dir .. "/a.lua", "one\n")
    local root = F.commit(dir, "first")
    F.write(dir .. "/a.lua", "one\ntwo\nthree\n")
    F.write(dir .. "/dir/b.md", "x\n")
    local second = F.commit(dir, "second")

    local function load(s)
      local l = preview.new({
        defer = function(fn)
          fn()
        end,
      })
      local got
      l:request(dir, s, function(v)
        got = v
      end)
      assert.is_true(vim.wait(10000, function()
        return got ~= nil
      end, 10))
      return got
    end

    local v = load(second)
    assert.is_nil(v.error, v.error)
    assert.is_true(v.counts)
    table.sort(v.files, function(x, y)
      return x.path < y.path
    end)
    assert.same({
      { status = "M", path = "a.lua", adds = 2, dels = 0 },
      { status = "A", path = "dir/b.md", adds = 1, dels = 0 },
    }, v.files)

    local r = load(root)
    assert.same({ { status = "A", path = "a.lua", adds = 1, dels = 0 } }, r.files)
  end)
end)
