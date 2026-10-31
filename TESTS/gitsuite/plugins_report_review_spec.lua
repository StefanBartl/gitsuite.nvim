-- TESTS/gitsuite/plugins_report_review_spec.lua -- what the review of the report tab (015747b ..
-- 6d15390) found: r against the store as it was, the preview left as the last window, an
-- answer that comes at once, marks kept for the session, one name for two clones, a stopped
-- build's progress, a stale schedule after a rebuild, and the smaller ones.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local function sha(c)
  return string.rep(c, 40)
end

local function with(mod, key, value, fn)
  local saved = mod[key]
  mod[key] = value
  local ok, err = pcall(fn)
  mod[key] = saved
  assert(ok, err)
end

local editor_scope = dofile(dir_of_spec .. "editor_scope.lua")
describe("report.build with before (r reads against the store as it was)", function()
  editor_scope.install()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local state = require("gitsuite.features.plugins.state")
  local builder = require("gitsuite.features.plugins.report")

  after_each(function()
    F.cleanup()
  end)

  it("the snapshot fallback sees the older report, not the one shown", function()
    local dir = F.init("-snap")
    F.write(dir .. "/a.lua", "1\n")
    local old = F.commit(dir, "old state")
    F.write(dir .. "/a.lua", "2\n")
    local now = F.commit(dir, "new state")
    -- No usable reflog (expired, never written): the case the snapshot is for.
    vim.fn.delete(dir .. "/.git/logs", "rf")
    local store = F.tmpdir("-store") .. "/plugins_reports.json"
    local cfg = { keep_reports = 20, max_age_days = 36500 }
    local function stored(id, at, head)
      return {
        version = 1,
        id = id,
        at = at,
        mode = "updated",
        plugins = {},
        heads = { [dir] = head },
        counts = { checked = 1, changed = 0, commits = 0, unchanged = 1 },
        errors = {},
      }
    end
    assert.is_true((state.add(stored("older", 1700000000, old), cfg, store)))
    assert.is_true((state.add(stored("shown", 1700000100, now), cfg, store)))
    local ref = {
      name = "snap",
      dir = dir,
      managed_by = "clones",
      is_local = false,
      spec = { pin = false },
    }

    local function build(before)
      local got
      builder.build({
        refs = { ref },
        mode = "updated",
        persist = false,
        store_path = store,
        before = before,
      }, function(r)
        got = r
      end)
      assert.is_true(vim.wait(10000, function()
        return got ~= nil
      end, 10))
      return got
    end

    assert.equals(0, #build(nil).plugins, "against the shown report the clone did not move")
    local again = build({ id = "shown", at = 1700000100 })
    assert.equals(1, #again.plugins)
    assert.equals("snapshot", again.plugins[1].source)
    assert.equals(old, again.plugins[1].from)
  end)
end)

describe("report tab review fixes", function()
  -- window.reset() first: it deletes the WinClosed handler before the report tab is closed.
  editor_scope.install({ manual = true })
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local ui, window, model, report

  before_each(function()
    for _, mod in ipairs({ "", ".window", ".keys", ".render", ".model", ".seen", ".preview" }) do
      package.loaded["gitsuite.features.plugins.report_ui" .. mod] = nil
    end
    ui = require("gitsuite.features.plugins.report_ui")
    window = require("gitsuite.features.plugins.report_ui.window")
    model = require("gitsuite.features.plugins.report_ui.model")
    report = dofile(dir_of_spec .. "../fixtures/report_ui_report.lua")
    window.set_seen_path(vim.fn.tempname() .. "/plugins_seen.json")
  end)

  after_each(function()
    window.reset()
    editor_scope.restore()
    F.cleanup()
  end)

  local function S()
    return window.state()
  end

  local function press(lhs)
    for _, mp in ipairs(vim.api.nvim_buf_get_keymap(S().list_buf, "n")) do
      if mp.lhs == lhs then return mp.callback() end
    end
    error("no mapping " .. lhs)
  end

  local function goto_key(key)
    local line = require("gitsuite.features.plugins.report_ui.render").find(S().rendered, key)
    assert.is_not_nil(line, vim.inspect(key))
    vim.api.nvim_set_current_win(S().list_win)
    vim.api.nvim_win_set_cursor(S().list_win, { line, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = S().list_buf })
  end

  it("a commit hash that is no hash shows its answer, not loading", function()
    report.plugins[1].commits[2].sha = "not-a-hash"
    ui.open(report)
    press("<CR>")
    goto_key({ name = "telescope.nvim", sha = "not-a-hash" })
    local text = table.concat(vim.api.nvim_buf_get_lines(S().preview_buf, 0, -1, false), "\n")
    assert.truthy(text:find("Files: not a commit hash", 1, true), text)
  end)

  it("marks the file did not take survive q and :Git plugins", function()
    local blocker = vim.fn.tempname()
    F.write(blocker, "a file, so no folder can be made below it")
    window.set_seen_path(blocker .. "/sub/plugins_seen.json")
    local warns = {}
    local notify = require("gitsuite.util.notify")
    with(notify, "warn", function(msg)
      warns[#warns + 1] = msg
    end, function()
      ui.open(report)
      goto_key({ name = "telescope.nvim" })
      press("m")
    end)
    assert.truthy(table.concat(warns, "\n"):find("kept for this session", 1, true))
    press("q")
    ui.open_last()
    assert.is_true(model.is_seen(S().model, "telescope.nvim", sha("a")))
  end)

  it("two clones of one name are two rows, two summaries", function()
    local twin = vim.deepcopy(report.plugins[2])
    twin.dir = "/own/mason.nvim"
    twin.commits = { { sha = sha("9"), subject = "feat: my own change", author = "me", body = "" } }
    table.insert(report.plugins, twin)
    local m = model.new(report)
    local names = {}
    for _, e in ipairs(model.entries(m)) do
      names[#names + 1] = e.name
    end
    assert.is_true(vim.tbl_contains(names, "mason.nvim"))
    assert.is_true(vim.tbl_contains(names, "mason.nvim (/own/mason.nvim)"))
    assert.equals(6, model.summary(m, model.entry(m, "mason.nvim")).count)
    assert.equals(1, model.summary(m, model.entry(m, "mason.nvim (/own/mason.nvim)")).count)
    assert.equals(
      "mason.nvim",
      report.plugins[#report.plugins].name,
      "the stored report is not changed"
    )
  end)

  it("a rebuild in the same tick is not undone by the closing tab's schedule", function()
    ui.open(report)
    local tab = S().tab
    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tab))
    ui.open_last()
    vim.wait(100)
    assert.is_true(S().preview_on)
    assert.is_true(S().preview_win ~= nil and vim.api.nvim_win_is_valid(S().preview_win))
  end)

  it("]] from a plugin that is gone starts at the first", function()
    local m = model.show(model.new(report), { kind = "detail", name = "telescope.nvim" })
    m.view = { kind = "detail", name = "gone.nvim" }
    assert.equals("telescope.nvim", model.step_plugin(m, 1).view.name)
    assert.equals("mason.nvim", model.step_plugin(m, -1).view.name)
  end)

  it(":Git plugins shows a report stored after the one in the tab", function()
    local store = F.tmpdir("-store") .. "/plugins_reports.json"
    local state = require("gitsuite.features.plugins.state")
    ui.open(report)
    press("q")
    local newer = vim.deepcopy(report)
    newer.id, newer.at = "newer", report.at + 60
    assert.is_true((state.add(newer, { keep_reports = 20, max_age_days = 36500 }, store)))
    ui.open_last({ store_path = store })
    assert.equals("newer", S().model.report.id)
  end)

  it("a rollback's compare page goes from the new state to the old one", function()
    local links = require("gitsuite.features.plugins.links")
    local actions = require("gitsuite.features.plugins.report_ui.actions")
    with(links, "compare_url", function(_, a, b)
      return a .. "..." .. b
    end, function()
      local url = actions.url(model.new(report), { kind = "plugin", name = "gitsigns.nvim" })
      assert.equals(sha("5") .. "..." .. sha("6"), url)
    end)
  end)
end)

describe("preview loader review fixes", function()
  editor_scope.install()
  local preview

  before_each(function()
    package.loaded["gitsuite.features.plugins.report_ui.preview"] = nil
    preview = require("gitsuite.features.plugins.report_ui.preview")
  end)

  after_each(function()
    package.loaded["gitsuite.features.plugins.report_ui.preview"] = nil
  end)

  local function loader(run)
    return preview.new({
      run = run,
      partial = function()
        return false
      end,
      defer = function(fn)
        fn()
      end,
    })
  end

  it("a failed answer is asked for again once ERROR_TTL_MS passed", function()
    local runs = 0
    local l = loader(function(_, _, cb)
      runs = runs + 1
      cb({ code = 128, stdout = "", stderr = "fatal: busy" }, nil)
      return { stop = function() end }
    end)
    l:request("/c", sha("a"), function() end)
    assert.is_not_nil(l:cached("/c", sha("a")), "kept for a while: no loop")
    preview.ERROR_TTL_MS = -1
    l:request("/c", sha("b"), function() end)
    assert.is_nil(l:cached("/c", sha("b")), "then dropped")
    assert.equals(2, runs)
  end)

  it("a hit keeps an entry from being evicted (LRU)", function()
    preview.CACHE_MAX = 2
    local l = loader(function(args, _, cb)
      cb({ code = 0, stdout = ":1 1 a b M\0" .. args[#args] .. "\0" }, nil)
      return { stop = function() end }
    end)
    for _, c in ipairs({ "a", "b" }) do
      l:request("/c", sha(c), function() end)
    end
    assert.is_not_nil(l:cached("/c", sha("a")), "a is used again")
    l:request("/c", sha("c"), function() end)
    assert.is_not_nil(l:cached("/c", sha("a")), "a stays")
    assert.is_nil(l:cached("/c", sha("b")), "b, the least recently used, goes")
  end)

  it("stop reaches the newest process, not one that already ended", function()
    local stopped = {}
    local pending = {}
    local l = preview.new({
      run = function(args, _, cb)
        local id = args[#args]
        pending[id] = cb
        return {
          stop = function()
            stopped[#stopped + 1] = id
          end,
        }
      end,
      partial = function()
        return false
      end,
      defer = function(fn)
        fn()
      end,
    })
    l:request("/c", sha("a"), function() end)
    l:request("/c", sha("b"), function() end)
    pending[sha("a")]({ code = 0, stdout = "" }, nil)
    l:stop()
    assert.same({ sha("b") }, stopped)
  end)
end)

describe("seen marks review fixes", function()
  editor_scope.install()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local seen = require("gitsuite.features.plugins.report_ui.seen")

  after_each(function()
    F.cleanup()
  end)

  it("a plugin name with @ is kept", function()
    local path = F.tmpdir("-s") .. "/plugins_seen.json"
    local key = "me@work.nvim@" .. sha("a")
    seen.update({ [key] = true }, { path = path, ttl_days = 10, now = 1790000000 })
    assert.is_not_nil((seen.load(path))[key])
  end)

  it("a file that cannot be read is left alone, not moved aside", function()
    local dir = F.tmpdir("-s")
    local path = dir .. "/plugins_seen.json"
    vim.fn.mkdir(path, "p") -- a folder where the file should be
    local _, err = seen.update({ ["a@" .. sha("1")] = true }, { path = path, ttl_days = 10 })
    assert.truthy(err and err:find("left as they are", 1, true), err)
    assert.equals(1, vim.fn.isdirectory(path))
    assert.equals(0, vim.fn.filereadable(path .. ".corrupt"))
  end)

  it("a second broken file in the same second does not overwrite the first", function()
    local path = F.tmpdir("-s") .. "/plugins_seen.json"
    for _, text in ipairs({ "{ first", "{ second" }) do
      F.write(path, text)
      seen.update({ ["a@" .. sha("1")] = true }, { path = path, ttl_days = 10, now = 1790000000 })
    end
    local function read(p)
      local f = assert(io.open(p, "rb"))
      local t = f:read("*a")
      f:close()
      return t
    end
    assert.equals("{ first", read(path .. ".corrupt"))
    assert.equals("{ second", read(path .. ".corrupt.1790000000.1"))
  end)
end)

describe("a stopped report build", function()
  editor_scope.install()
  it("finishes its progress", function()
    local plugins = require("gitsuite.features.plugins")
    local builder = require("gitsuite.features.plugins.report")
    local progress = require("gitsuite.util.progress")
    local finished = {}
    with(progress, "create", function()
      return {
        update = function() end,
        finish = function(_, t)
          finished[#finished + 1] = t
        end,
      }
    end, function()
      with(builder, "build", function()
        return { stop = function() end }
      end, function()
        local handle = plugins.report({ open = false, quiet = false })
        assert.is_not_nil(handle)
        handle.stop()
      end)
    end)
    assert.same({ "plugins report: stopped" }, finished)
  end)
end)
