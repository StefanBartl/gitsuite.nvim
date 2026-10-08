-- TESTS/gitsuite/plugins_log_spec.lua -- `:Git plugins log`: text sanitising,
-- the commit view (rows, preview, picker), links, the feature entry point and
-- the registered route with its argument type.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("gitsuite :Git plugins log", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local text, view, plugins

  ---A history with a tag, a hostile subject and a multi-line body.
  local function repo_with_history()
    local repo = F.init("-plugins-log")
    F.write(repo .. "/a.txt", "1\n")
    F.commit(repo, "first", 1700000100)
    F.write(repo .. "/a.txt", "2\n")
    F.write(repo .. "/dir/b c.txt", "x\n")
    F.commit(repo, "second\n\nline one\nline two\n", 1700000200)
    F.git(repo, { "tag", "v1.0" })
    F.write(repo .. "/a.txt", "3\n")
    F.commit(repo, "\27[31mred\27[0m subject\r", 1700000300)
    return repo
  end

  local original_notify_error, notices

  before_each(function()
    for _, name in ipairs({
      "gitsuite.features.plugins",
      "gitsuite.features.plugins.view",
      "gitsuite.features.plugins.text",
      "gitsuite.features.plugins.sources",
      "gitsuite.features.plugins.gitlog",
      "gitsuite.features.plugins.links",
    }) do
      package.loaded[name] = nil
    end
    require("gitsuite.config").setup({})
    text = require("gitsuite.features.plugins.text")
    view = require("gitsuite.features.plugins.view")
    plugins = require("gitsuite.features.plugins")

    -- Collect what the feature tells the user instead of printing it.
    local notify = require("gitsuite.util.notify")
    notices = {}
    original_notify_error = notify.error
    notify.error = function(msg)
      notices[#notices + 1] = msg
    end
  end)

  after_each(function()
    require("gitsuite.util.notify").error = original_notify_error
    F.cleanup()
  end)

  describe("text.lines", function()
    it("returns every line, with the count", function()
      local lines, total, exact = text.lines("a\nb\nc")
      assert.same({ "a", "b", "c" }, lines)
      assert.equals(3, total)
      assert.is_true(exact)
    end)

    it("cleans and returns only the first `max` lines but still counts the rest", function()
      local lines, total, exact = text.lines(("line\27\n"):rep(50), 5)
      assert.equals(5, #lines)
      assert.equals("line?", lines[1])
      assert.equals(51, total) -- the text ends with a newline: a last, empty line
      assert.is_true(exact)
    end)

    it("does not copy more of a huge line than it shows", function()
      local lines = text.lines(("x"):rep(3000000) .. "\nnext", 10)
      assert.equals(2, #lines)
      assert.is_true(vim.fn.strchars(lines[1]) <= text.MAX_LINE + 1)
      assert.equals("next", lines[2])
    end)
  end)

  describe("text.clean", function()
    it("turns terminal escapes, CR and NUL into ?", function()
      assert.equals("?[31mred?[0m", text.clean("\27[31mred\27[0m"))
      assert.equals("a?b", text.clean("a\rb"))
      assert.equals("a?b", text.clean("a\0b"))
      assert.equals("a?b", text.clean("a\127b"))
    end)

    it("turns a tab into a space and also removes the C1 controls", function()
      assert.equals("a b", text.clean("a\tb"))
      assert.equals("a?b", text.clean("a\194\155b")) -- U+009B, a CSI in a UTF-8 terminal
      assert.equals("café ü", text.clean("café ü"))
      -- multi-byte characters whose bytes lie in 0x80..0x9F survive intact
      assert.equals("a…b€c€", text.clean("a…b€c€"))
      assert.equals("日本語", text.clean("日本語"))
    end)

    it("removes characters that reorder or hide text", function()
      for _, bad in ipairs({
        "\226\128\174", -- U+202E right-to-left override
        "\226\129\166", -- U+2066 left-to-right isolate
        "\226\128\139", -- U+200B zero-width space
        "\226\128\168", -- U+2028 line separator
        "\239\187\191", -- U+FEFF byte-order mark
        "\226\129\160", -- U+2060 word joiner
        "\216\156", -- U+061C Arabic letter mark
        "\239\191\185", -- U+FFF9 interlinear annotation anchor
        "\243\160\128\129", -- U+E0001 language tag
      }) do
        assert.equals("a?b", text.clean("a" .. bad .. "b"))
      end
      -- neighbours in the same blocks stay
      assert.equals("a…b", text.clean("a…b")) -- U+2026
      assert.equals("a–b", text.clean("a–b")) -- U+2013
    end)

    it("takes only the first line for a message, a title or a header", function()
      assert.equals("first", text.one_line("first\nsecond"))
      assert.equals("a?b", text.one_line("a\27b\r\nrest"))
      assert.equals("", text.one_line(nil))
    end)

    it("replaces bytes that are not UTF-8 and bounds its work by the text it keeps", function()
      assert.equals("a?b", text.clean("a\255b"))
      local started = vim.uv.hrtime()
      local cut = text.clean(("\226\128\174x"):rep(2000000)) -- 8 MB of hostile characters
      assert.is_true(vim.fn.strchars(cut) <= text.MAX_LINE + 1)
      assert.is_true((vim.uv.hrtime() - started) / 1e9 < 2, "clean() did not stay bounded")
    end)

    it("cuts an endless line", function()
      local cut = text.clean(("x"):rep(10000))
      assert.is_true(vim.fn.strchars(cut) <= text.MAX_LINE + 1)
      assert.is_truthy(cut:find("…", 1, true))
    end)

    it("splits a message into clean lines", function()
      assert.same({ "a", "", "b?c" }, text.lines("a\n\nb\27c"))
    end)
  end)

  describe("view", function()
    local entry = {
      sha = ("ab12"):rep(10),
      parents = {},
      author = "Ann\27[2J",
      email = "ann@example.invalid",
      commit_time = 1700000200,
      refs = { "HEAD -> main", "tag: v1.0", "origin/main" },
      subject = "fix: \27[31mred",
      body = "para\nBREAKING CHANGE: x\27",
      files = {
        { status = "M", path = "a.txt" },
        { status = "R100", path = "new.txt", orig_path = "old.txt" },
      },
    }

    it("calls HEAD 'installed' only for a plugin, not for an arbitrary clone", function()
      assert.is_truthy(view.line(entry, "plugin"):find("<- installed (HEAD)", 1, true))
      local path_line = view.line(entry, "path")
      assert.is_truthy(path_line:find("<- HEAD", 1, true))
      assert.is_nil(path_line:find("installed", 1, true))
    end)

    it("marks the installed commit and the tags in the one-line form", function()
      local line = view.line(entry, "plugin")
      assert.is_truthy(line:find(entry.sha:sub(1, 8), 1, true))
      assert.is_truthy(line:find("<- installed (HEAD)", 1, true))
      assert.is_truthy(line:find("[v1.0]", 1, true))
      assert.is_nil(line:find("\27", 1, true))
      assert.is_true(view.is_head(entry))
      assert.is_false(view.is_head({ refs = { "tag: v1" } }))
      assert.same({ "v1.0" }, view.tags(entry))
    end)

    it("builds a preview with author, message and changed files, escapes removed", function()
      local joined = table.concat(view.preview_lines(entry), "\n")
      assert.is_truthy(joined:find(entry.sha, 1, true))
      assert.is_truthy(joined:find("BREAKING CHANGE: x?", 1, true))
      assert.is_truthy(joined:find("Files (2)", 1, true))
      assert.is_truthy(joined:find("M  a.txt", 1, true))
      assert.is_truthy(joined:find("R  old.txt -> new.txt", 1, true))
      assert.is_nil(joined:find("\27", 1, true))
    end)

    it("says so for a commit without files", function()
      local lines = view.preview_lines(vim.tbl_extend("force", entry, { files = {} }))
      assert.is_truthy(table.concat(lines, "\n"):find("no changed files", 1, true))
    end)

    it("lists the commits under a header", function()
      local rows = view.rows({ kind = "plugin", name = "p", dir = "/d/p" }, { entry, entry })
      assert.is_truthy(rows[1]:find("2 commits", 1, true))
      assert.equals(4, #rows)
      assert.equals("", rows[2])
    end)

    it("cleans the target's name and path in the header", function()
      local rows = view.rows({ kind = "path", name = "p\27[2J", dir = "/d/\27]0;x" }, { entry })
      assert.is_nil(rows[1]:find("\27", 1, true))
      assert.is_truthy(rows[1]:find("1 commit of", 1, true))
    end)

    it("caps a huge message and a huge file list in the preview", function()
      local body = {}
      for i = 1, view.MAX_BODY_LINES + 40 do
        body[i] = "line " .. i
      end
      local files = {}
      for i = 1, view.MAX_FILES + 25 do
        files[i] = { status = "A", path = "f" .. i }
      end
      local lines = view.preview_lines(
        vim.tbl_extend("force", entry, { body = table.concat(body, "\n"), files = files })
      )
      local joined = table.concat(lines, "\n")
      assert.is_truthy(joined:find("... 40 more lines", 1, true))
      assert.is_truthy(joined:find("... 25 more", 1, true))
      assert.is_nil(joined:find("line " .. (view.MAX_BODY_LINES + 1) .. "\n", 1, true))
      assert.is_true(#lines < view.MAX_BODY_LINES + view.MAX_FILES + 20)
    end)

    it("refuses an unknown output with the reason", function()
      assert.is_nil(view.show({ kind = "path", name = "p", dir = "/d" }, { entry }, "printer"))
      assert.is_truthy(notices[1]:find("unknown output 'printer'", 1, true))
    end)

    describe("the picker spec", function()
      local spec, original_kit

      before_each(function()
        original_kit = package.loaded["ui.kit"]
        package.loaded["ui.kit"] = {
          picker = function(s)
            spec = s
            return { current = function() end, close = function() end }
          end,
        }
      end)

      after_each(function()
        package.loaded["ui.kit"] = original_kit
      end)

      ---@return string
      local function plain(chunks)
        return table.concat(vim.tbl_map(function(c)
          return c[1]
        end, chunks))
      end

      it("cleans every piece of foreign text it shows and drops the lazygit key", function()
        local target = { kind = "path", name = "n\27[2J", dir = "/d", ref = nil }
        view.show(target, { entry }, "picker")
        assert.is_not_nil(spec)
        assert.is_nil(spec.title:find("\27", 1, true))
        assert.is_nil(plain(spec.format(entry)):find("\27", 1, true))
        assert.is_truthy(plain(spec.format(entry)):find("<- HEAD", 1, true))
        assert.is_nil(plain(spec.format(entry)):find("installed", 1, true))
        assert.is_nil(spec.keys["<M-g>"], "no key may hand a clone to a program that can change it")
        assert.is_function(spec.keys["<M-o>"])
        assert.is_function(spec.keys["<M-y>"])

        local set
        spec.preview(entry, {
          set_lines = function(_, lines)
            set = lines
          end,
        })
        assert.is_nil(table.concat(set, "\n"):find("\27", 1, true))
      end)

      it("<M-y> copies the hash of the entry under the cursor", function()
        view.show({ kind = "path", name = "n", dir = "/d" }, { entry }, "picker")
        vim.fn.setreg('"', "")
        spec.keys["<M-y>"]({
          current = function()
            return entry
          end,
        })
        assert.equals(entry.sha, vim.fn.getreg('"'))
      end)

      it("<CR> on a clone without a forge copies the hash instead", function()
        local repo = F.init("-picker-submit")
        local sha = F.commit(repo, "one")
        view.show({ kind = "path", name = "n", dir = repo }, { entry }, "picker")
        local notify = require("gitsuite.util.notify")
        local original = notify.warn
        notify.warn = function() end
        spec.on_submit(nil, nil, vim.tbl_extend("force", entry, { sha = sha }))
        notify.warn = original
        assert.equals(sha, vim.fn.getreg('"'))
      end)
    end)
  end)

  describe("plugins.log", function()
    ---Run the feature and wait for the commits to be read.
    local function log(target, opts)
      local box
      opts = vim.tbl_extend("force", opts or {}, {
        on_done = function(entries, err)
          box = { entries = entries, err = err }
        end,
      })
      local handle = plugins.log(target, opts)
      if handle then vim.wait(20000, function()
        return box ~= nil
      end, 10) end
      return handle, box
    end

    it("--out=buffer opens a scratch listing of the commits", function()
      local repo = repo_with_history()
      local before = #vim.api.nvim_list_wins()
      local _, box = log(repo, { out = "buffer", n = 10 })
      assert.is_nil(box.err)
      assert.equals(3, #box.entries)
      vim.wait(2000, function()
        return vim.bo.filetype == "gitsuite-plugins-log"
      end, 10)
      assert.equals("gitsuite-plugins-log", vim.bo.filetype)
      assert.equals(before + 1, #vim.api.nvim_list_wins())
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.is_truthy(joined:find("3 commits", 1, true))
      assert.is_truthy(joined:find("[v1.0]", 1, true))
      -- a path is not an installed plugin: the marker says where HEAD is, no more
      assert.is_truthy(joined:find("<- HEAD", 1, true))
      assert.is_nil(joined:find("installed", 1, true))
      assert.is_nil(joined:find("\27", 1, true), "the hostile escape never reaches the buffer")
      vim.cmd("close")
    end)

    it("--out=clipboard puts the listing into the unnamed register", function()
      local repo = repo_with_history()
      log(repo, { out = "clipboard", n = 2 })
      vim.wait(2000, function()
        return vim.fn.getreg('"'):find("2 commits", 1, true) ~= nil
      end, 10)
      assert.is_truthy(vim.fn.getreg('"'):find("2 commits", 1, true))
    end)

    it("opens a picker with the commits and a preview that follows the cursor", function()
      local repo = repo_with_history()
      local target = assert(require("gitsuite.features.plugins.sources").resolve(repo))
      local gitlog = require("gitsuite.features.plugins.gitlog")
      local entries
      gitlog.log(target.dir, 10, function(e)
        entries = e
      end)
      vim.wait(20000, function()
        return entries ~= nil
      end, 10)
      local handle = assert(view.show(target, entries, "picker"))
      vim.wait(2000, function()
        return handle.current() ~= nil
      end, 10)
      assert.equals(entries[1].sha, handle.current().sha)
      assert.is_false(handle.is_closed())
      handle.close()
      assert.is_true(handle.is_closed())
    end)

    it(
      "refuses a bad count, an unknown plugin and a missing git repository, with the reason",
      function()
        assert.is_nil(plugins.log(F.init("-x"), { n = 0 }))
        assert.is_truthy(notices[1]:find("count must be a positive integer", 1, true))

        assert.is_nil(plugins.log("someone/not-installed"))
        assert.is_truthy(notices[2]:find("not an installed plugin", 1, true))

        -- never got as far as reading, but `on_done` still hears about it
        local _, box = log(F.tmpdir("-no-repo-but-a-target"), {})
        assert.is_nil(box.entries)
        assert.is_truthy(box.err:find("not a git repository", 1, true))
        assert.is_truthy(notices[3]:find("not a git repository", 1, true))
      end
    )

    it("cuts an enormous count and refuses NaN, infinity and fractions", function()
      local gitlog = require("gitsuite.features.plugins.gitlog")
      local repo = F.init("-clamp")
      local asked
      local original_log = gitlog.log
      gitlog.log = function(_, n)
        asked = n
        return { stop = function() end }
      end
      local notify = require("gitsuite.util.notify")
      local original_warn, warned = notify.warn, nil
      notify.warn = function(msg)
        warned = msg
      end
      plugins.log(repo, { n = 10 ^ 9 })
      gitlog.log, notify.warn = original_log, original_warn
      assert.equals(plugins.MAX_COMMITS, asked)
      assert.is_truthy(warned and warned:find(tostring(plugins.MAX_COMMITS), 1, true))

      for _, bad in ipairs({ 0 / 0, math.huge, -1, 2.5, "7" }) do
        notices = {}
        local heard
        assert.is_nil(plugins.log(repo, {
          n = bad,
          on_done = function(_, err)
            heard = err
          end,
        }))
        assert.is_truthy(notices[1] and notices[1]:find("positive integer", 1, true), tostring(bad))
        assert.is_truthy(heard, tostring(bad))
      end
    end)

    it("cleans a git error before it reaches a notification", function()
      local gitlog = require("gitsuite.features.plugins.gitlog")
      local original_log = gitlog.log
      gitlog.log = function(_, _, on_done)
        vim.schedule(function()
          on_done(nil, "fatal: bad\27[31m thing\nsecond line")
        end)
        return { stop = function() end }
      end
      local _, box = log(F.init("-err"), {})
      gitlog.log = original_log
      assert.is_not_nil(box)
      assert.is_nil(notices[1]:find("\27", 1, true))
      assert.is_nil(notices[1]:find("\n", 1, true))
    end)

    it("reports a read failure and an empty repository", function()
      local empty = F.init("-empty")
      local _, box = log(empty, { out = "buffer" })
      assert.is_nil(box.entries)
      assert.is_truthy(notices[1]:find("plugins log:", 1, true))
    end)
  end)

  describe("links", function()
    it("builds a commit URL from the origin remote and falls back to copying the hash", function()
      local links = require("gitsuite.features.plugins.links")
      local repo = F.init("-links")
      local sha = F.commit(repo, "one")
      local url, err = links.commit_url(repo, sha)
      assert.is_nil(url)
      assert.is_truthy(err:find("no 'origin' remote", 1, true))

      F.git(repo, { "remote", "add", "origin", "https://github.com/someone/thing.nvim.git" })
      assert.equals(
        "https://github.com/someone/thing.nvim/commit/" .. sha,
        (links.commit_url(repo, sha))
      )

      F.git(repo, { "remote", "set-url", "origin", "https://git.example.org/o/r.git" })
      local _, host_err = links.commit_url(repo, sha)
      assert.is_truthy(host_err:find("unrecognized host", 1, true))
      require("gitsuite.config").setup({ browse = { hosts = { ["git.example.org"] = "gitlab" } } })
      assert.equals("https://git.example.org/o/r/-/commit/" .. sha, (links.commit_url(repo, sha)))
    end)

    it("refuses an owner or repository name that is not a plain name", function()
      local links = require("gitsuite.features.plugins.links")
      local repo = F.init("-links-hostile")
      local sha = F.commit(repo, "one")
      for _, url in ipairs({
        "https://github.com/%24HOME/thing.git",
        "https://github.com/a%3Bb/thing.git",
        "https://github.com/owner/%60id%60.git",
      }) do
        F.git(repo, { "config", "remote.origin.url", url })
        local got, err = links.commit_url(repo, sha)
        assert.is_nil(got, url)
        assert.is_truthy(err, url)
      end
    end)

    it("never lets an escape sequence in the remote reach a message", function()
      local links = require("gitsuite.features.plugins.links")
      local repo = F.init("-links-esc")
      local sha = F.commit(repo, "one")
      local config = repo .. "/.git/config"
      local f = assert(io.open(config, "ab"))
      f:write('[remote "origin"]\n\turl = https://github.com/own\27[31mer/th\27ing.git\n')
      f:close()
      local got, err = links.commit_url(repo, sha)
      assert.is_nil(got)
      assert.is_nil(err:find("\27", 1, true))
    end)

    it("takes only a hex string as a commit hash", function()
      local links = require("gitsuite.features.plugins.links")
      local repo = F.init("-links-sha")
      F.git(repo, { "remote", "add", "origin", "https://github.com/a/b.git" })
      assert.is_nil((links.commit_url(repo, "abc/../../x")))
      assert.is_nil((links.commit_url(repo, "")))
      assert.is_nil((links.commit_url(repo, nil)))
    end)

    it("copies the hash when there is no usable forge", function()
      local repo = F.init("-links-copy")
      local sha = F.commit(repo, "one")
      local warned
      local notify = require("gitsuite.util.notify")
      local original = notify.warn
      notify.warn = function(msg)
        warned = msg
      end
      view.open_commit({ name = "x", dir = repo, kind = "path" }, { sha = sha })
      notify.warn = original
      assert.equals(sha, vim.fn.getreg('"'))
      assert.is_truthy(warned and warned:find("copied", 1, true))
    end)
  end)

  describe("the :Git plugins log route", function()
    local function register()
      -- a fresh command registry for this file's own cfg
      require("gitsuite.bindings.usrcmds").register(require("gitsuite.config").get())
    end

    it("is registered with a plugin-or-path argument type that resolves and completes", function()
      register()
      local repo = repo_with_history()
      require("gitsuite.config").setup({ plugins = { roots = { vim.fs.dirname(repo) } } })
      local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
      local type_def = argtypes.get and argtypes.get("GITSUITE_PLUGIN_OR_REPO")
      if type_def == nil then
        -- registry accessor differs between lib versions: exercise the route instead
        vim.cmd(("Git plugins log %s 2 --out=clipboard"):format(vim.fn.fnameescape(repo)))
        vim.wait(20000, function()
          return vim.fn.getreg('"'):find("2 commits", 1, true) ~= nil
        end, 10)
        assert.is_truthy(vim.fn.getreg('"'):find("2 commits", 1, true))
        return
      end
      local ok, target = type_def.validate(repo)
      assert.is_true(ok)
      assert.equals(vim.fs.basename(repo), target.name)
      local bad_ok, _, bad_err = type_def.validate("someone/not-installed")
      assert.is_false(bad_ok)
      assert.is_truthy(bad_err:find("not an installed plugin", 1, true))
    end)

    it("runs end to end: target, count and --out", function()
      register()
      local repo = repo_with_history()
      vim.fn.setreg('"', "")
      vim.cmd(("Git plugins log %s 2 --out=clipboard"):format(vim.fn.fnameescape(repo)))
      vim.wait(20000, function()
        return vim.fn.getreg('"'):find("2 commits", 1, true) ~= nil
      end, 10)
      assert.is_truthy(vim.fn.getreg('"'):find("2 commits", 1, true))
    end)

    it("takes the count from --count as well, and shows it with the right plural", function()
      register()
      local repo = repo_with_history()
      vim.fn.setreg('"', "")
      vim.cmd(("Git plugins log %s --count=1 --out=clipboard"):format(vim.fn.fnameescape(repo)))
      vim.wait(20000, function()
        return vim.fn.getreg('"'):find("1 commit of", 1, true) ~= nil
      end, 10)
      assert.is_truthy(vim.fn.getreg('"'):find("1 commit of", 1, true))
      assert.is_nil(vim.fn.getreg('"'):find("1 commits", 1, true))
    end)

    it("reaches the user with a clear message for an unknown target", function()
      register()
      -- The composer rejects an invalid argument value itself, naming the
      -- argument and the reason (it reports through a scheduled notification).
      local messages = {}
      local original = vim.notify
      vim.notify = function(msg)
        messages[#messages + 1] = tostring(msg)
      end
      vim.cmd("Git plugins log someone/not-installed")
      vim.wait(2000, function()
        return #messages > 0
      end, 10)
      vim.notify = original
      local joined = table.concat(messages, " | ")
      assert.is_truthy(joined:find("not an installed plugin", 1, true))
      assert.is_truthy(joined:find("GITSUITE_PLUGIN_OR_REPO", 1, true))
    end)
  end)
end)
