-- TESTS/gitsuite/plugins_report_ui_spec.lua -- the report tab's model and renderer against a
-- fixture report (TESTS/fixtures/report_ui_report.lua). Pure: no window, no process, no file.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("gitsuite.features.plugins.report_ui", function()
  local model, render, report

  local function sha(c)
    return string.rep(c, 40)
  end

  ---Names of the plugin lines, in order.
  local function plugin_names(r)
    local out = {}
    for i = 1, #r.lines do
      if r.items[i].kind == "plugin" then out[#out + 1] = r.items[i].name end
    end
    return out
  end

  ---The line `item` stands on (1-based), checking the item agrees.
  local function line_of(r, name, s)
    local i = render.find(r, { name = name, sha = s })
    assert.is_not_nil(i, ("no line for %s %s"):format(name, s or ""))
    return r.lines[i], i
  end

  ---Highlight groups that cover the 0-based line `row`.
  local function hls(r, row)
    local out = {}
    for _, mk in ipairs(r.marks) do
      if mk.line == row then out[mk.hl] = true end
    end
    return out
  end

  before_each(function()
    package.loaded["gitsuite.features.plugins.report_ui.model"] = nil
    package.loaded["gitsuite.features.plugins.report_ui.render"] = nil
    model = require("gitsuite.features.plugins.report_ui.model")
    render = require("gitsuite.features.plugins.report_ui.render")
    report = dofile(dir_of_spec .. "../fixtures/report_ui_report.lua")
  end)

  describe("overview", function()
    it("starts with a summary line and lists the changed plugins, breaking first", function()
      local r = render.render(model.new(report))
      assert.truthy(r.lines[1]:find("plugins updated", 1, true), r.lines[1])
      assert.truthy(
        r.lines[1]:find("5 changed, 9 commits, 1 breaking, 9 unseen", 1, true),
        r.lines[1]
      )
      assert.equals("summary", r.items[1].kind)
      assert.same(
        { "telescope.nvim", "broken.nvim", "fresh.nvim", "gitsigns.nvim", "mason.nvim" },
        plugin_names(r)
      )
    end)

    it("says every state with a glyph and a word", function()
      local r = render.render(model.new(report))
      local tel, row = line_of(r, "telescope.nvim")
      assert.truthy(tel:find("! breaking", 1, true), tel)
      assert.truthy(tel:find("1111111..2222222 (v0.2.0)", 1, true), tel)
      assert.truthy(tel:find("3 commits, • 3 unseen", 1, true), tel)
      assert.is_true(hls(r, row - 1).GitSuitePluginsBreaking == true)

      assert.truthy(line_of(r, "broken.nvim"):find("✗ error", 1, true))
      assert.truthy(line_of(r, "broken.nvim"):find("HEAD names no commit", 1, true))
      assert.truthy(line_of(r, "gitsigns.nvim"):find("↓ rollback", 1, true))
      assert.truthy(line_of(r, "gitsigns.nvim"):find("1 removed", 1, true))
      assert.truthy(line_of(r, "mason.nvim"):find("↑ updated", 1, true))
      -- A fresh install has no "from": only where it landed, no "?..".
      local fresh = line_of(r, "fresh.nvim")
      assert.truthy(fresh:find("+ new", 1, true), fresh)
      assert.is_nil(fresh:find("?..", 1, true), fresh)
      for _, l in ipairs(r.lines) do
        assert.is_nil(l:find("%s$"), "no trailing blanks: '" .. l .. "'")
      end
    end)

    it("uses ASCII glyphs when asked", function()
      local r = render.render(model.new(report, { ascii = true }))
      assert.truthy(line_of(r, "mason.nvim"):find("^%^ updated"), line_of(r, "mason.nvim"))
      assert.truthy(line_of(r, "broken.nvim"):find("^x error"))
      assert.truthy(line_of(r, "telescope.nvim"):find("* 3 unseen", 1, true))
      for _, l in ipairs(r.lines) do
        assert.is_nil(l:find("[\128-\255]") and not l:find("·", 1, true) and l or nil, l)
      end
    end)

    it("marks a clone whose HEAD moved since the report, and only that one", function()
      local m = model.new(
        report,
        { heads = { ["/lazy/mason.nvim"] = sha("e"), ["/lazy/telescope.nvim"] = sha("2") } }
      )
      local r = render.render(m)
      assert.truthy(line_of(r, "mason.nvim"):find("↻ moved since the report", 1, true))
      -- ("since the report", not "moved": gitsigns' "1 removed" contains that word.)
      assert.is_nil(line_of(r, "telescope.nvim"):find("since the report", 1, true))
      -- Not checked at all: nothing is called moved.
      assert.is_nil(
        table.concat(render.render(model.new(report)).lines, "\n"):find("since the report", 1, true)
      )
    end)

    it("counts the unchanged plugins, and A lists them", function()
      local m = model.new(report)
      local r = render.render(m)
      assert.equals("2 unchanged (A lists them)", r.lines[#r.lines])
      local all = render.render(model.toggle_all(m))
      local tail = { all.lines[#all.lines - 1], all.lines[#all.lines] }
      assert.same({ "  Comment.nvim", "  plenary.nvim" }, tail)
      assert.equals("plenary.nvim", all.items[#all.lines].name)
      assert.equals(
        2,
        render.find(all, { name = "plenary.nvim" })
          - render.find(all, { name = "Comment.nvim" })
          + 1
      )
    end)

    it("says so when nothing changed", function()
      report.plugins = {}
      local r = render.render(model.new(report))
      assert.truthy(
        table.concat(r.lines, "\n"):find("No plugin changed since the last sync", 1, true)
      )
    end)

    it("cycles the sort: breaking, name, commits, time", function()
      local m = model.new(report)
      assert.equals("breaking", m.sort)
      m = model.next_sort(m)
      assert.same(
        { "broken.nvim", "fresh.nvim", "gitsigns.nvim", "mason.nvim", "telescope.nvim" },
        plugin_names(render.render(m))
      )
      m = model.next_sort(m)
      assert.equals("commits", m.sort)
      assert.same(
        { "mason.nvim", "telescope.nvim" },
        { unpack(plugin_names(render.render(m)), 1, 2) }
      )
      m = model.next_sort(m)
      assert.equals("time", m.sort)
      assert.same(
        { "gitsigns.nvim", "telescope.nvim", "mason.nvim" },
        { unpack(plugin_names(render.render(m)), 1, 3) }
      )
      assert.equals("breaking", model.next_sort(m).sort, "wraps")
    end)

    it("finds a plugin's line again by its name after a re-sort", function()
      local m = model.new(report)
      local before = render.render(m)
      local after = render.render(model.next_sort(m))
      local a, b =
        render.find(before, { name = "mason.nvim" }), render.find(after, { name = "mason.nvim" })
      assert.is_not.equal(a, b, "the line moved")
      assert.equals("mason.nvim", after.items[b].name)
    end)
  end)

  describe("seen marks", function()
    it("count per plugin and key on name@sha, not on the SHA alone", function()
      local m = model.new(report)
      local tel = model.entry(m, "telescope.nvim")
      local mason = model.entry(m, "mason.nvim")
      assert.equals(3, model.unseen(m, tel))

      m = model.mark(m, { { name = "telescope.nvim", sha = sha("a") } })
      assert.equals(2, model.unseen(m, tel))
      m = model.mark(m, { { name = "mason.nvim", sha = sha("1") } })
      assert.equals(5, model.unseen(m, mason))
      assert.equals(2, model.unseen(m, tel))
      -- The same SHA under another plugin's name (a fork, a vendored copy) marks nothing of mason.
      m = model.mark(m, { { name = "telescope.nvim", sha = sha("d") } })
      assert.equals(5, model.unseen(m, mason), "a seen mark is name@sha, not the SHA alone")

      m = model.mark(m, model.commit_keys(m, tel))
      assert.equals(0, model.unseen(m, tel))
      local r = render.render(m)
      assert.is_nil(line_of(r, "telescope.nvim"):find("unseen", 1, true))

      m = model.mark(m, { { name = "telescope.nvim", sha = sha("b") } }, false)
      assert.equals(1, model.unseen(m, tel), "unmarked again")
    end)

    it("never changes the model it was given", function()
      local m = model.new(report)
      local m2 = model.mark(m, { { name = "telescope.nvim", sha = sha("a") } })
      assert.is_nil(m.seen[model.seen_key("telescope.nvim", sha("a"))])
      assert.is_true(m2.seen[model.seen_key("telescope.nvim", sha("a"))])
      assert.equals("overview", model.show(m2, { kind = "digest" }) and m2.view.kind)
    end)
  end)

  describe("breaking digest", function()
    it("lists breaking commits flat over all plugins, keyed by name and full SHA", function()
      local m = model.show(model.new(report), { kind = "digest" })
      local r = render.render(m)
      assert.truthy(r.lines[1]:find("breaking digest", 1, true))
      local l, i = line_of(r, "telescope.nvim", sha("a"))
      assert.truthy(l:find("telescope.nvim", 1, true), l)
      assert.truthy(l:find("aaaaaaa feat(picker)!: drop the old layout API", 1, true), l)
      assert.equals("BREAKING (1)", r.lines[i - 1])
      assert.equals(sha("a"), r.items[i].sha)
    end)

    it("says so when nothing looks breaking", function()
      report.plugins = { report.plugins[2] }
      local r = render.render(model.show(model.new(report), { kind = "digest" }))
      assert.truthy(
        table.concat(r.lines, "\n"):find("No commit of this report looks breaking", 1, true)
      )
    end)
  end)

  describe("plugin detail", function()
    it("splits BREAKING, GROUPED and OTHER", function()
      local r =
        render.render(model.show(model.new(report), { kind = "detail", name = "telescope.nvim" }))
      local text = table.concat(r.lines, "\n")
      assert.truthy(text:find("BREAKING (1)\n  • aaaaaaa [sure] feat(picker)!", 1, true), text)
      assert.truthy(text:find("OTHER (2)", 1, true), text)

      local mason =
        render.render(model.show(model.new(report), { kind = "detail", name = "mason.nvim" }))
      local mtext = table.concat(mason.lines, "\n")
      assert.truthy(mtext:find("GROUPED (5)\n  chore(registry): update ×5", 1, true), mtext)
      assert.truthy(
        mtext:find("OTHER (1)\n  • 0000000 fix: install path on Windows", 1, true),
        mtext
      )
      local _, gi = line_of(mason, "mason.nvim", sha("d"))
      assert.equals(
        "    • ddddddd chore(registry): update",
        mason.lines[gi],
        "group members are indented"
      )
    end)

    it("shows what a rollback removed, without a seen state", function()
      local r =
        render.render(model.show(model.new(report), { kind = "detail", name = "gitsigns.nvim" }))
      local l = line_of(r, "gitsigns.nvim", sha("9"))
      assert.equals("    9999999 feat: blame in the sign column", l)
      assert.truthy(table.concat(r.lines, "\n"):find("REMOVED (1)", 1, true))
    end)

    it("]] and [[ walk the plugins in the overview's order, wrapping", function()
      local m = model.show(model.new(report), { kind = "detail", name = "telescope.nvim" })
      m = model.step_plugin(m, 1)
      assert.equals("broken.nvim", m.view.name)
      m = model.step_plugin(m, -2)
      assert.equals("mason.nvim", m.view.name, "wraps backwards")
      assert.equals(
        "overview",
        model.step_plugin(model.new(report), 1).view.kind,
        "only in a detail"
      )
    end)

    it("refuses a plugin that is not in the report", function()
      local m = model.new(report)
      assert.equals(m, model.show(m, { kind = "detail", name = "nope.nvim" }))
    end)
  end)

  describe("preview", function()
    it("shows subject, author, date, SHA, the verdict, the body and the files", function()
      local m = model.new(report)
      local r = render.render_preview(m, "telescope.nvim", sha("a"), {
        { status = "M", path = "lua/telescope/pickers.lua" },
        { status = "D", path = "lua/telescope/layout.lua" },
      })
      assert.equals("feat(picker)!: drop the old layout API", r.lines[1])
      assert.truthy(r.lines[2]:find("Bea · ", 1, true), r.lines[2])
      assert.truthy(r.lines[2]:find(sha("a"), 1, true), r.lines[2])
      assert.truthy(r.lines[3]:find("! sure", 1, true), r.lines[3])
      local text = table.concat(r.lines, "\n")
      assert.truthy(
        text:find("BREAKING CHANGE: layout_strategy is gone.\nUse layout_config.", 1, true)
      )
      assert.truthy(
        text:find("Files (2)\n  M lua/telescope/pickers.lua\n  D lua/telescope/layout.lua", 1, true)
      )
      for i = 1, #r.lines do
        assert.equals(sha("a"), r.items[i].sha or sha("a"))
      end
    end)

    it("says when the files are loading or could not be read", function()
      local m = model.new(report)
      assert.truthy(
        table
          .concat(render.render_preview(m, "mason.nvim", sha("0"), "loading").lines, "\n")
          :find("Files: loading...", 1, true)
      )
      assert.truthy(
        table
          .concat(
            render.render_preview(m, "mason.nvim", sha("0"), { error = "not available locally" }).lines,
            "\n"
          )
          :find("Files: not available locally", 1, true)
      )
      assert.equals(
        "No commit under the cursor",
        render.render_preview(m, "mason.nvim", sha("a")).lines[1]
      )
    end)

    it("cleans commit text from other repositories", function()
      report.plugins[1].commits[2].subject = "fix: \27[31mred\27[0m and a\rcarriage"
      local m = model.new(report)
      local r = render.render_preview(m, "telescope.nvim", sha("b"))
      assert.is_nil(r.lines[1]:find("\27", 1, true), r.lines[1])
      assert.is_nil(r.lines[1]:find("\r", 1, true), r.lines[1])
      local d = render.render(model.show(m, { kind = "detail", name = "telescope.nvim" }))
      assert.is_nil(table.concat(d.lines, "\n"):find("\27", 1, true))
    end)
  end)
end)
