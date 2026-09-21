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
describe("gitsuite.features.ui", function()
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
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("neogit() reports 'not installed', does not crash, without neogit", function()
    local ok = pcall(ui.neogit)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  it("diffview() reports 'not installed', does not crash, without diffview", function()
    local ok = pcall(ui.diffview)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
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
      ---@diagnostic disable-next-line: undefined-field
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
    end)

    after_each(function()
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
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(1, #errors, "exactly one error is reported")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_truthy(errors[1]:find(pattern, 1, true), errors[1])
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(0, #spawned, "no process is started")
      ---@diagnostic disable-next-line: undefined-field
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

      ---@diagnostic disable-next-line: undefined-field
      assert.equals(0, #errors, table.concat(errors, "\n"))
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(1, #spawned)
      local argv = spawned[1].argv
      ---@diagnostic disable-next-line: undefined-field
      assert.same({ "lazygit", "-p" }, { argv[1], argv[2] })
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(real(repo), real(argv[3]), "-p is the repo root, not the subdirectory")
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(real(repo), real(spawned[1].opts.cwd), "the process cwd is the repo root")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(real(repo) ~= real(original_cwd), "not the repo Neovim happens to be in")
    end)

    it("without an argument, still uses the repo of the cwd", function()
      local repo = scratch .. "/repo"
      git_init(repo)
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      ui.lazygit()

      ---@diagnostic disable-next-line: undefined-field
      assert.equals(0, #errors, table.concat(errors, "\n"))
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(1, #spawned)
      ---@diagnostic disable-next-line: undefined-field
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
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(0, #errors, table.concat(errors, "\n"))
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(1, #spawned)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(real(repo), real(spawned[1].argv[3]), "the <dir> argument reaches lazygit")

      -- No argument: the cwd's repo (this suite runs inside the gitsuite checkout).
      spawned = {}
      vim.cmd("stopinsert")
      vim.cmd("Git ui lazygit")
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(1, #spawned)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(real(original_cwd), real(spawned[1].argv[3]))
    end)
  end)
end)
