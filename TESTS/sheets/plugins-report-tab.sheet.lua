-- Live check: the report tab of `:Git plugins` (section 4 of the gitsuite live-check file,
-- task gitsuite.nvim/plugins-report-ui-live-check, which went into gitsuite.nvim/live-test-checklist).
-- Automated: four local clones (no network) with hand-written reflogs of one update run -- a
-- breaking update, a plain one, a fresh install, an unchanged plugin -- scanned by the real
-- `:Git plugins report`; then the keys: <CR> detail, j through the commits, <BS>, D digest, ]b, m,
-- o on a plugin and on a commit (the system's opener is stubbed and records the URL), ? (nothing
-- cut), O (the menu), a colorscheme change (the groups still have a colour), q and `:Git plugins`
-- again. A snapshot per state. The colours themselves, real blobless lazy clones and the real
-- browser stay with a person.
return {
  id = "gitsuite.plugins-report-tab",
  title = "gitsuite.nvim: report tab of :Git plugins (keys, layout, colours)",
  task = "gitsuite.nvim/live-test-checklist",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 }, { rows = 40, cols = 160 } },
  steps = {
    {
      lua = [[vim.opt.shortmess:append("I"); vim.o.ruler = false; vim.o.showcmd = false
      vim.o.tabline = " tab %{tabpagenr()} of %{tabpagenr('$')}"]],
      note = "no intro, no ruler; a tabline of its own (the default shortens the gitsuite:// name per platform)",
    },
    {
      lua = [=[_G.opened = {}
      package.loaded["lib.nvim.cross.open_default"] = function(url)
        _G.opened[#_G.opened + 1] = url
        return true
      end
      local root = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(root, "p")
      _G.sheet_root = root
      local ZERO = ("0"):rep(40)
      local TU = 1790000000 -- the update run (13:33 UTC)
      local T0 = TU - 30 * 86400 -- the clones were made
      local function git(dir, args, stdin)
        local argv = { "git", "-c", "user.name=sheet", "-c", "user.email=sheet@example.invalid",
          "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false", "-C", dir }
        vim.list_extend(argv, args)
        local res = vim.system(argv, { text = true, stdin = stdin }):wait()
        assert(res.code == 0, "git " .. table.concat(args, " ") .. ": " .. (res.stderr or ""))
        return res
      end
      local function write(path, text)
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        local f = assert(io.open(path, "wb"))
        f:write(text)
        f:close()
      end
      local function data(s) return ("data %d\n%s\n"):format(#s, s) end
      -- commits: { message, { [path] = content }, time }; returns the hashes
      local function clone(name, commits, reflog)
        local dir = root .. "/" .. name
        vim.fn.mkdir(dir, "p")
        git(dir, { "init", "-q", "-b", "main" })
        local parts = {}
        for i, c in ipairs(commits) do
          local who = ("Ada <ada@example.invalid> %d +0000"):format(c[3])
          parts[#parts + 1] = ("commit refs/heads/main\nmark :%d\nauthor %s\ncommitter %s\n"):format(i, who, who)
            .. data(c[1]) .. (i > 1 and ("from :%d\n"):format(i - 1) or "")
          local paths = vim.tbl_keys(c[2])
          table.sort(paths)
          for _, p in ipairs(paths) do
            parts[#parts + 1] = ("M 100644 inline %s\n"):format(p) .. data(c[2][p])
          end
          parts[#parts + 1] = "\n"
        end
        local marks = vim.fn.tempname()
        git(dir, { "fast-import", "--quiet", "--export-marks=" .. marks }, table.concat(parts))
        local s = {}
        for line in io.lines(marks) do
          local n, sha = line:match("^:(%d+) (%x+)$")
          if n then s[tonumber(n)] = sha end
        end
        vim.fn.delete(marks)
        write(dir .. "/.git/HEAD", s[#commits] .. "\n")
        local lines = {}
        for _, r in ipairs(reflog(s)) do
          lines[#lines + 1] = ("%s %s T <t@example.invalid> %d +0000\t%s"):format(r[1] or ZERO, r[2], r[3], r[4])
        end
        write(dir .. "/.git/logs/HEAD", table.concat(lines, "\n") .. "\n")
        local cfg = assert(io.open(dir .. "/.git/config", "ab"))
        cfg:write(('[remote "origin"]\n\turl = https://github.com/example/%s\n'):format(name))
        cfg:close()
        return s
      end
      local base = T0 - 86400
      clone("telescope.nvim", {
        { "feat: pickers", { ["lua/telescope/init.lua"] = "return {}\n", ["README.md"] = "# telescope\n" }, base },
        { "fix: sorter", { ["lua/telescope/sorters.lua"] = "return 1\n" }, base + 60 },
        { "feat(picker)!: drop the old layout API\n\nBREAKING CHANGE: layout_strategy is gone.\nUse layout_config instead.\n",
          { ["lua/telescope/layout.lua"] = "return { config = {} }\n" }, TU - 7200 },
        { "fix: keep the cursor in the prompt", { ["lua/telescope/prompt.lua"] = "return 2\n" }, TU - 5400 },
        { "docs: layout_config in the readme", { ["README.md"] = "# telescope\n\nlayout_config\n" }, TU - 3600 },
      }, function(s)
        return {
          { nil, s[1], T0, "clone: from https://github.com/example/telescope.nvim" },
          { s[1], s[2], T0 + 5, "checkout: moving from main to " .. s[2] },
          { s[2], s[5], TU, "checkout: moving from " .. s[2] .. " to " .. s[5] },
        }
      end)
      clone("mason.nvim", {
        { "feat: registry", { ["lua/mason/init.lua"] = "return {}\n" }, base },
        { "chore(registry): update", { ["registry.json"] = "{\"v\":1}\n" }, TU - 7000 },
        { "chore(registry): update", { ["registry.json"] = "{\"v\":2}\n" }, TU - 6000 },
        { "fix: install path on Windows", { ["lua/mason/path.lua"] = "return '\\\\'\n" }, TU - 5000 },
      }, function(s)
        return {
          { nil, s[1], T0, "clone: from https://github.com/example/mason.nvim" },
          { s[1], s[4], TU + 10, "checkout: moving from " .. s[1] .. " to " .. s[4] },
        }
      end)
      clone("fresh.nvim", {
        { "feat: first", { ["lua/fresh.lua"] = "return 1\n" }, TU - 86400 },
        { "feat: second", { ["lua/fresh.lua"] = "return 2\n" }, TU - 80000 },
      }, function(s)
        return {
          { nil, s[1], TU + 20, "clone: from https://github.com/example/fresh.nvim" },
          { s[1], s[2], TU + 25, "checkout: moving from main to " .. s[2] },
        }
      end)
      clone("plenary.nvim", {
        { "feat: async", { ["lua/plenary/async.lua"] = "return {}\n" }, base },
      }, function(s)
        return { { nil, s[1], T0, "clone: from https://github.com/example/plenary.nvim" } }
      end)
      require("gitsuite").setup({ plugins = { sources = { "clones" }, roots = { root } } })
      require("gitsuite.features.plugins.report_ui.window").set_seen_path(root .. "/plugins_seen.json")
      _G.rs = function() return require("gitsuite.features.plugins.report_ui.window").state() end
      _G.item = function()
        local s = _G.rs()
        return s.rendered.items[vim.api.nvim_win_get_cursor(s.list_win)[1]] or {}
      end
      _G.list = function() return vim.api.nvim_buf_get_lines(_G.rs().list_buf, 0, -1, false) end
      _G.preview = function()
        return table.concat(vim.api.nvim_buf_get_lines(_G.rs().preview_buf, 0, -1, false), "\n")
      end
      _G.float = function()
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.api.nvim_win_get_config(w).relative ~= "" then return w end
        end
      end
      -- every report group still links where it should and ends in something visible: a
      -- foreground colour, or bold (habamax's Title is bold without a colour of its own)
      _G.coloured = function()
        local missing = {}
        for group, target in pairs(require("gitsuite.features.plugins.report_ui.highlights").LINKS) do
          local resolved = vim.api.nvim_get_hl(0, { name = group, link = false })
          if vim.api.nvim_get_hl(0, { name = group }).link ~= target or not (resolved.fg or resolved.bold) then
            missing[#missing + 1] = group
          end
        end
        table.sort(missing)
        return #missing == 0 or table.concat(missing, ", ")
      end]=],
      note = "four local clones with the reflog of one update run; gitsuite reads only them; the opener stubbed",
    },
    { keys = ":Git plugins report<CR>", note = "build the report and open its tab" },
    {
      wait = [[(function()
        local s = require("gitsuite.features.plugins.report_ui.window").state()
        return s.model ~= nil and s.tab == vim.api.nvim_get_current_tabpage()
      end)()]],
      timeout = 30000,
      note = "the report tab is up",
    },
    { settle = 500 },
    { lua = 'vim.cmd("echo")', note = "clear the progress message of the scan" },
    {
      expect = [[_G.list()[1]:find("3 changed, 6 commits, 1 breaking, 6 unseen", 1, true) ~= nil]],
      note = "the first line sums up: 3 plugins changed, 6 commits, 1 breaking, all unseen",
    },
    {
      expect = [[_G.list()[3]:find("^! breaking  telescope%.nvim") and _G.list()[4]:find("^%+ new +fresh%.nvim")
        and _G.list()[5]:find("^↑ updated +mason%.nvim") and _G.list()[7]:find("1 unchanged", 1, true)]],
      note = "breaking first; every state with a glyph AND a word; the unchanged plugin only counted",
    },
    {
      expect = [[vim.api.nvim_get_current_win() == _G.rs().list_win and _G.item().name == "telescope.nvim"]],
      note = "the cursor is in the list, on the breaking plugin",
    },
    {
      expect = [[_G.coloured() == true]],
      note = "every report group has a colour in the default colorscheme",
    },
    { screen = "overview", masks = { "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d" } },

    { keys = "<CR>", note = "<CR> on telescope.nvim: its detail" },
    {
      expect = [[_G.rs().model.view.kind == "detail" and _G.rs().model.view.name == "telescope.nvim"]],
      note = "the detail of telescope.nvim",
    },
    {
      expect = [[(function()
        local l = table.concat(_G.list(), "\n")
        local b, g, o = l:find("BREAKING", 1, true), l:find("GROUPED", 1, true), l:find("OTHER", 1, true)
        return b ~= nil and (g == nil or g > b) and (o == nil or o > b)
      end)()]],
      note = "the BREAKING section first",
    },
    { screen = "detail", masks = { "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d" } },
    { keys = "3j", note = "down to the first commit (under BREAKING)" },
    {
      wait = [[_G.item().kind == "commit" and _G.preview():find("BREAKING CHANGE: layout_strategy is gone", 1, true) ~= nil]],
      note = "the preview follows: the message of the breaking commit",
    },
    {
      wait = [[_G.preview():find("lua/telescope/layout.lua", 1, true) ~= nil]],
      note = "and the files it changed",
    },
    { screen = "detail-commit", masks = { "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d" } },
    { keys = "3j", note = "down to the first commit under OTHER" },
    {
      wait = [[_G.preview():find("layout_config in the readme", 1, true) ~= nil]],
      note = "the preview shows the next commit",
    },
    { keys = "<BS>", note = "back to the overview" },
    {
      expect = [[_G.rs().model.view.kind == "overview" and _G.item().name == "telescope.nvim"]],
      note = "the overview, the cursor back on telescope.nvim",
    },

    { keys = "D", note = "the breaking digest" },
    {
      expect = [[_G.list()[1]:find("breaking digest", 1, true) ~= nil]],
      note = "the digest over every plugin",
    },
    { keys = "gg]b", note = "]b: the next breaking commit not seen yet" },
    {
      expect = [[_G.item().kind == "commit" and _G.item().name == "telescope.nvim"
        and _G.preview():find("drop the old layout API", 1, true) ~= nil]],
      note = "the cursor on the breaking commit of telescope.nvim",
    },
    { screen = "digest", masks = { "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d" } },
    { keys = "<CR>", note = "<CR> on a commit of the digest" },
    {
      expect = [[_G.rs().model.view.kind == "detail" and _G.item().kind == "commit"
        and _G.preview():find("drop the old layout API", 1, true) ~= nil]],
      note = "its plugin's detail, the cursor on that commit",
    },
    { keys = "m", note = "m: mark the commit as seen" },
    {
      expect = [[_G.list()[1]:find("5 unseen", 1, true) ~= nil]],
      note = "the unseen counter drops from 6 to 5",
    },
    { keys = "o", note = "o on the commit" },
    {
      expect = [[#_G.opened == 1 and _G.opened[1]:find("^https://github%.com/example/telescope%.nvim/commit/%x+$") ~= nil]],
      note = "the commit page of telescope.nvim is handed to the system's opener",
    },
    { keys = "<BS>", note = "back to the overview" },
    { keys = "o", note = "o on the plugin telescope.nvim" },
    {
      expect = [[#_G.opened == 2 and _G.opened[2]:find("^https://github%.com/example/telescope%.nvim/compare/%x+%.%.%.%x+$") ~= nil]],
      note = "the compare page of the update",
    },
    {
      expect = [[_G.list()[1]:find("3 unseen", 1, true) ~= nil]],
      note = "what was opened counts as seen: telescope.nvim's commits are no longer unseen",
    },

    { keys = "?", note = "?: every key" },
    { wait = [[_G.float() ~= nil]], note = "the key list is up" },
    {
      expect = [[(function()
        local w = _G.float()
        local width = vim.api.nvim_win_get_width(w)
        for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
          if vim.fn.strdisplaywidth(l) > width then return false end
        end
        return #require("gitsuite.features.plugins.report_ui.keys").KEYS + 5
          == vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(w))
      end)()]],
      note = "every key is listed and no line is wider than the window (nothing cut)",
    },
    { screen = "help", masks = { "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d" } },
    { keys = "q", note = "close the key list" },
    {
      wait = [[_G.float() == nil and vim.api.nvim_get_current_win() == _G.rs().list_win]],
      note = "back in the list",
    },

    { keys = "O", note = "O: the menu of the actions" },
    { wait = [[_G.float() ~= nil]], note = "the menu is up" },
    { settle = 300 },
    { screen = "menu", masks = { "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d" } },
    { keys = "<Esc>", note = "close the menu" },
    { wait = [[_G.float() == nil]], note = "the menu is gone" },

    { lua = 'vim.cmd.colorscheme("habamax")', note = "another colorscheme" },
    { expect = [[_G.coloured() == true]], note = "every report group still has a colour" },
    { lua = 'vim.cmd("echo")' },
    { screen = "habamax", masks = { "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d" } },

    { keys = "j", note = "the cursor on fresh.nvim" },
    { keys = "q", note = "q closes the report tab" },
    {
      expect = [[vim.t.gitsuite_plugins_report == nil and #vim.api.nvim_list_tabpages() == 1]],
      note = "the tab is gone",
    },
    { keys = ":Git plugins<CR>", note = ":Git plugins opens it again" },
    {
      wait = [[vim.t.gitsuite_plugins_report == true and _G.rs().model ~= nil]],
      note = "the report tab is back",
    },
    {
      expect = [[_G.rs().model.view.kind == "overview" and _G.item().name == "fresh.nvim"
        and _G.list()[1]:find("3 unseen", 1, true) ~= nil]],
      note = "same view, the cursor on the same line, the marks kept",
    },
  },
  judge = {
    "Colours in the snapshots: breaking red, updated green, hashes as numbers, dimmed text grey, and still coloured after the colorscheme change",
    "The layout reads well: list and preview side by side at 160 columns, one above the other at 120; the legend fits (at 160 the summary line of the list is cut after '1 breaking' -- acceptable?)",
    "The ? list at 120x30 is taller than the screen: its last rows (?, q / <Esc>) are reached by scrolling -- acceptable, or should it fit?",
    "The O menu names each action with its first key only (o, not o / K) -- reads well?",
  },
  manual = {
    "In your own config with real lazy clones: :Git plugins report, the colours fit your colorscheme; :colorscheme <another> keeps them coloured",
    "On a real blobless lazy clone: the preview of a commit lists the changed files without +/- counts and says 'blobless'",
    "o on a commit opens the commit page in the real browser; o on a plugin its compare page",
    "The feel of the keys: nothing lags, the cursor lands where you expect",
    "Enter findings under 'Befunde' in docs/ROADMAP/Final_Checks/gitsuite-live-checks-2026-10-22.md (nvim config), each as a kind: bug task",
  },
}
