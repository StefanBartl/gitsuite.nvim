-- TESTS/gitsuite/blame_spec.lua -- gitsuite.features.blame against this
-- repo's own tracked README.md (real git history, no fixture needed).
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
describe("gitsuite.features.blame", function()
  local blame
  local bufnr

  before_each(function()
    package.loaded["gitsuite.features.blame"] = nil
    blame = require("gitsuite.features.blame")
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/README.md"))
    bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("line() does not error on a real tracked file", function()
    local ok = pcall(blame.line)
    assert.is_true(ok)
  end)

  it("line() reports an error, not a crash, on an unnamed buffer", function()
    vim.cmd("enew")
    local ok = pcall(blame.line)
    assert.is_true(ok, "must not raise even without a file")
    vim.cmd("bdelete!")
  end)

  it("toggle() sets a buffer-local flag and an extmark, toggling again clears both", function()
    assert.is_nil(vim.b[bufnr].gitsuite_blame_active)

    -- The refresh is async (LUA-15: a blocking call on every CursorHold
    -- would freeze the UI) -- the first extmark lands after the underlying
    -- git job completes, not synchronously when toggle() returns.
    blame.toggle()
    assert.is_true(vim.b[bufnr].gitsuite_blame_active)
    local ns = vim.api.nvim_create_namespace("gitsuite_blame")
    vim.wait(2000, function()
      return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}) > 0
    end)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
    assert.is_true(#marks > 0, "toggle() on must place at least one extmark")

    blame.toggle()
    assert.is_nil(vim.b[bufnr].gitsuite_blame_active)
    marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
    assert.equals(0, #marks, "toggle() off must clear its own extmarks")
  end)

  it(
    "toggling off right after on does not let the in-flight async result "
      .. "resurrect a ghost extmark at the original line",
    function()
      -- Deleting the augroup on toggle-off does not cancel the git process
      -- refresh() already kicked off: that request's callback used to check
      -- only its own "on session"-local `generation`, which nothing had
      -- incremented since (no more CursorHold fired once toggling off tore
      -- the augroup down) -- so it still matched, and the callback placed
      -- its extmark anyway once it finally returned, permanently, at
      -- whatever line the cursor was on when *this* toggle() call started.
      local ns = vim.api.nvim_create_namespace("gitsuite_blame")

      blame.toggle() -- on: kicks off an async blame lookup for this line
      blame.toggle() -- off, almost certainly before that lookup returns

      -- Give the async git process every chance to finish and, if the race
      -- were still there, place its now-stale extmark.
      vim.wait(1500)

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
      assert.equals(
        0,
        #marks,
        "a blame result from before toggle-off must not add an extmark after it"
      )
    end
  )

  it("full() opens a synced split with one line per source line", function()
    local src_win = vim.api.nvim_get_current_win()
    local expected = #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    blame.full()

    local blame_win = vim.api.nvim_get_current_win()
    assert.are_not.equal(src_win, blame_win, "full() opens a new window, not the source one")

    local blame_bufnr = vim.api.nvim_win_get_buf(blame_win)
    local lines = vim.api.nvim_buf_get_lines(blame_bufnr, 0, -1, false)
    assert.equals(expected, #lines, "one blame line per source line")

    assert.is_true(vim.wo[blame_win].scrollbind)
    assert.is_true(vim.wo[src_win].scrollbind)

    -- Closing the blame window must clear scrollbind on the source window
    -- again (BufWinLeave cleanup), not leave it stuck bound forever.
    vim.api.nvim_win_close(blame_win, true)
    assert.is_false(vim.wo[src_win].scrollbind)
  end)
end)

-- for_location(dir, path, lnum[, cb]) against a throwaway repo: history that
-- is known exactly (two commits by two authors, one uncommitted edit), a path
-- with a space, and -- unlike the block above -- no buffer anywhere.
describe("gitsuite.features.blame.for_location", function()
  local blame
  local repo
  local original_notify = vim.notify

  ---@param args string[]
  ---@param author string
  local function git(args, author)
    local argv =
      { "git", "-c", "user.name=" .. author, "-c", "user.email=" .. author .. "@example.test" }
    vim.list_extend(argv, args)
    local res = vim.system(argv, { cwd = repo }):wait()
    assert.equals(0, res.code, table.concat(args, " ") .. ": " .. tostring(res.stderr))
  end

  before_each(function()
    package.loaded["gitsuite.features.blame"] = nil
    blame = require("gitsuite.features.blame")

    repo = vim.fn.tempname()
    vim.fn.mkdir(repo .. "/sub dir", "p")
    git({ "init", "-q" }, "Init")
    local file = repo .. "/sub dir/a b.txt"
    vim.fn.writefile({ "one", "two", "three" }, file)
    git({ "add", "." }, "Alice")
    git({ "commit", "-q", "-m", "first commit" }, "Alice")
    vim.fn.writefile({ "one", "TWO", "three" }, file)
    git({ "commit", "-q", "-am", "second commit" }, "Bob")
    -- An uncommitted change on line 3.
    vim.fn.writefile({ "one", "TWO", "three!" }, file)
  end)

  after_each(function()
    vim.notify = original_notify
    vim.fn.delete(repo, "rf")
  end)

  it("returns the author, sha and summary of one line -- with no buffer open", function()
    assert.equals(-1, vim.fn.bufnr(repo .. "/sub dir/a b.txt"), "the fixture is not open in Neovim")

    local first, err1 = blame.for_location(repo .. "/sub dir", "a b.txt", 1)
    local second, err2 = blame.for_location(repo .. "/sub dir", "a b.txt", 2)

    assert.is_nil(err1)
    assert.is_nil(err2)
    assert.equals("Alice", first.author)
    assert.equals("first commit", first.summary)
    assert.equals(1, first.line)
    assert.is_truthy(first.sha:match("^%x+$") and #first.sha == 40)
    assert.equals("Bob", second.author)
    assert.equals("second commit", second.summary)
    assert.equals(2, second.line)
    assert.is_number(second.author_time)
  end)

  it("marks an uncommitted line with the all-zero sha", function()
    local entry = blame.for_location(repo .. "/sub dir", "a b.txt", 3)
    assert.is_truthy(entry.sha:match("^0+$"))
  end)

  it("takes an absolute path and any directory inside the repo", function()
    local entry, err = blame.for_location(repo, repo .. "/sub dir/a b.txt", 1)
    assert.is_nil(err)
    assert.equals("Alice", entry.author)
  end)

  it("reports git failures as (nil, err): line past the end, untracked file, no repo", function()
    local past, err_past = blame.for_location(repo .. "/sub dir", "a b.txt", 99)
    assert.is_nil(past)
    assert.is_truthy(err_past and err_past ~= "")

    vim.fn.writefile({ "x" }, repo .. "/untracked.txt")
    local untracked, err_untracked = blame.for_location(repo, "untracked.txt", 1)
    assert.is_nil(untracked)
    assert.is_truthy(err_untracked and err_untracked ~= "")

    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    local none, err_none = blame.for_location(outside, "a.txt", 1)
    vim.fn.delete(outside, "rf")
    assert.is_nil(none)
    assert.is_truthy(err_none and err_none ~= "")
  end)

  it("rejects an invalid location without running git", function()
    for _, bad in ipairs({ 0, -1, 1.5 }) do
      local entry, err = blame.for_location(repo, "untracked.txt", bad)
      assert.is_nil(entry)
      assert.is_truthy(err and err:find("invalid location", 1, true), tostring(bad))
    end
    local entry, err = blame.for_location(repo, "", 1)
    assert.is_nil(entry)
    assert.is_truthy(err and err:find("invalid location", 1, true))
  end)

  it("with a callback: same result, delivered asynchronously", function()
    local got, got_err, called = nil, nil, false
    local handle = blame.for_location(repo .. "/sub dir", "a b.txt", 2, function(entry, err)
      got, got_err, called = entry, err, true
    end)
    assert.is_function(handle.stop)
    assert.is_false(called, "the callback never runs synchronously")

    assert.is_true(vim.wait(5000, function()
      return called
    end, 10))
    assert.is_nil(got_err)
    assert.equals("Bob", got.author)
  end)

  it(
    "with a callback: errors and invalid input arrive as (nil, err), also asynchronously",
    function()
      local results = {}
      blame.for_location(repo, "untracked-and-missing.txt", 1, function(entry, err)
        results.missing = { entry, err }
      end)
      blame.for_location(repo, "a b.txt", 0, function(entry, err)
        results.invalid = { entry, err }
      end)
      assert.is_nil(results.invalid, "invalid input is reported asynchronously too")

      assert.is_true(vim.wait(5000, function()
        return results.missing ~= nil and results.invalid ~= nil
      end, 10))
      assert.is_nil(results.missing[1])
      assert.is_truthy(results.missing[2] and results.missing[2] ~= "")
      assert.is_truthy(results.invalid[2]:find("invalid location", 1, true))
    end
  )

  it("line() reports the same entry through a real buffer (behaviour unchanged)", function()
    local notes = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/sub dir/a b.txt"))
    local bufnr = vim.api.nvim_get_current_buf()

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    blame.line()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    blame.line()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

    assert.equals(2, #notes)
    assert.is_truthy(
      notes[1]:find("Bob", 1, true) and notes[1]:find("second commit", 1, true),
      notes[1]
    )
    assert.is_truthy(notes[2]:find("uncommitted", 1, true), notes[2])
  end)
end)
