-- TESTS/gitsuite/plugins_report_window_spec.lua -- the report tab: its windows and buffers, the
-- layout, the keys, the preview following the cursor, closing and rebuilding it, and the key table
-- against docs/BINDINGS.md. A fixture report (TESTS/fixtures/report_ui_report.lua); no process.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local editor_scope = dofile(dir_of_spec .. "editor_scope.lua")
describe("gitsuite.features.plugins.report_ui window", function()
  -- window.reset() first: it deletes the WinClosed handler before the report tab is closed.
  editor_scope.install({ manual = true })
  local ui, window, keys, report
  local columns

  local function sha(c)
    return string.rep(c, 40)
  end

  local function S()
    return window.state()
  end

  local function lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  ---Run the report tab's mapping for `lhs`, as a key press would.
  local function press(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(S().list_buf, "n")) do
      if m.lhs == lhs or vim.fn.keytrans(m.lhs) == lhs then
        m.callback()
        return
      end
    end
    error("no report mapping for " .. lhs)
  end

  ---Put the cursor on the line of `key` and let the preview follow.
  local function goto_key(key)
    local line = require("gitsuite.features.plugins.report_ui.render").find(S().rendered, key)
    assert.is_not_nil(line, vim.inspect(key))
    vim.api.nvim_set_current_win(S().list_win)
    vim.api.nvim_win_set_cursor(S().list_win, { line, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = S().list_buf })
  end

  local function cursor_item()
    return S().rendered.items[vim.api.nvim_win_get_cursor(S().list_win)[1]]
  end

  before_each(function()
    columns = vim.o.columns
    for _, mod in ipairs({ "", ".window", ".keys", ".render", ".model" }) do
      package.loaded["gitsuite.features.plugins.report_ui" .. mod] = nil
    end
    ui = require("gitsuite.features.plugins.report_ui")
    window = require("gitsuite.features.plugins.report_ui.window")
    -- Never the real stdpath("state"): marks go to a file of this spec.
    window.set_seen_path(vim.fn.tempname() .. "/plugins_seen.json")
    keys = require("gitsuite.features.plugins.report_ui.keys")
    report = dofile(dir_of_spec .. "../fixtures/report_ui_report.lua")
  end)

  after_each(function()
    window.reset()
    editor_scope.restore()
    vim.o.columns = columns
  end)

  it("opens a tab of its own with a list and a preview, both fixed to their buffers", function()
    local tabs = #vim.api.nvim_list_tabpages()
    ui.open(report)
    assert.equals(tabs + 1, #vim.api.nvim_list_tabpages())
    assert.equals(S().tab, vim.api.nvim_get_current_tabpage())
    assert.is_true(vim.t[S().tab].gitsuite_plugins_report)
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(S().tab))

    for _, buf in ipairs({ S().list_buf, S().preview_buf }) do
      assert.equals("nofile", vim.bo[buf].buftype)
      assert.equals("hide", vim.bo[buf].bufhidden)
      assert.is_false(vim.bo[buf].modifiable)
    end
    assert.is_true(vim.wo[S().list_win].winfixbuf)
    assert.is_true(vim.wo[S().preview_win].winfixbuf)
    assert.truthy(
      vim.api.nvim_buf_get_name(S().list_buf):find("gitsuite://plugins/report", 1, true)
    )

    local l = lines(S().list_buf)
    assert.truthy(l[1]:find("plugins updated", 1, true), l[1])
    assert.same({ kind = "plugin", name = "telescope.nvim" }, cursor_item())

    -- winfixbuf: another buffer cannot be put into the list window.
    vim.api.nvim_set_current_win(S().list_win)
    local scratch = vim.api.nvim_create_buf(true, false)
    assert.is_false(pcall(vim.cmd, "buffer " .. scratch))
    assert.equals(S().list_buf, vim.api.nvim_win_get_buf(S().list_win))
    vim.api.nvim_buf_delete(scratch, { force = true })
  end)

  it("puts the preview to the right from 140 columns on, below otherwise", function()
    vim.o.columns = 160
    ui.open(report)
    local lp, pp =
      vim.api.nvim_win_get_position(S().list_win), vim.api.nvim_win_get_position(S().preview_win)
    assert.equals(lp[1], pp[1], "same row")
    assert.is_true(pp[2] > lp[2], "to the right")
    window.reset()
    pcall(vim.cmd, "silent! tabonly")

    vim.o.columns = 100
    ui.open(report)
    lp, pp =
      vim.api.nvim_win_get_position(S().list_win), vim.api.nvim_win_get_position(S().preview_win)
    assert.equals(lp[2], pp[2], "same column")
    assert.is_true(pp[1] > lp[1], "below")
  end)

  it("D, <CR>, <BS> and s change the view and keep the cursor on its key", function()
    ui.open(report)
    goto_key({ name = "mason.nvim" })
    press("s")
    assert.equals("name", S().model.sort)
    assert.same(
      { kind = "plugin", name = "mason.nvim" },
      cursor_item(),
      "the cursor stays on mason"
    )

    press("D")
    assert.truthy(lines(S().list_buf)[1]:find("breaking digest", 1, true))
    goto_key({ name = "telescope.nvim", sha = sha("a") })
    press("<CR>")
    assert.equals("detail", S().model.view.kind)
    assert.equals(sha("a"), cursor_item().sha, "detail opens on the commit")

    press("<BS>")
    assert.equals("overview", S().model.view.kind)
    assert.same({ kind = "plugin", name = "telescope.nvim" }, cursor_item())

    press("<CR>")
    assert.equals("telescope.nvim", S().model.view.name)
    press("]]")
    assert.equals("broken.nvim", S().model.view.name, "the next plugin in the name sort")
    press("[[")
    assert.equals("telescope.nvim", S().model.view.name)
  end)

  it("the preview follows the cursor onto a commit", function()
    ui.open(report)
    assert.equals("Move to a commit to see its message here", lines(S().preview_buf)[1])
    press("<CR>")
    goto_key({ name = "telescope.nvim", sha = sha("b") })
    assert.equals("fix: keep the cursor in the prompt", lines(S().preview_buf)[1])
    -- The files are asked for (the fixture's clones do not exist: the answer is
    -- that they are not available, never a list).
    assert.truthy(table.concat(lines(S().preview_buf), "\n"):find("Files: loading...", 1, true))
    assert.is_true(vim.wait(2000, function()
      return table.concat(lines(S().preview_buf), "\n"):find("Files: not available", 1, true) ~= nil
    end, 10))
  end)

  it("]b jumps to the next breaking commit", function()
    ui.open(report)
    press("D")
    goto_key({ name = "telescope.nvim", sha = sha("a") })
    vim.api.nvim_win_set_cursor(S().list_win, { 1, 0 })
    press("]b")
    assert.equals(sha("a"), cursor_item().sha)
  end)

  it("p closes and reopens the preview; closing the preview alone turns it off", function()
    ui.open(report)
    press("p")
    assert.is_nil(S().preview_win)
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(S().tab))
    press("p")
    assert.is_not_nil(S().preview_win)
    vim.api.nvim_win_close(S().preview_win, true)
    -- (decided one tick later: a whole tab closing must not turn it off)
    assert.is_true(vim.wait(500, function()
      return S().preview_on == false
    end, 10))
  end)

  it("the summary line is never cut: two lines next to the preview, one without it", function()
    vim.o.columns = 160
    ui.open(report)
    local function fits()
      local width = vim.api.nvim_win_get_width(S().list_win)
      for i, l in ipairs(lines(S().list_buf)) do
        if S().rendered.items[i].kind == "summary" and vim.fn.strdisplaywidth(l) > width then
          return false
        end
      end
      return true
    end
    local function summary_lines()
      local n = 0
      for i = 1, #S().rendered.lines do
        if S().rendered.items[i].kind == "summary" then n = n + 1 end
      end
      return n
    end
    assert.is_true(fits())
    assert.equals(2, summary_lines())
    assert.same({ kind = "plugin", name = "telescope.nvim" }, cursor_item())
    -- p: the list takes the whole width, the summary one line again
    press("p")
    assert.is_true(fits())
    assert.equals(1, summary_lines())
    assert.same({ kind = "plugin", name = "telescope.nvim" }, cursor_item())
    press("p")
    assert.equals(2, summary_lines())
    -- a resize by hand (WinResized) lays it out anew as well
    vim.api.nvim_win_set_width(S().list_win, 150)
    vim.api.nvim_exec_autocmds("WinResized", {})
    assert.is_true(fits())
    assert.equals(1, summary_lines())
  end)

  it("an empty view puts the cursor on its message under a two-line summary", function()
    vim.o.columns = 140
    report.plugins = {}
    ui.open(report)
    local r = S().rendered
    assert.equals("summary", r.items[2].kind)
    local line = vim.api.nvim_win_get_cursor(S().list_win)[1]
    assert.equals("No plugin changed since the last sync", r.lines[line])
  end)

  it("closing the list window closes the preview with it", function()
    ui.open(report)
    local p = S().preview_win
    vim.api.nvim_win_close(S().list_win, true)
    vim.wait(200, function()
      return not vim.api.nvim_win_is_valid(p)
    end, 10)
    assert.is_false(vim.api.nvim_win_is_valid(p))
  end)

  it("q closes the tab, goes back, and :Git plugins rebuilds it on the same commit", function()
    local origin = vim.api.nvim_get_current_tabpage()
    ui.open(report)
    press("<CR>")
    goto_key({ name = "telescope.nvim", sha = sha("c") })
    local list_buf = S().list_buf
    press("q")
    assert.is_nil(S().tab)
    assert.equals(origin, vim.api.nvim_get_current_tabpage())
    assert.is_true(vim.api.nvim_buf_is_valid(list_buf), "the buffer stays")

    assert.is_true(ui.open_last())
    assert.equals(list_buf, vim.api.nvim_win_get_buf(S().list_win))
    assert.equals("detail", S().model.view.kind, "the view is kept")
    assert.equals(sha("c"), cursor_item().sha, "the cursor is back on the commit")
  end)

  it("survives :tabclose and :only in another tab", function()
    ui.open(report)
    goto_key({ name = "mason.nvim" })
    local report_tab = S().tab
    vim.cmd("tabnew")
    vim.cmd("vsplit")
    vim.cmd("only")
    assert.is_true(vim.api.nvim_tabpage_is_valid(report_tab))
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(report_tab))

    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(report_tab))
    assert.is_false(vim.api.nvim_tabpage_is_valid(report_tab))
    -- Let what the closing scheduled run, as it would before anyone types :Git plugins.
    vim.wait(50)
    ui.open_last()
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(S().tab))
    assert.same({ kind = "plugin", name = "mason.nvim" }, cursor_item())
    assert.is_true(vim.wo[S().list_win].winfixbuf)
  end)

  it(":Git plugins without a report says how to make one", function()
    local infos = {}
    local notify = require("gitsuite.util.notify")
    local saved = notify.info
    notify.info = function(msg)
      infos[#infos + 1] = msg
    end
    local ok = ui.open_last({ store_path = vim.fn.tempname() .. "/none.json" })
    notify.info = saved
    assert.is_false(ok)
    assert.truthy(table.concat(infos, "\n"):find(":Git plugins report builds one", 1, true))
  end)

  it("the winbar legend shows the keys of the current view", function()
    ui.open(report)
    local overview = window.legend()
    assert.truthy(overview:find("s sort", 1, true), overview)
    assert.truthy(overview:find("? keys", 1, true), overview)
    press("D")
    local digest = window.legend()
    assert.is_nil(digest:find("s sort", 1, true), digest)
    assert.truthy(digest:find("<BS> back", 1, true), digest)
    -- Narrow: entries go from the right, "? keys" stays.
    assert.equals(" ? keys", keys.legend("overview", 10))
  end)

  it("the ? list names every key", function()
    local help = table.concat(keys.help_lines(), "\n")
    for _, k in ipairs(keys.KEYS) do
      assert.truthy(help:find(k.desc, 1, true), k.desc)
      -- The ? popup does not wrap: a longer text was cut at 120 columns (seen in
      -- a real TUI).
      assert.is_true(#k.desc <= 100, ("%d chars: %s"):format(#k.desc, k.desc))
      for _, lhs in ipairs(k.keys) do
        assert.truthy(help:find(lhs, 1, true), lhs)
      end
    end
  end)

  it("binds exactly the keys of the table", function()
    ui.open(report)
    local bound = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(S().list_buf, "n")) do
      -- (lhs comes back readable already: "<CR>", "]]")
      bound[m.lhs] = true
    end
    for _, k in ipairs(keys.KEYS) do
      for _, lhs in ipairs(k.keys) do
        assert.is_true(bound[lhs] == true, lhs)
      end
    end
    assert.is_nil(bound["gS"], "no AI key without a plugins.summarize hook")
  end)

  it(
    "with a plugins.summarize hook gS asks for the plugin under the cursor and shows it",
    function()
      local ai = require("gitsuite.features.plugins.ai_summary")
      local saved = { hook = ai.hook, key = ai.key, request = ai.request }
      local asked
      ai.hook = function()
        return function() end
      end
      ai.key = function()
        return "gS"
      end
      ai.request = function(rep, name, opts)
        asked = name
        for _, e in ipairs(rep.plugins) do
          if e.name == name then
            e.ai_summary =
              { text = "Drops the old layout API.", provider = "fake", at = 1790000000 }
            opts.on_done(e.ai_summary)
          end
        end
        return true
      end
      local ok, err = pcall(function()
        ui.open(report)
        goto_key({ name = "telescope.nvim" })
        press("gS")
        assert.equals("telescope.nvim", asked)
        press("<CR>")
        local text = table.concat(lines(S().list_buf), "\n")
        assert.truthy(
          text:find("AI SUMMARY (fake, ", 1, true) and text:find("not verified", 1, true),
          text
        )
        assert.truthy(text:find("  Drops the old layout API.", 1, true), text)
      end)
      ai.hook, ai.key, ai.request = saved.hook, saved.key, saved.request
      assert(ok, err)
    end
  )

  it("a plugin's detail shows where the commit under the cursor stands (c i/n)", function()
    local render = require("gitsuite.features.plugins.report_ui.render")
    local model = require("gitsuite.features.plugins.report_ui.model")
    local m = model.new(report)
    -- telescope's list is the whole update in topological order: 1 is the oldest
    assert.same({ 3, 3 }, { render.position(m, "telescope.nvim", sha("a")) })
    assert.same({ 1, 3 }, { render.position(m, "telescope.nvim", sha("c")) })
    -- mason's order is not known: no position rather than a guess
    assert.is_nil((render.position(m, "mason.nvim", sha("d"))))
    assert.is_nil((render.position(m, "telescope.nvim", sha("f"))))

    ui.open(report)
    press("<CR>")
    goto_key({ name = "telescope.nvim", sha = sha("a") })
    assert.truthy(window.legend():find("%=%#GitSuitePluginsSha#c 3/3", 1, true), window.legend())
    goto_key({ name = "telescope.nvim", sha = sha("c") })
    assert.truthy(window.legend():find("c 1/3", 1, true), window.legend())
    goto_key({ name = "telescope.nvim" })
    assert.is_nil(window.legend():find("%=", 1, true), "no position on the plugin line")
    press("<BS>")
    goto_key({ name = "mason.nvim" })
    press("<CR>")
    goto_key({ name = "mason.nvim", sha = sha("d") })
    assert.is_nil(window.legend():find("%=", 1, true), "none where the order is not known")
  end)

  it("docs/BINDINGS.md lists the key table row by row", function()
    local doc = io.open(dir_of_spec .. "../../docs/BINDINGS.md", "r")
    assert.is_not_nil(doc)
    local text = doc:read("*a")
    doc:close()
    local section = text:match("## Plugins report keys %(component%-local%)(.-)\n## ")
    assert.is_not_nil(section, "no 'Plugins report keys' section")
    local rows = {}
    for row in section:gmatch("\n(| `[^\n]*)") do
      rows[#rows + 1] = (row:gsub("\r$", ""))
    end
    assert.same(keys.doc_rows(), rows)
  end)
end)
