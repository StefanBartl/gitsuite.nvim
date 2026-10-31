-- TESTS/gitsuite/plugins_report_actions_spec.lua -- the report tab's opening keys: which URL,
-- hash, CHANGELOG and quickfix items (report_ui.actions, pure), the clone's status and the compare
-- URL against real repositories, and the keys in the tab with the browser, the clipboard, lazygit,
-- the menu and the picker stubbed.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local function sha(c)
  return string.rep(c, 40)
end

---Replace `mod[key]` for the duration of `fn`.
local function with(mod, key, value, fn)
  local saved = mod[key]
  mod[key] = value
  local ok, err = pcall(fn)
  mod[key] = saved
  assert(ok, err)
end

local editor_scope = dofile(dir_of_spec .. "editor_scope.lua")
describe("gitsuite.features.plugins.report_ui.actions (pure)", function()
  editor_scope.install()
  local actions, model, links, report, m
  local opened

  before_each(function()
    package.loaded["gitsuite.features.plugins.report_ui.actions"] = nil
    actions = require("gitsuite.features.plugins.report_ui.actions")
    model = require("gitsuite.features.plugins.report_ui.model")
    links = require("gitsuite.features.plugins.links")
    report = dofile(dir_of_spec .. "../fixtures/report_ui_report.lua")
    m = model.new(report)
    opened = {}
  end)

  local function stub_links(fn)
    with(links, "commit_url", function(dir, s)
      opened[#opened + 1] = "commit " .. dir .. " " .. s
      return "https://forge/" .. s
    end, function()
      with(links, "compare_url", function(dir, a, b)
        opened[#opened + 1] = "compare " .. dir .. " " .. a .. ".." .. b
        return "https://forge/compare/" .. a .. "..." .. b
      end, fn)
    end)
  end

  it("a commit line opens the commit, and only that commit counts as seen", function()
    stub_links(function()
      local url, err, seen =
        actions.url(m, { kind = "commit", name = "telescope.nvim", sha = sha("b") })
      assert.is_nil(err)
      assert.equals("https://forge/" .. sha("b"), url)
      assert.same({ { name = "telescope.nvim", sha = sha("b") } }, seen)
    end)
  end)

  it(
    "a plugin line, or go, opens the compare page of the update; all its new commits count",
    function()
      stub_links(function()
        local url, _, seen = actions.url(m, { kind = "plugin", name = "telescope.nvim" })
        assert.equals("https://forge/compare/" .. sha("1") .. "..." .. sha("2"), url)
        assert.equals(3, #seen)
        local url2 =
          actions.url(m, { kind = "commit", name = "telescope.nvim", sha = sha("b") }, true)
        assert.equals(url, url2, "go forces the compare page from a commit line")
      end)
    end
  )

  it("a removed commit opens but is nothing new; a fresh install opens where it landed", function()
    stub_links(function()
      local _, _, seen = actions.url(m, { kind = "commit", name = "gitsigns.nvim", sha = sha("9") })
      assert.same({}, seen)
      local url, _, seen2 = actions.url(m, { kind = "plugin", name = "fresh.nvim" })
      assert.equals("https://forge/" .. sha("7"), url)
      assert.same({}, seen2)
      local none, err = actions.url(m, { kind = "plugin", name = "broken.nvim" })
      assert.is_nil(none)
      assert.truthy(err)
      assert.is_nil((actions.url(m, { kind = "blank" })))
    end)
  end)

  it("y / Y copy the short / full hash; a plugin line gives where its update ended", function()
    local it = { kind = "commit", name = "telescope.nvim", sha = sha("b") }
    assert.equals("bbbbbbb", actions.hash(m, it))
    assert.equals(sha("b"), actions.hash(m, it, true))
    assert.equals("2222222", actions.hash(m, { kind = "plugin", name = "telescope.nvim" }))
    assert.is_nil(actions.hash(m, { kind = "plugin", name = "broken.nvim" }))
  end)

  it("finds the CHANGELOG at the top of a clone, whatever its case", function()
    local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
    local dir = F.tmpdir("-cl")
    assert.is_nil(actions.changelog(dir))
    F.write(dir .. "/News.md", "x")
    assert.equals(dir .. "/News.md", actions.changelog(dir))
    F.write(dir .. "/CHANGELOG.md", "x")
    assert.equals(dir .. "/CHANGELOG.md", actions.changelog(dir), "CHANGELOG before NEWS")
    assert.is_nil(actions.changelog(dir .. "/nope"))
    F.cleanup()
  end)

  it("puts the breaking commits into quickfix items, sure first", function()
    local items = actions.breaking_items(m)
    assert.equals(1, #items)
    assert.equals(
      "telescope.nvim  aaaaaaa  [sure] feat(picker)!: drop the old layout API",
      items[1].text
    )
    assert.same({ name = "telescope.nvim", sha = sha("a") }, items[1].user_data)
  end)
end)

describe("gitsuite.features.plugins.report_ui.actions against real clones", function()
  editor_scope.install()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local actions = require("gitsuite.features.plugins.report_ui.actions")
  local links = require("gitsuite.features.plugins.links")

  after_each(function()
    F.cleanup()
  end)

  it("S reads the status and the last commits, read only", function()
    local dir = F.init("-status")
    F.write(dir .. "/a.lua", "1\n")
    F.commit(dir, "first commit")
    F.write(dir .. "/new.txt", "x\n")
    local lines
    actions.status(dir, function(l)
      lines = l
    end)
    assert.is_true(vim.wait(10000, function()
      return lines ~= nil
    end, 10))
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("## main", 1, true), text)
    assert.truthy(text:find("?? new.txt", 1, true), text)
    assert.truthy(text:find("Recent commits", 1, true), text)
    assert.truthy(text:find("first commit", 1, true), text)
    assert.is_nil(vim.uv.fs_stat(dir .. "/.git/index.lock"), "no lock left")
  end)

  it("builds the compare URL of a GitHub clone", function()
    local dir = F.init("-forge")
    F.git(dir, { "remote", "add", "origin", "https://github.com/owner/repo.git" })
    local url = links.compare_url(dir, sha("1"), sha("2"))
    assert.equals("https://github.com/owner/repo/compare/" .. sha("1") .. "..." .. sha("2"), url)
    assert.is_nil((links.compare_url(dir, "--x", sha("2"))))
  end)
end)

describe("gitsuite.features.plugins.gitlog allows status for S", function()
  editor_scope.install()
  local gitlog = require("gitsuite.features.plugins.gitlog")

  it("passes status --short --branch, and nothing of status anywhere else", function()
    assert.is_true((gitlog.check({ "status", "--short", "--branch" })))
    assert.is_false((gitlog.check({ "status", "--porcelain=v2" })))
    assert.is_false((gitlog.check({ "log", "--short" })), "--short belongs to status only")
    assert.is_false((gitlog.check({ "log", "--branch" })))
  end)
end)

describe("gitsuite.features.plugins.report_ui opening keys in the tab", function()
  editor_scope.install()
  local ui, window, report, seen_path
  local links, view, lazygit, kit

  before_each(function()
    for _, mod in ipairs({ "", ".window", ".keys", ".render", ".model", ".seen", ".actions" }) do
      package.loaded["gitsuite.features.plugins.report_ui" .. mod] = nil
    end
    ui = require("gitsuite.features.plugins.report_ui")
    window = require("gitsuite.features.plugins.report_ui.window")
    links = require("gitsuite.features.plugins.links")
    view = require("gitsuite.features.plugins.view")
    lazygit = require("gitsuite.features.ui.lazygit")
    kit = require("ui.kit")
    report = dofile(dir_of_spec .. "../fixtures/report_ui_report.lua")
    seen_path = vim.fn.tempname() .. "/plugins_seen.json"
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
    pcall(vim.cmd, "silent! cclose")
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
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
  end

  it("o opens the commit in the browser and marks it as seen", function()
    local opened = {}
    with(links, "commit_url", function(_, s)
      return "https://forge/" .. s
    end, function()
      with(links, "open", function(url)
        opened[#opened + 1] = url
        return true
      end, function()
        ui.open(report, { seen_path = seen_path })
        press("<CR>")
        goto_key({ name = "telescope.nvim", sha = sha("b") })
        press("o")
      end)
    end)
    assert.same({ "https://forge/" .. sha("b") }, opened)
    local marks = require("gitsuite.features.plugins.report_ui.seen").load(seen_path)
    assert.is_not_nil(marks["telescope.nvim@" .. sha("b")])
  end)

  it("a browser that cannot open marks nothing", function()
    with(links, "commit_url", function(_, s)
      return "https://forge/" .. s
    end, function()
      with(links, "open", function()
        return false, "no opener"
      end, function()
        ui.open(report, { seen_path = seen_path })
        press("<CR>")
        goto_key({ name = "telescope.nvim", sha = sha("b") })
        press("o")
      end)
    end)
    assert.same({}, (require("gitsuite.features.plugins.report_ui.seen").load(seen_path)))
  end)

  it("y and Y copy the hash, gy the URL", function()
    local copied = {}
    with(view, "copy", function(v)
      copied[#copied + 1] = v
      return true
    end, function()
      with(links, "commit_url", function(_, s)
        return "https://forge/" .. s
      end, function()
        ui.open(report, { seen_path = seen_path })
        press("<CR>")
        goto_key({ name = "telescope.nvim", sha = sha("c") })
        press("y")
        press("Y")
        press("gy")
      end)
    end)
    assert.same({ "ccccccc", sha("c"), "https://forge/" .. sha("c") }, copied)
  end)

  it("L opens lazygit in the plugin's clone", function()
    local dirs = {}
    with(lazygit, "open", function(dir)
      dirs[#dirs + 1] = dir
    end, function()
      ui.open(report, { seen_path = seen_path })
      goto_key({ name = "mason.nvim" })
      press("L")
    end)
    assert.same({ "/lazy/mason.nvim" }, dirs)
  end)

  it("C opens the CHANGELOG read only in the tab the report came from", function()
    local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
    local dir = F.tmpdir("-clone")
    F.write(dir .. "/CHANGELOG.md", "# Changes\n")
    report.plugins[2].dir = dir
    -- The origin window shows a named buffer: `:edit` would otherwise reuse the editor's empty
    -- start buffer for the CHANGELOG, and that one cannot be wiped afterwards.
    F.write(dir .. "/start.txt", "start\n")
    editor_scope.open_file(dir .. "/start.txt")
    local origin = vim.api.nvim_get_current_tabpage()
    ui.open(report, { seen_path = seen_path })
    local report_tab = S().tab
    goto_key({ name = "mason.nvim" })
    press("C")
    assert.equals(origin, vim.api.nvim_get_current_tabpage())
    assert.equals("# Changes", vim.api.nvim_get_current_line())
    assert.is_false(vim.bo.modifiable)
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(report_tab), "the report tab is untouched")
    editor_scope.restore()
    F.cleanup()
  end)

  it(
    "Q fills the quickfix list with the breaking commits, opened outside the report tab",
    function()
      local origin = vim.api.nvim_get_current_tabpage()
      ui.open(report, { seen_path = seen_path })
      local report_tab = S().tab
      press("Q")
      local qf = vim.fn.getqflist({ title = 1, items = 1 })
      assert.equals("gitsuite plugins: breaking commits", qf.title)
      assert.equals(1, #qf.items)
      assert.equals(origin, vim.api.nvim_get_current_tabpage())
      assert.equals("quickfix", vim.bo.buftype)
      assert.equals(2, #vim.api.nvim_tabpage_list_wins(report_tab))
    end
  )

  it("O offers the actions of the view, F jumps to a commit", function()
    local menu, picker
    with(kit, "menu", function(o)
      menu = o
    end, function()
      with(kit, "picker", function(o)
        picker = o
      end, function()
        ui.open(report, { seen_path = seen_path })
        press("O")
        press("F")
      end)
    end)
    local labels = table.concat(
      vim.tbl_map(function(x)
        return x.label
      end, menu.items),
      "\n"
    )
    assert.truthy(labels:find("o  Open in the browser", 1, true), labels)
    assert.is_nil(labels:find("Menu of the actions", 1, true), "the menu does not list itself")
    assert.is_nil(labels:find("Back to the overview", 1, true), "<BS> does nothing in the overview")

    local target
    for _, x in ipairs(picker.items) do
      if x.sha == sha("e") then target = x end
    end
    assert.is_not_nil(target)
    assert.truthy(target.label:find("mason.nvim  eeeeeee", 1, true), target.label)
    picker.on_submit(nil, nil, target)
    assert.equals("detail", S().model.view.kind)
    assert.equals("mason.nvim", S().model.view.name)
    local item = S().rendered.items[vim.api.nvim_win_get_cursor(S().list_win)[1]]
    assert.equals(sha("e"), item.sha)
  end)
end)
