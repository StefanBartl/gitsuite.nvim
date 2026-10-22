-- TESTS/gitsuite/plugins_report_seen_spec.lua -- the report tab's seen marks: the marks file
-- (report_ui.seen: merge with what another editor wrote, expiry, a broken or newer file), the m/M
-- keys and ]b in the tab, and a clone whose HEAD moved since the report.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local function sha(c)
  return string.rep(c, 40)
end

local NOW = 1790000000
local DAY = 86400

describe("gitsuite.features.plugins.report_ui.seen (the marks file)", function()
  local seen, path

  before_each(function()
    package.loaded["gitsuite.features.plugins.report_ui.seen"] = nil
    seen = require("gitsuite.features.plugins.report_ui.seen")
    path = vim.fn.tempname() .. "/gitsuite/plugins_seen.json"
  end)

  local function write_raw(text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  it("starts empty without a file and writes what is marked", function()
    local marks, info = seen.load(path)
    assert.same({}, marks)
    assert.same({}, info)
    local now_marks, err = seen.update(
      { ["a.nvim@" .. sha("1")] = true },
      { path = path, ttl_days = 10, now = NOW }
    )
    assert.is_nil(err)
    assert.same({ ["a.nvim@" .. sha("1")] = NOW }, now_marks)
    assert.same({ ["a.nvim@" .. sha("1")] = NOW }, (seen.load(path)))
  end)

  it("merges into what another editor wrote meanwhile, and unmarks", function()
    seen.update({ ["a.nvim@" .. sha("1")] = true }, { path = path, ttl_days = 10, now = NOW })
    -- another editor, which read the file before the first write, adds its own mark
    seen.update({ ["b.nvim@" .. sha("2")] = true }, { path = path, ttl_days = 10, now = NOW + 1 })
    local marks = seen.load(path)
    assert.equals(NOW, marks["a.nvim@" .. sha("1")], "the first editor's mark is still there")
    assert.equals(NOW + 1, marks["b.nvim@" .. sha("2")])
    seen.update({ ["a.nvim@" .. sha("1")] = false }, { path = path, ttl_days = 10, now = NOW + 2 })
    assert.same({ ["b.nvim@" .. sha("2")] = NOW + 1 }, (seen.load(path)))
  end)

  it("drops marks older than seen_ttl_days on the next write", function()
    seen.update(
      { ["old@" .. sha("1")] = true },
      { path = path, ttl_days = 30, now = NOW - 31 * DAY }
    )
    seen.update({ ["new@" .. sha("2")] = true }, { path = path, ttl_days = 30, now = NOW })
    local marks = seen.load(path)
    assert.is_nil(marks["old@" .. sha("1")])
    assert.equals(NOW, marks["new@" .. sha("2")])
  end)

  it("moves a broken file aside instead of writing over it", function()
    write_raw("{ this is not json")
    local marks, info = seen.load(path)
    assert.same({}, marks)
    assert.is_not_nil(info.error)
    local _, err = seen.update(
      { ["a@" .. sha("1")] = true },
      { path = path, ttl_days = 10, now = NOW }
    )
    assert.is_nil(err)
    local f = assert(io.open(path .. ".corrupt", "rb"))
    assert.equals("{ this is not json", f:read("*a"), "the old content is kept")
    f:close()
    assert.same({ ["a@" .. sha("1")] = NOW }, (seen.load(path)))
  end)

  it("leaves a file of a newer gitsuite alone", function()
    write_raw(vim.json.encode({ version = 99, seen = { ["a@" .. sha("1")] = NOW } }))
    local before = assert(io.open(path, "rb")):read("*a")
    local _, err = seen.update(
      { ["b@" .. sha("2")] = true },
      { path = path, ttl_days = 10, now = NOW }
    )
    assert.truthy(err and err:find("newer gitsuite", 1, true), err)
    assert.equals(before, assert(io.open(path, "rb")):read("*a"))
    assert.equals(NOW, (seen.load(path))["a@" .. sha("1")], "but its marks are read")
  end)

  it("reads only well-formed marks", function()
    write_raw(vim.json.encode({
      version = 1,
      seen = {
        ["ok.nvim@" .. sha("a")] = NOW,
        ["no-sha"] = NOW,
        ["x@zz"] = NOW,
        ["bad@" .. sha("b")] = "yesterday",
        ["future@" .. sha("c")] = 9999999999,
      },
    }))
    assert.same({ ["ok.nvim@" .. sha("a")] = NOW }, (seen.load(path)))
  end)
end)

describe("gitsuite.features.plugins.report_ui seen marks in the tab", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local ui, window, seen, report, path

  before_each(function()
    for _, mod in ipairs({ "", ".window", ".keys", ".render", ".model", ".seen" }) do
      package.loaded["gitsuite.features.plugins.report_ui" .. mod] = nil
    end
    ui = require("gitsuite.features.plugins.report_ui")
    window = require("gitsuite.features.plugins.report_ui.window")
    seen = require("gitsuite.features.plugins.report_ui.seen")
    report = dofile(dir_of_spec .. "../fixtures/report_ui_report.lua")
    path = vim.fn.tempname() .. "/plugins_seen.json"
    window.set_loader({
      cached = function()
        return { counts = false, files = {} }
      end,
      request = function() end,
      stop = function() end,
    })
  end)

  after_each(function()
    window.reset()
    pcall(vim.cmd, "silent! tabonly")
    F.cleanup()
  end)

  local function S()
    return window.state()
  end

  local function press(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(S().list_buf, "n")) do
      if m.lhs == lhs then return m.callback() end
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

  local function list_text()
    return table.concat(vim.api.nvim_buf_get_lines(S().list_buf, 0, -1, false), "\n")
  end

  it("m on a plugin marks its new commits and writes them; m again unmarks", function()
    ui.open(report, { seen_path = path })
    goto_key({ name = "telescope.nvim" })
    assert.truthy(list_text():find("3 unseen", 1, true))
    press("m")
    assert.is_nil(list_text():find("3 unseen", 1, true), list_text())
    local marks = seen.load(path)
    for _, c in ipairs({ "a", "b", "c" }) do
      assert.is_not_nil(marks["telescope.nvim@" .. sha(c)], c)
    end
    press("m")
    assert.truthy(list_text():find("3 unseen", 1, true))
    assert.same({}, (seen.load(path)))
  end)

  it("m on a commit marks that one; on a removed commit it says there is nothing new", function()
    ui.open(report, { seen_path = path })
    goto_key({ name = "telescope.nvim" })
    press("<CR>")
    goto_key({ name = "telescope.nvim", sha = sha("b") })
    press("m")
    assert.same({ "telescope.nvim@" .. sha("b") }, vim.tbl_keys(seen.load(path)))

    local infos = {}
    local notify = require("gitsuite.util.notify")
    local saved = notify.info
    notify.info = function(msg)
      infos[#infos + 1] = msg
    end
    press("<BS>")
    goto_key({ name = "gitsigns.nvim" })
    press("<CR>")
    goto_key({ name = "gitsigns.nvim", sha = sha("9") })
    press("m")
    notify.info = saved
    assert.truthy(table.concat(infos, "\n"):find("removed commit is not new", 1, true))
    assert.equals(1, #vim.tbl_keys(seen.load(path)))
  end)

  it("M marks every commit the view lists, in one write", function()
    ui.open(report, { seen_path = path })
    press("M")
    assert.equals(9, #vim.tbl_keys(seen.load(path)), "3 telescope + 6 mason")
    assert.is_nil(list_text():find("unseen", 1, true), list_text())
  end)

  it("]b skips breaking commits already seen", function()
    seen.update({ ["telescope.nvim@" .. sha("a")] = true }, { path = path, ttl_days = 10 })
    local infos = {}
    local notify = require("gitsuite.util.notify")
    local saved = notify.info
    notify.info = function(msg)
      infos[#infos + 1] = msg
    end
    ui.open(report, { seen_path = path })
    press("D")
    vim.api.nvim_win_set_cursor(S().list_win, { 1, 0 })
    press("]b")
    notify.info = saved
    assert.equals(1, vim.api.nvim_win_get_cursor(S().list_win)[1], "nothing unseen to jump to")
    assert.truthy(table.concat(infos, "\n"):find("no unseen breaking commit", 1, true))
  end)

  it("reopening reads the marks fresh: another editor's marks show up", function()
    ui.open(report, { seen_path = path })
    goto_key({ name = "mason.nvim" })
    assert.truthy(list_text():find("6 unseen", 1, true))
    -- another Neovim marks two of mason's commits meanwhile
    seen.update({
      ["mason.nvim@" .. sha("d")] = true,
      ["mason.nvim@" .. sha("e")] = true,
    }, { path = path, ttl_days = 10 })
    press("q")
    ui.open_last()
    assert.truthy(list_text():find("4 unseen", 1, true), list_text())
  end)

  it("a clone whose HEAD moved since the report says so", function()
    local dir = F.init("-moved")
    F.write(dir .. "/a.lua", "1\n")
    local first = F.commit(dir, "first")
    F.write(dir .. "/a.lua", "2\n")
    F.commit(dir, "second")
    -- the report saw the clone at `first`; it is at `second` now
    report.plugins[2].dir = dir
    report.plugins[2].head = first
    ui.open(report, { seen_path = path })
    local text = list_text()
    local mason = text:match("[^\n]*mason%.nvim[^\n]*")
    assert.truthy(mason:find("moved since the report", 1, true), mason)
    local tel = text:match("[^\n]*telescope%.nvim[^\n]*")
    assert.is_nil(tel:find("moved", 1, true), "a clone that cannot be read is not called moved")
  end)
end)
