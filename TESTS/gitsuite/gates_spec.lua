-- TESTS/gitsuite/gates_spec.lua -- gitsuite.features.status.gates
-- (`:Git status todos|lint|spell`), against real throwaway git repos.
-- insights.nvim is not a sibling checkout of this test environment (like
-- relink_spec.lua's filetree.nvim), so `todos` is faked via
-- `package.loaded["insights.todos"]` -- this suite is about what gates.lua
-- computes and filters, not insights.nvim's own scanner (that belongs to
-- insights.nvim's own test suite). `lint`/`spell` need no soft dependency.
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
describe("gitsuite.features.status.gates", function()
  local gates
  local original_cwd, repo

  local function run(...)
    return vim.system({ ... }, { text = true, cwd = repo }):wait()
  end

  before_each(function()
    package.loaded["gitsuite.features.status.gates"] = nil
    gates = require("gitsuite.features.status.gates")

    original_cwd = vim.fn.getcwd()
    repo = vim.fn.tempname() .. "-gitsuite-gates"
    vim.fn.mkdir(repo, "p")
    local init = run("git", "init", "-q")
    assert.equals(0, init.code, "fixture: git init failed: " .. tostring(init.stderr))
    run("git", "config", "user.email", "test@example.com")
    run("git", "config", "user.name", "Test")
    vim.api.nvim_set_current_dir(repo)

    -- Each gate only populates the quickfix list when it finds something,
    -- so a stale list from a previous test's own findings must not survive
    -- into a "no findings" assertion here.
    vim.fn.setqflist({}, "r", { items = {} })
  end)

  after_each(function()
    vim.api.nvim_set_current_dir(original_cwd)
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.delete, repo, "rf")
  end)

  describe("todos()", function()
    it("without insights.nvim: reports it is not installed, no error", function()
      vim.fn.writefile({ "-- TODO: anything" }, repo .. "/changed.lua")

      local real_todos = package.loaded["insights.todos"]
      package.loaded["insights.todos"] = nil
      local orig_preload = package.preload["insights.todos"]
      package.preload["insights.todos"] = function()
        error("no insights.nvim here")
      end

      local seen = {}
      local original_notify = vim.notify
      vim.notify = function(msg)
        seen[#seen + 1] = tostring(msg)
      end
      local ok = pcall(gates.todos)
      vim.notify = original_notify

      package.preload["insights.todos"] = orig_preload
      package.loaded["insights.todos"] = real_todos

      assert.is_true(ok, "must not raise, just report an error")
      assert.equals(1, #seen)
      assert.is_truthy(seen[1]:find("insights.nvim is not installed", 1, true))
    end)

    it("no changed files: reports so, never reaches insights.nvim", function()
      vim.fn.writefile({ "content" }, repo .. "/tracked.lua")
      run("git", "add", "tracked.lua")
      run("git", "commit", "-q", "-m", "init")

      local scan_calls = 0
      package.loaded["insights.todos"] = {
        scan = function()
          scan_calls = scan_calls + 1
          return {}, nil
        end,
      }
      gates.todos()
      package.loaded["insights.todos"] = nil

      assert.equals(0, scan_calls)
    end)

    it("filters a whole-tree scan down to the changed files only", function()
      vim.fn.writefile({ "content" }, repo .. "/unchanged.lua")
      run("git", "add", "unchanged.lua")
      run("git", "commit", "-q", "-m", "init")
      vim.fn.writefile({ "-- TODO: fix the changed one" }, repo .. "/changed.lua")

      package.loaded["insights.todos"] = {
        scan = function(opts)
          -- gates.lua derives this from git.repo_root(), which normalizes
          -- separators -- not necessarily the same spelling as `repo`
          -- (from vim.fn.tempname()) on Windows. Use what was actually
          -- passed, so this fixture stays self-consistent either way.
          local root = opts.cwd
          assert.is_not_nil(root)
          return {
            {
              filename = root .. "/unchanged.lua",
              lnum = 1,
              col = 1,
              text = "TODO: this one is not changed",
              keyword = "TODO",
            },
            {
              filename = root .. "/changed.lua",
              lnum = 1,
              col = 1,
              text = "TODO: fix the changed one",
              keyword = "TODO",
            },
          },
            nil
        end,
      }
      gates.todos()
      package.loaded["insights.todos"] = nil

      local items = vim.fn.getqflist({ items = 0 }).items
      assert.equals(1, #items, "only the changed file's TODO made it into the quickfix list")
      local name = vim.fn.bufname(items[1].bufnr)
      assert.is_truthy(name:find("changed%.lua$"))
      vim.cmd("cclose")
    end)
  end)

  describe("lint()", function()
    it("no changed files: reports so", function()
      vim.fn.writefile({ "content" }, repo .. "/tracked.lua")
      run("git", "add", "tracked.lua")
      run("git", "commit", "-q", "-m", "init")

      local ok = pcall(gates.lint)
      assert.is_true(ok)
    end)

    it("collects diagnostics from an open changed file, counts the rest as skipped", function()
      local open_path = repo .. "/open.lua"
      local closed_path = repo .. "/closed.lua"
      vim.fn.writefile({ "content" }, open_path)
      vim.fn.writefile({ "content" }, closed_path)

      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      local bufnr = vim.api.nvim_get_current_buf()
      local ns = vim.api.nvim_create_namespace("gitsuite_gates_spec")
      vim.diagnostic.set(ns, bufnr, {
        { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "boom" },
      })

      local seen = {}
      local original_notify = vim.notify
      vim.notify = function(msg)
        seen[#seen + 1] = tostring(msg)
      end
      gates.lint()
      vim.notify = original_notify
      vim.diagnostic.reset(ns, bufnr)

      local items = vim.fn.getqflist({ items = 0 }).items
      assert.equals(1, #items, "the open file's diagnostic made it into the quickfix list")
      assert.is_truthy(items[1].text:find("boom", 1, true))
      assert.is_truthy(
        table.concat(seen, "\n"):find("1 changed file", 1, true),
        "notifies that the unopened file was skipped"
      )
      vim.cmd("cclose")
    end)
  end)

  describe("spell()", function()
    it("no changed files: reports so", function()
      vim.fn.writefile({ "content" }, repo .. "/tracked.lua")
      run("git", "add", "tracked.lua")
      run("git", "commit", "-q", "-m", "init")

      local ok = pcall(gates.spell)
      assert.is_true(ok)
    end)

    it("flags a misspelling in an untracked changed file's on-disk content", function()
      local original_spelllang = vim.o.spelllang
      vim.o.spelllang = "en"
      vim.fn.writefile({ "this is a tset of the speling gate" }, repo .. "/note.md")

      gates.spell()
      vim.o.spelllang = original_spelllang

      local items = vim.fn.getqflist({ items = 0 }).items
      assert.is_true(#items > 0, "at least one misspelling was found")
      local words = {}
      for _, item in ipairs(items) do
        words[item.text] = true
      end
      assert.is_true(words["tset"] or words["speling"], "the actual misspelled words are reported")
      vim.cmd("cclose")
    end)

    it("does not flag a clean file", function()
      local original_spelllang = vim.o.spelllang
      vim.o.spelllang = "en"
      vim.fn.writefile({ "this is a clean sentence with no mistakes" }, repo .. "/clean.md")

      gates.spell()
      vim.o.spelllang = original_spelllang

      local items = vim.fn.getqflist({ items = 0 }).items
      assert.equals(0, #items)
    end)

    it("skips a binary changed file instead of spell-checking its raw bytes", function()
      local original_spelllang = vim.o.spelllang
      vim.o.spelllang = "en"
      -- A NUL byte marks this as binary (git's own heuristic) -- content
      -- that would otherwise flag as a misspelling ("tset") must never be
      -- read as text in the first place. Written via plain Lua io, not
      -- vim.fn.writefile: an embedded NUL in a Lua string crosses the
      -- Lua->Vimscript bridge as a Blob, which writefile()'s list-of-lines
      -- form rejects.
      local fh = assert(io.open(repo .. "/asset.bin", "wb"))
      fh:write("tset\0binary")
      fh:close()

      local ok = pcall(gates.spell)
      vim.o.spelllang = original_spelllang

      assert.is_true(ok, "a binary changed file must not error the gate")
      local items = vim.fn.getqflist({ items = 0 }).items
      assert.equals(0, #items, "binary content is skipped, not flagged")
    end)
  end)
end)
