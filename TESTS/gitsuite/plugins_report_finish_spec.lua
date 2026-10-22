-- TESTS/gitsuite/plugins_report_finish_spec.lua -- the report tab's last pieces: its highlight
-- groups (made on first open, back after a colorscheme), plugins.ascii, r (read one clone again,
-- in this tab only) and R (a new report), and the progress of :Git plugins report.
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

describe("gitsuite.features.plugins.report_ui finishing", function()
  local ui, window, report, config

  before_each(function()
    for _, mod in ipairs({ "", ".window", ".keys", ".render", ".model", ".seen", ".actions" }) do
      package.loaded["gitsuite.features.plugins.report_ui" .. mod] = nil
    end
    ui = require("gitsuite.features.plugins.report_ui")
    window = require("gitsuite.features.plugins.report_ui.window")
    config = require("gitsuite.config")
    report = dofile(dir_of_spec .. "../fixtures/report_ui_report.lua")
    window.set_seen_path(vim.fn.tempname() .. "/plugins_seen.json")
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
    config.setup({})
    pcall(vim.cmd, "silent! tabonly")
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

  local function line_of(name)
    return table
      .concat(vim.api.nvim_buf_get_lines(S().list_buf, 0, -1, false), "\n")
      :match("[^\n]*" .. vim.pesc(name) .. "[^\n]*")
  end

  it("links every group it draws with, and makes them again after a colorscheme", function()
    local hl = require("gitsuite.features.plugins.report_ui.highlights")
    ui.open(report)
    for group, target in pairs(hl.LINKS) do
      assert.equals(target, vim.api.nvim_get_hl(0, { name = group }).link, group)
    end
    -- every group the report tab's code names has a link (not only those this
    -- fixture happens to draw)
    local src_dir = dir_of_spec .. "../../lua/gitsuite/features/plugins/report_ui/"
    local named = 0
    for _, file in ipairs({ "render.lua", "window.lua" }) do
      local f = assert(io.open(src_dir .. file, "rb"))
      local src = f:read("*a")
      f:close()
      for group in src:gmatch('"(GitSuitePlugins%a+)"') do
        named = named + 1
        assert.is_not_nil(hl.LINKS[group], file .. ": " .. group)
      end
    end
    assert.is_true(named > 10, "the scan found the groups")
    -- A colorscheme resets groups (`:hi clear`); a `default` link survives that in
    -- current Neovim, and the ColorScheme handler sets them again regardless.
    assert.equals(
      1,
      #vim.api.nvim_get_autocmds({ group = "gitsuite_plugins_report_hl", event = "ColorScheme" })
    )
    vim.cmd("highlight clear")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    for group, target in pairs(hl.LINKS) do
      assert.equals(target, vim.api.nvim_get_hl(0, { name = group }).link, group)
    end
  end)

  it("a user's own colour for a group stays (default = true)", function()
    vim.api.nvim_set_hl(0, "GitSuitePluginsSha", { fg = "#123456" })
    ui.open(report)
    local got = vim.api.nvim_get_hl(0, { name = "GitSuitePluginsSha" })
    assert.is_nil(got.link)
    assert.equals(tonumber("123456", 16), got.fg)
    vim.api.nvim_set_hl(0, "GitSuitePluginsSha", {})
  end)

  it("plugins.ascii draws the glyphs in ASCII, the words stay", function()
    config.setup({ plugins = { ascii = true } })
    ui.open(report)
    assert.truthy(line_of("mason.nvim"):find("^%^ updated"), line_of("mason.nvim"))
    assert.truthy(line_of("broken.nvim"):find("^x error"), line_of("broken.nvim"))
  end)

  it("an error row says r reads it again", function()
    ui.open(report)
    assert.truthy(
      line_of("broken.nvim"):find("(r reads it again)", 1, true),
      line_of("broken.nvim")
    )
  end)

  it("r reads the clone again and replaces its row in this tab only", function()
    local builder = require("gitsuite.features.plugins.report")
    local sources = require("gitsuite.features.plugins.sources")
    local asked
    with(sources, "list", function()
      return { { name = "broken.nvim", dir = "/lazy/broken.nvim", managed_by = "lazy", spec = {} } }, {
        "lazy",
      }, {}
    end, function()
      with(builder, "build", function(opts, cb)
        asked = opts
        cb({
          plugins = {
            {
              name = "broken.nvim",
              dir = "/lazy/broken.nvim",
              status = "forward",
              from = sha("1"),
              to = sha("2"),
              head = sha("2"),
              commits = {
                { sha = sha("e"), subject = "fix: readable again", author = "x", body = "" },
              },
            },
          },
        }, {})
        return { stop = function() end }
      end, function()
        ui.open(report)
        goto_key({ name = "broken.nvim" })
        press("r")
      end)
    end)
    assert.is_false(asked.persist, "nothing is stored")
    assert.equals("updated", asked.mode)
    assert.equals("/lazy/broken.nvim", asked.refs[1].dir)
    local l = line_of("broken.nvim")
    assert.truthy(l:find("1 commit", 1, true), l)
    assert.is_nil(l:find("error", 1, true), l)
  end)

  it("r on a clone that shows no change now drops its row; one not installed says so", function()
    local builder = require("gitsuite.features.plugins.report")
    local sources = require("gitsuite.features.plugins.sources")
    local infos = {}
    local notify = require("gitsuite.util.notify")
    with(notify, "info", function(msg)
      infos[#infos + 1] = msg
    end, function()
      with(sources, "list", function()
        return { { name = "mason.nvim", dir = "/lazy/mason.nvim", managed_by = "lazy", spec = {} } }, {}, {}
      end, function()
        with(builder, "build", function(_, cb)
          cb({ plugins = {} }, {})
          return { stop = function() end }
        end, function()
          ui.open(report)
          goto_key({ name = "mason.nvim" })
          press("r")
          goto_key({ name = "telescope.nvim" })
          press("r")
        end)
      end)
    end)
    assert.is_nil(line_of("mason.nvim"), "mason's row is gone")
    local all = table.concat(infos, "\n")
    assert.truthy(all:find("mason.nvim shows no change now", 1, true), all)
    assert.truthy(all:find("telescope.nvim is not installed", 1, true), all)
  end)

  it("R builds a new report in the same mode", function()
    local plugins = require("gitsuite.features.plugins")
    local asked
    with(plugins, "report", function(opts)
      asked = opts
    end, function()
      ui.open(report)
      press("R")
    end)
    assert.same({ mode = "updated" }, asked)
  end)
end)

describe(":Git plugins report progress", function()
  it("reports how many clones were read and finishes with the result", function()
    local plugins = require("gitsuite.features.plugins")
    local builder = require("gitsuite.features.plugins.report")
    local progress = require("gitsuite.util.progress")
    local events = {}
    local handle = {
      update = function(_, u)
        events[#events + 1] = ("update %d/%d"):format(u.current, u.total)
      end,
      finish = function(_, t)
        events[#events + 1] = "finish " .. t
      end,
    }
    local done
    with(progress, "create", function()
      return handle
    end, function()
      with(builder, "build", function(opts, cb)
        opts.on_progress(1, 2)
        opts.on_progress(2, 2)
        vim.schedule(function()
          cb({
            id = "x",
            mode = "updated",
            at = 1,
            plugins = {},
            counts = { checked = 2, changed = 0, commits = 0, unchanged = 2 },
            errors = {},
          }, {})
        end)
        return { stop = function() end }
      end, function()
        plugins.report({
          open = false,
          on_done = function()
            done = true
          end,
        })
        assert.is_true(vim.wait(2000, function()
          return done == true
        end, 10))
      end)
    end)
    assert.same({ "update 1/2", "update 2/2", "finish plugins report: 0 of 2 changed" }, events)
  end)
end)
