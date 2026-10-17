-- TESTS/gitsuite/ui_spec.lua -- gitsuite.features.ui. Deliberately does NOT
-- spawn a real lazygit/neogit/diffview process even where the binary/plugin
-- happens to be installed on the machine running this suite: an
-- interactive TUI process left running (or a flaky kill) would make this
-- suite non-deterministic across dev machines and CI. Every case here
-- forces the "not available" path instead, which is also exactly what CI
-- sees for real (none of the three are sibling checkouts/PATH entries
-- there) -- see hunk_spec.lua/browse_spec.lua for the same approach with
-- gitsigns/open.nvim.
-- The one exception is the lazygit(repo_dir) block, which pretends lazygit
-- is present but stubs `jobstart`, so it still never starts a process.
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
describe("gitsuite.features.ui", function()
  local G = dofile(dir_of_spec .. "spec_guard.lua")()
  G.install({
    { vim.fn, "executable", "jobstart" },
    { vim, "notify" },
  })

  local ui

  before_each(function()
    package.loaded["gitsuite.features.ui"] = nil
    package.loaded["gitsuite.adapter"] = nil
    ui = require("gitsuite.features.ui")
  end)

  it("lazygit() reports a clean error, does not crash, when lazygit is not on $PATH", function()
    local original_executable = vim.fn.executable
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      if name == "lazygit" then return 0 end
      return original_executable(name)
    end

    local ok = pcall(ui.lazygit)

    vim.fn.executable = original_executable
    assert.is_true(ok)
  end)

  it("neogit() reports 'not installed', does not crash, without neogit", function()
    local ok = pcall(ui.neogit)
    assert.is_true(ok)
  end)

  it(
    "diffview_open() falls back to diff.nvim's split() (:Diff, no args) without diffview.nvim",
    function()
      local calls = {}
      local real_diff = package.loaded["diff"]
      package.loaded["diff"] = {
        run = function(raw_args)
          calls[#calls + 1] = { "run", raw_args }
        end,
      }

      local ok = pcall(ui.diffview_open)

      package.loaded["diff"] = real_diff
      assert.is_true(ok)
      assert.same({ { "run", "" } }, calls)
    end
  )

  it(
    "diffview_close() falls back to diff.nvim's clear() (:DiffClear) without diffview.nvim",
    function()
      local calls = {}
      local real_diff = package.loaded["diff"]
      package.loaded["diff"] = {
        clear = function()
          calls[#calls + 1] = { "clear" }
        end,
      }

      local ok = pcall(ui.diffview_close)

      package.loaded["diff"] = real_diff
      assert.is_true(ok)
      assert.same({ { "clear" } }, calls)
    end
  )

  describe("diffview_open()/diffview_close(), with a faked diffview.nvim", function()
    local real_diffview

    before_each(function()
      real_diffview = package.loaded["diffview"]
    end)

    after_each(function()
      package.loaded["diffview"] = real_diffview
    end)

    it("diffview_open() opens with no extra args", function()
      local calls = {}
      package.loaded["diffview"] = {
        open = function(args)
          calls[#calls + 1] = { "open", args }
        end,
        close = function()
          calls[#calls + 1] = { "close" }
        end,
      }

      ui.diffview_open()

      assert.same({ { "open", {} } }, calls)
    end)

    it("diffview_close() closes the current view", function()
      local calls = {}
      package.loaded["diffview"] = {
        open = function(args)
          calls[#calls + 1] = { "open", args }
        end,
        close = function()
          calls[#calls + 1] = { "close" }
        end,
      }

      ui.diffview_close()

      assert.same({ { "close" } }, calls)
    end)

    it(":Git ui diffview open|close route to diffview_open()/diffview_close()", function()
      require("gitsuite.bindings.usrcmds").register({ commands = { git = "Git" } })
      local calls = {}
      package.loaded["diffview"] = {
        open = function(args)
          calls[#calls + 1] = { "open", args }
        end,
        close = function()
          calls[#calls + 1] = { "close" }
        end,
      }

      vim.cmd("Git ui diffview open")
      vim.cmd("Git ui diffview close")

      assert.same({ { "open", {} }, { "close" } }, calls)
    end)
  end)

  -- lazygit(repo_dir): still no real process. `lazygit` is pretended present
  -- and `jobstart` records what it would have been asked to run, so the
  -- cases below can assert on the argv and cwd the float would spawn with.
  describe("lazygit(repo_dir)", function()
    local original_executable = vim.fn.executable
    local original_jobstart = vim.fn.jobstart
    local original_notify = vim.notify
    local original_cwd
    local spawned
    local errors
    local wins_before
    local scratch

    ---@param dir string
    local function git_init(dir)
      vim.fn.mkdir(dir, "p")
      local res = vim.system({ "git", "init", "-q", dir }):wait()
      assert.equals(0, res.code, "git init: " .. tostring(res.stderr))
    end

    ---@param path string
    ---@return string
    local function real(path)
      return vim.uv.fs_realpath(path) or path
    end

    before_each(function()
      original_cwd = vim.fn.getcwd()
      spawned, errors = {}, {}
      wins_before = vim.api.nvim_list_wins()
      scratch = vim.fn.tempname()
      vim.fn.mkdir(scratch, "p")

      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.executable = function(name)
        if name == "lazygit" then return 1 end
        return original_executable(name)
      end
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.jobstart = function(argv, opts)
        spawned[#spawned + 1] = { argv = argv, opts = opts }
        return 7
      end
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then errors[#errors + 1] = msg end
      end
      -- terminal.nvim is absent unless a case installs a fake: a real one
      -- found on the runtimepath must never change which route is tested.
      package.loaded["terminal"] = nil
      package.preload["terminal"] = function()
        error("terminal.nvim is not installed in this spec")
      end
    end)

    after_each(function()
      package.loaded["terminal"] = nil
      package.preload["terminal"] = nil
      vim.fn.executable = original_executable
      vim.fn.jobstart = original_jobstart
      vim.notify = original_notify
      vim.cmd("stopinsert")
      vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if not vim.tbl_contains(wins_before, win) then pcall(vim.api.nvim_win_close, win, true) end
      end
      vim.fn.delete(scratch, "rf")
    end)

    ---@param pattern string
    local function assert_error_and_no_float(pattern)
      assert.equals(1, #errors, "exactly one error is reported")
      assert.is_truthy(errors[1]:find(pattern, 1, true), errors[1])
      assert.equals(0, #spawned, "no process is started")
      assert.equals(#wins_before, #vim.api.nvim_list_wins(), "no float is left open")
    end

    it("a directory outside any repository -> error, no float", function()
      ui.lazygit(scratch)
      assert_error_and_no_float("not inside a git repository")
    end)

    it("a path that does not exist -> error, no float", function()
      ui.lazygit(scratch .. "/nope")
      assert_error_and_no_float("not a directory")
    end)

    it("a file instead of a directory -> error, no float", function()
      local file = scratch .. "/file.txt"
      vim.fn.writefile({ "x" }, file)
      ui.lazygit(file)
      assert_error_and_no_float("not a directory")
    end)

    it("another repo (given by a subdirectory) -> argv and cwd point at its root", function()
      local repo = scratch .. "/repo"
      git_init(repo)
      vim.fn.mkdir(repo .. "/sub/deep", "p")

      ui.lazygit(repo .. "/sub/deep")

      assert.equals(0, #errors, table.concat(errors, "\n"))
      assert.equals(1, #spawned)
      local argv = spawned[1].argv
      assert.same({ "lazygit", "-p" }, { argv[1], argv[2] })
      assert.equals(real(repo), real(argv[3]), "-p is the repo root, not the subdirectory")
      assert.equals(real(repo), real(spawned[1].opts.cwd), "the process cwd is the repo root")
      assert.is_true(real(repo) ~= real(original_cwd), "not the repo Neovim happens to be in")
    end)

    it("without an argument, still uses the repo of the cwd", function()
      local repo = scratch .. "/repo"
      git_init(repo)
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      ui.lazygit()

      assert.equals(0, #errors, table.concat(errors, "\n"))
      assert.equals(1, #spawned)
      assert.equals(real(repo), real(spawned[1].argv[3]))
    end)

    it("without an argument outside any repository -> error, no float", function()
      vim.cmd("cd " .. vim.fn.fnameescape(scratch))
      ui.lazygit()
      assert_error_and_no_float("not inside a git repository")
    end)

    it(":Git ui lazygit <dir> and :Git ui lazygit go through the same route", function()
      require("gitsuite.bindings.usrcmds").register({ commands = { git = "Git" } })
      local repo = scratch .. "/repo"
      git_init(repo)

      vim.cmd("Git ui lazygit " .. vim.fn.fnameescape(vim.fs.normalize(repo)))
      assert.equals(0, #errors, table.concat(errors, "\n"))
      assert.equals(1, #spawned)
      assert.equals(real(repo), real(spawned[1].argv[3]), "the <dir> argument reaches lazygit")

      -- No argument: the cwd's repo (this suite runs inside the gitsuite checkout).
      spawned = {}
      vim.cmd("stopinsert")
      vim.cmd("Git ui lazygit")
      assert.equals(1, #spawned)
      assert.equals(real(original_cwd), real(spawned[1].argv[3]))
    end)

    -- With terminal.nvim installed, the float, job and exit handling are
    -- terminal.nvim's (`run(argv, { direct = true })`); the own float and
    -- `jobstart` are only the fallback.
    describe("with terminal.nvim", function()
      local runs

      before_each(function()
        runs = {}
        package.loaded["terminal"] = {
          run = function(cmd, opts)
            runs[#runs + 1] = { cmd = cmd, opts = opts }
            return true, nil, { name = "lazygit" }
          end,
        }
      end)

      it("hands the argv to terminal.run as a direct float job, no own float", function()
        local repo = scratch .. "/repo"
        git_init(repo)
        vim.fn.mkdir(repo .. "/sub", "p")

        ui.lazygit(repo .. "/sub")

        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals(0, #spawned, "the own jobstart route is not used")
        assert.equals(#wins_before, #vim.api.nvim_list_wins(), "no own float is opened")
        assert.equals(1, #runs)
        local cmd, opts = runs[1].cmd, runs[1].opts
        assert.same({ "lazygit", "-p" }, { cmd[1], cmd[2] })
        assert.equals(real(repo), real(cmd[3]), "-p is the repo root")
        assert.equals(real(repo), real(opts.cwd), "the job cwd is the repo root")
        assert.is_true(opts.direct)
        assert.equals("lazygit", opts.name)
        assert.equals("float", opts.layout)
        assert.equals("always", opts.close)
        assert.equals("function", type(opts.on_open))
        -- A native terminal gets $NVIM from Neovim; tmux/WezTerm refuse `env`.
        assert.is_nil(opts.env, "no env is passed")
      end)

      -- terminal.nvim's tmux/WezTerm backends refuse any `env` (preflight):
      -- this fake answers like them, so passing $NVIM keeps lazygit from
      -- starting in a pane.
      it("starts under a multiplexer backend (which refuses env)", function()
        package.loaded["terminal"] = {
          run = function(cmd, opts)
            runs[#runs + 1] = { cmd = cmd, opts = opts }
            if opts.env ~= nil and next(opts.env) ~= nil then
              return false, "the tmux backend cannot set environment variables for a pane"
            end
            return true, nil, { name = "lazygit", pane = "%1" }
          end,
        }
        local repo = scratch .. "/repo"
        git_init(repo)

        ui.lazygit(repo)

        assert.equals(1, #runs)
        assert.is_nil(runs[1].opts.env)
        assert.equals(0, #spawned, "lazygit runs in the pane, not in an own float")
        assert.equals(0, #errors, table.concat(errors, "\n"))
      end)

      it("run() returning false falls back to the own float", function()
        package.loaded["terminal"] = {
          run = function(cmd, opts)
            runs[#runs + 1] = { cmd = cmd, opts = opts }
            return false, "cannot start"
          end,
        }
        local repo = scratch .. "/repo"
        git_init(repo)

        ui.lazygit(repo)

        assert.equals(1, #runs)
        assert.equals(1, #spawned, "the own jobstart route is used")
        assert.equals(real(repo), real(spawned[1].argv[3]))
      end)

      it("run() raising is reported and falls back to the own float", function()
        package.loaded["terminal"] = {
          run = function()
            error("kaputt")
          end,
        }
        local repo = scratch .. "/repo"
        git_init(repo)

        ui.lazygit(repo)

        assert.equals(1, #errors)
        assert.is_truthy(errors[1]:find("terminal.nvim failed", 1, true), errors[1])
        assert.equals(1, #spawned, "the own jobstart route is used")
      end)

      -- A fake with a registry like terminal.nvim's: `run` creates a native
      -- handle (a real buffer) and calls on_open like run_direct does.
      describe("a lazygit terminal that already exists", function()
        local registry
        local opens
        local bufs

        ---@param handle table
        local function add(handle)
          bufs[#bufs + 1] = handle.bufnr
          registry[#registry + 1] = handle
        end

        before_each(function()
          registry, opens, bufs = {}, {}, {}
          package.loaded["terminal"] = {
            run = function(cmd, opts)
              runs[#runs + 1] = { cmd = cmd, opts = opts }
              -- run_direct replaces the earlier terminal of that name.
              for i = #registry, 1, -1 do
                if registry[i].name == opts.name then table.remove(registry, i) end
              end
              local handle = {
                name = opts.name,
                backend = "native",
                bufnr = vim.api.nvim_create_buf(false, true),
              }
              add(handle)
              opts.on_open(handle)
              return true, nil, handle
            end,
            list = function()
              return registry
            end,
            open = function(target)
              opens[#opens + 1] = target
              for _, h in ipairs(registry) do
                if h.name == target.name then return h end
              end
              return nil, "no such terminal"
            end,
          }
        end)

        after_each(function()
          for _, b in ipairs(bufs) do
            pcall(vim.api.nvim_buf_delete, b, { force = true })
          end
        end)

        it("is shown again for the same repo, not replaced (q only hid it)", function()
          local repo = scratch .. "/repo"
          git_init(repo)

          ui.lazygit(repo)
          ui.lazygit(repo)

          assert.equals(1, #runs, "the running lazygit is not replaced")
          assert.equals(1, #opens)
          assert.equals("lazygit", opens[1].name)
          assert.equals("float", opens[1].layout)
          assert.equals(0, #errors, table.concat(errors, "\n"))
        end)

        it("is replaced for another repo", function()
          local repo_a, repo_b = scratch .. "/a", scratch .. "/b"
          git_init(repo_a)
          git_init(repo_b)

          ui.lazygit(repo_a)
          ui.lazygit(repo_b)

          assert.equals(2, #runs)
          assert.equals(0, #opens)
          assert.equals(real(repo_b), real(runs[2].cmd[3]))
        end)

        it("is replaced when it is not gitsuite's (a session restore) or has exited", function()
          local repo = scratch .. "/repo"
          git_init(repo)
          -- Restored by terminal.nvim's sessions: same name, no on_open.
          add({ name = "lazygit", backend = "native", bufnr = vim.api.nvim_create_buf(false, true) })

          ui.lazygit(repo)
          assert.equals(1, #runs, "the restored terminal is replaced")
          assert.equals(0, #opens)

          registry[1].exited = true
          ui.lazygit(repo)
          assert.equals(2, #runs, "an exited lazygit is not shown again")
          assert.equals(0, #opens)
        end)
      end)

      it("on_open maps q/<Esc> in the buffer; a pane without one is fine", function()
        local repo = scratch .. "/repo"
        git_init(repo)
        ui.lazygit(repo)
        assert.equals(1, #runs)

        local buf = vim.api.nvim_create_buf(false, true)
        runs[1].opts.on_open({ name = "lazygit", bufnr = buf })
        vim.api.nvim_buf_call(buf, function()
          assert.equals(1, vim.fn.maparg("q", "n", false, true).buffer)
          assert.equals(1, vim.fn.maparg("<Esc>", "t", false, true).buffer)
        end)
        vim.api.nvim_buf_delete(buf, { force = true })

        -- A multiplexer backend hands a pane, not a buffer.
        runs[1].opts.on_open({ name = "lazygit", pane = "%1" })
        assert.equals(0, #errors, table.concat(errors, "\n"))
      end)

      it("a terminal module without run() falls back to the own float", function()
        package.loaded["terminal"] = {}
        local repo = scratch .. "/repo"
        git_init(repo)

        ui.lazygit(repo)

        assert.equals(0, #runs)
        assert.equals(1, #spawned, "the own jobstart route is used")
      end)
    end)
  end)

  -- Bug regression: `:Git ui <Tab>` used to list lazygit/neogit unconditionally,
  -- including when the binary/plugin behind them isn't actually available --
  -- composer.complete now reads each route's own `check` (usrcmds.lua) to
  -- decide, the same test its `run` already applies.
  describe(":Git ui <Tab> completion", function()
    local original_executable = vim.fn.executable

    before_each(function()
      require("gitsuite.bindings.usrcmds").register({ commands = { git = "Git" } })
    end)

    after_each(function()
      vim.fn.executable = original_executable
      -- Unconditional, not just the one test that sets it: if a case errors
      -- between the set and its own cleanup, an inline reset never runs, and
      -- `scripts/test.sh` runs every spec file in ONE nvim process
      -- (`sequential = true`) -- a leaked package.loaded["neogit"] would
      -- silently flip "not installed" assertions in whatever spec happens to
      -- run after this file.
      package.loaded["neogit"] = nil
    end)

    it("omits lazygit and neogit when neither is available", function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.executable = function(name)
        if name == "lazygit" then return 0 end
        return original_executable(name)
      end

      local candidates = vim.fn.getcompletion("Git ui ", "cmdline")

      assert.is_falsy(vim.tbl_contains(candidates, "lazygit"))
      assert.is_falsy(vim.tbl_contains(candidates, "neogit"))
      -- diffview has no `check` (it degrades to diff.nvim's split, never
      -- "not installed" -- see features/ui/init.lua) -- always offered.
      assert.is_truthy(vim.tbl_contains(candidates, "diffview"))
    end)

    it("offers lazygit once the executable is on $PATH", function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.executable = function(name)
        if name == "lazygit" then return 1 end
        return original_executable(name)
      end

      local candidates = vim.fn.getcompletion("Git ui ", "cmdline")

      assert.is_truthy(vim.tbl_contains(candidates, "lazygit"))
      -- neogit's own check reads package.loaded (LUA-91: never `require`d to
      -- probe) -- this suite never loads it, so it stays excluded here too.
      assert.is_falsy(vim.tbl_contains(candidates, "neogit"))
    end)

    it("offers neogit once it is loaded (package.loaded set)", function()
      package.loaded["neogit"] = { open = function() end }

      local candidates = vim.fn.getcompletion("Git ui ", "cmdline")

      assert.is_truthy(vim.tbl_contains(candidates, "neogit"))
    end)
  end)
end)
