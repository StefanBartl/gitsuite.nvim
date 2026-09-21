-- TESTS/gitsuite/conflict_git_spec.lua -- gitsuite.features.conflict against
-- conflicts produced by a REAL `git merge` in a throwaway repository.
--
-- Why real merges: the parser is the one place in gitsuite.nvim where a bug
-- means lost code in a half-finished merge, and string fixtures only prove
-- that the parser agrees with what the author *believed* git writes. Here
-- git writes the conflict (all three `merge.conflictStyle` values, LF and
-- CRLF files, `core.autocrlf` on and off) and git is also the oracle: for a
-- file whose only differences are the conflicts, `choose("ours")` /
-- `choose("theirs")` on every region must leave exactly the bytes that
-- `git checkout --ours|--theirs` leaves.
--
-- Nothing here may skip itself: a missing `git`, or a merge that unexpectedly
-- does not conflict, fails loudly (a test that quietly proves nothing is
-- worse than none).

local FILE = "conflicted file.txt" -- a space on purpose

describe("gitsuite.features.conflict against real `git merge` conflicts", function()
  local conflict
  local repo
  local original_cwd
  local original_notify
  local notices

  ---@param args string[]
  ---@param autocrlf boolean
  ---@param allow_fail? boolean
  ---@return string stdout
  ---@return integer code
  local function git(args, autocrlf, allow_fail)
    local argv = {
      "git",
      "-c",
      "user.name=gitsuite-spec",
      "-c",
      "user.email=spec@example.test",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.autocrlf=" .. tostring(autocrlf),
      "-c",
      "core.safecrlf=false",
    }
    vim.list_extend(argv, args)
    local res = vim.system(argv, { cwd = repo, text = true }):wait()
    if not allow_fail then
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(0, res.code, "git " .. table.concat(args, " ") .. ": " .. tostring(res.stderr))
    end
    return res.stdout or "", res.code
  end

  ---@param path string
  ---@param text string
  local function write_bytes(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---@param path string
  ---@return string
  local function read_bytes(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
  end

  ---@param lines string[]
  ---@param eol string
  ---@return string
  local function join(lines, eol)
    if #lines == 0 then return "" end
    return table.concat(lines, eol) .. eol
  end

  -- A fixture is a list of segments: `{ plain = {...} }` is unchanged text,
  -- `{ base = {...}, ours = {...}, theirs = {...} }` is a conflict. Every line
  -- of a conflict differs between the three sides on purpose -- git trims a
  -- common prefix/suffix out of a conflict (zdiff3 also out of the base), and
  -- the expected result below is computed from these arrays, not from git.
  ---@param fixture table[]
  ---@param side "base"|"ours"|"theirs"|"both"|"none"
  ---@param eol string
  ---@return string
  local function expected(fixture, side, eol)
    local out = {}
    for _, seg in ipairs(fixture) do
      if seg.plain then
        vim.list_extend(out, seg.plain)
      elseif side == "base" then
        vim.list_extend(out, seg.base)
      elseif side == "ours" or side == "both" then
        vim.list_extend(out, seg.ours)
      end
      if seg.theirs and (side == "theirs" or side == "both") then
        vim.list_extend(out, seg.theirs)
      end
    end
    return join(out, eol)
  end

  ---@param fixture table[]
  ---@param side "base"|"ours"|"theirs"
  ---@return string[]
  local function version(fixture, side)
    local out = {}
    for _, seg in ipairs(fixture) do
      vim.list_extend(out, seg.plain or seg[side])
    end
    return out
  end

  ---@param fixture table[]
  ---@param style "merge"|"diff3"|"zdiff3"
  ---@param eol string
  ---@param autocrlf boolean
  ---@param attributes? string Contents of a `.gitattributes` committed with the base.
  ---@return string path
  local function make_conflict(fixture, style, eol, autocrlf, attributes)
    git({ "init", "-q", "-b", "main" }, autocrlf)
    local path = repo .. "/" .. FILE
    write_bytes(path, join(version(fixture, "base"), eol))
    if attributes then write_bytes(repo .. "/.gitattributes", attributes) end
    git({ "add", "." }, autocrlf)
    git({ "commit", "-q", "-m", "base" }, autocrlf)
    git({ "checkout", "-q", "-b", "other" }, autocrlf)
    write_bytes(path, join(version(fixture, "theirs"), eol))
    git({ "commit", "-q", "-am", "theirs" }, autocrlf)
    git({ "checkout", "-q", "main" }, autocrlf)
    write_bytes(path, join(version(fixture, "ours"), eol))
    git({ "commit", "-q", "-am", "ours" }, autocrlf)
    local _, code = git({ "-c", "merge.conflictStyle=" .. style, "merge", "other" }, autocrlf, true)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(code ~= 0, "fixture: the merge must conflict, otherwise this proves nothing")
    return path
  end

  ---@param path string
  ---@return integer bufnr
  local function open(path)
    vim.cmd("silent! %bwipeout!")
    vim.cmd.edit(vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
  end

  ---@param bufnr integer
  ---@param keep string
  local function resolve_all(bufnr, keep)
    for _ = 1, 100 do
      local regions = conflict.scan(bufnr)
      if #regions == 0 then return end
      vim.api.nvim_win_set_cursor(0, { regions[1].start_line + 1, 0 })
      conflict.choose(keep)
    end
    error("resolve_all(" .. keep .. ") did not converge -- choose() kept refusing")
  end

  ---@param text string
  ---@return integer
  local function count_markers(text)
    local n = 0
    for line in text:gmatch("[^\n]+") do
      if line:match("^<<<<<<<") then n = n + 1 end
    end
    return n
  end

  before_each(function()
    package.loaded["gitsuite.features.conflict"] = nil
    conflict = require("gitsuite.features.conflict")
    original_cwd = vim.fn.getcwd()
    original_notify = vim.notify
    notices = {}
    vim.notify = function(msg, level)
      notices[#notices + 1] = { msg = tostring(msg), level = level }
    end
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    vim.api.nvim_set_current_dir(repo)
  end)

  after_each(function()
    vim.notify = original_notify
    vim.cmd("silent! %bwipeout!")
    vim.api.nvim_set_current_dir(original_cwd)
    pcall(vim.fn.delete, repo, "rf")
  end)

  -- ── the matrix: every side of every region, byte for byte ───────────────
  local fixtures = {
    {
      name = "one conflict between unchanged lines",
      fixture = {
        { plain = { "header one", "header two" } },
        { base = { "b1", "b2" }, ours = { "o1", "o2" }, theirs = { "t1", "t2" } },
        { plain = { "tail one", "tail two" } },
      },
    },
    {
      name = "three separated conflicts",
      fixture = {
        { plain = { "top" } },
        { base = { "b-a" }, ours = { "o-a" }, theirs = { "t-a" } },
        { plain = { "u1", "u2", "u3", "u4", "u5", "u6" } },
        { base = { "b-b1", "b-b2" }, ours = { "o-b1", "o-b2" }, theirs = { "t-b1", "t-b2" } },
        { plain = { "v1", "v2", "v3", "v4", "v5", "v6" } },
        { base = { "b-c" }, ours = { "o-c1", "o-c2", "o-c3" }, theirs = { "t-c" } },
        { plain = { "bottom" } },
      },
    },
    {
      name = "one side deleted everything (empty section)",
      fixture = {
        { plain = { "keep one", "keep two", "keep three", "keep four" } },
        { base = { "b1" }, ours = {}, theirs = { "t1" } },
        { plain = { "keep five", "keep six", "keep seven", "keep eight" } },
      },
    },
  }

  local eols = {
    { name = "LF", eol = "\n", autocrlf = false },
    { name = "CRLF committed", eol = "\r\n", autocrlf = false },
    { name = "CRLF worktree + autocrlf", eol = "\r\n", autocrlf = true },
  }

  for _, style in ipairs({ "merge", "diff3", "zdiff3" }) do
    for _, ending in ipairs(eols) do
      for _, case in ipairs(fixtures) do
        -- The empty-section fixture is the same for every ending; running it
        -- for LF only keeps the suite's git calls (and time) down.
        if case.name:match("empty section") and ending.name ~= "LF" then goto continue end

        it(("%s / %s / %s"):format(style, ending.name, case.name), function()
          local path = make_conflict(case.fixture, style, ending.eol, ending.autocrlf)
          local conflicted = read_bytes(path)
          local n_conflicts = 0
          for _, seg in ipairs(case.fixture) do
            if seg.ours then n_conflicts = n_conflicts + 1 end
          end
          ---@diagnostic disable-next-line: undefined-field
          assert.equals(
            n_conflicts,
            count_markers(conflicted),
            "fixture: git must report exactly one conflict per conflicting segment"
          )

          -- The parser sees exactly the conflicts git wrote, none ambiguous.
          local bufnr = open(path)
          local regions = conflict.scan(bufnr)
          ---@diagnostic disable-next-line: undefined-field
          assert.equals(n_conflicts, #regions, "one region per `<<<<<<<` git wrote")
          for _, r in ipairs(regions) do
            ---@diagnostic disable-next-line: undefined-field
            assert.is_falsy(r.ambiguous)
            ---@diagnostic disable-next-line: undefined-field
            assert.equals(style == "merge" and "merge" or "diff3", r.style)
            ---@diagnostic disable-next-line: undefined-field
            assert.equals("HEAD", r.ours_label)
            ---@diagnostic disable-next-line: undefined-field
            assert.equals("other", r.theirs_label)
          end

          ---@param keep string
          ---@return string
          local function resolved_bytes(keep)
            write_bytes(path, conflicted)
            local buf = open(path)
            resolve_all(buf, keep)
            vim.cmd("silent write")
            return read_bytes(path)
          end

          -- Independent expectation, computed from the fixture, not from git.
          for _, keep in ipairs({ "ours", "theirs", "both", "none" }) do
            ---@diagnostic disable-next-line: undefined-field
            assert.equals(
              expected(case.fixture, keep, ending.eol),
              resolved_bytes(keep),
              ("choose('%s') on every region"):format(keep)
            )
          end
          if style ~= "merge" then
            ---@diagnostic disable-next-line: undefined-field
            assert.equals(
              expected(case.fixture, "base", ending.eol),
              resolved_bytes("base"),
              "choose('base') on every region"
            )
          end

          -- Git as the oracle: the same bytes `git checkout --ours/--theirs` writes.
          for _, side in ipairs({ "ours", "theirs" }) do
            local mine = resolved_bytes(side)
            write_bytes(path, conflicted)
            git({ "checkout", "--" .. side, "--", FILE }, ending.autocrlf)
            ---@diagnostic disable-next-line: undefined-field
            assert.equals(
              read_bytes(path),
              mine,
              ("choose('%s') matches `git checkout --%s`"):format(side, side)
            )
          end
        end)

        ::continue::
      end
    end
  end

  -- ── false alarms: a `=======` that belongs to the text ──────────────────
  describe("a Markdown file whose text contains `=======` lines", function()
    local doc = {
      "# Doc",
      "",
      "First section",
      "=======",
      "",
      "the conflicting line",
      "",
      "Second section",
      "=======",
      "",
      "last line",
    }

    ---@param conflicting string
    ---@return string[]
    local function with(conflicting)
      local out = vim.deepcopy(doc)
      out[6] = conflicting
      return out
    end

    it("a conflict elsewhere in the file is found exactly and resolves like git", function()
      local fixture = {
        { plain = vim.list_slice(doc, 1, 5) },
        { base = { doc[6] }, ours = { "ours line" }, theirs = { "theirs line" } },
        { plain = vim.list_slice(doc, 7, #doc) },
      }
      local path = make_conflict(fixture, "merge", "\n", false)
      local conflicted = read_bytes(path)
      local bufnr = open(path)

      local regions = conflict.scan(bufnr)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(1, #regions, "the setext underlines outside the conflict are not regions")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_falsy(regions[1].ambiguous)

      resolve_all(bufnr, "ours")
      vim.cmd("silent write")
      local mine = read_bytes(path)
      write_bytes(path, conflicted)
      git({ "checkout", "--ours", "--", FILE }, false)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(read_bytes(path), mine)
      ---@diagnostic disable-next-line: undefined-field
      assert.same(with("ours line"), vim.split(mine, "\n", { trimempty = true }))
    end)

    -- Both sides change the heading and the text around an unchanged
    -- `=======`. In merge style git joins that into ONE conflict with the
    -- underline inside every section (three `=======` lines, and no way to
    -- tell which one separates the sides); diff3/zdiff3 write two conflicts
    -- with the underline as a common line between them (next tests).
    local setext = {
      {
        base = { "Title", "=======", "text" },
        ours = { "Ours title", "=======", "ours text" },
        theirs = { "Their title", "=======", "their text" },
      },
    }

    do
      local style = "merge"
      it(
        "merge: a conflict that CONTAINS the underline is reported as ambiguous, never guessed",
        function()
          local fixture = setext
          local path = make_conflict(fixture, style, "\n", false)
          local conflicted = read_bytes(path)
          local bufnr = open(path)

          local regions = conflict.scan(bufnr)
          ---@diagnostic disable-next-line: undefined-field
          assert.equals(1, #regions, "the conflict is reported, not silently dropped")
          local r = regions[1]
          ---@diagnostic disable-next-line: undefined-field
          assert.is_true(r.ambiguous, "which `=======` ends our side cannot be told from the text")
          ---@diagnostic disable-next-line: undefined-field
          assert.is_true(#r.separators >= 2)
          ---@diagnostic disable-next-line: undefined-field
          assert.is_true(conflict.has_conflicts(bufnr), "keymaps and the statusline still see it")

          for _, keep in ipairs({ "ours", "theirs", "both", "none", "base" }) do
            notices = {}
            vim.api.nvim_win_set_cursor(0, { r.start_line + 1, 0 })
            conflict.choose(keep)
            ---@diagnostic disable-next-line: undefined-field
            assert.equals(
              conflicted,
              table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n",
              ("choose('%s') must leave the buffer untouched"):format(keep)
            )
            ---@diagnostic disable-next-line: undefined-field
            assert.is_true(
              #notices == 1 and notices[1].msg:lower():find("ambiguous", 1, true) ~= nil,
              "exactly one message, and it says why"
            )
          end
        end
      )
    end

    for _, style in ipairs({ "diff3", "zdiff3" }) do
      it(style .. ": git keeps the two conflicts apart, and each resolves exactly", function()
        local path = make_conflict(setext, style, "\n", false)
        local conflicted = read_bytes(path)
        local bufnr = open(path)

        local regions = conflict.scan(bufnr)
        ---@diagnostic disable-next-line: undefined-field
        assert.equals(2, #regions, "the underline between the two conflicts is a common line")
        for _, r in ipairs(regions) do
          ---@diagnostic disable-next-line: undefined-field
          assert.is_falsy(r.ambiguous)
        end

        for _, side in ipairs({ "ours", "theirs" }) do
          write_bytes(path, conflicted)
          resolve_all(open(path), side)
          vim.cmd("silent write")
          local mine = read_bytes(path)
          write_bytes(path, conflicted)
          git({ "checkout", "--" .. side, "--", FILE }, false)
          ---@diagnostic disable-next-line: undefined-field
          assert.equals(read_bytes(path), mine, ("choose('%s') matches git"):format(side))
        end
      end)
    end

    -- git's own remedy: `conflict-marker-size` lengthens the markers, so the
    -- 7-character `=======` in the text is no longer a marker at all.
    it("a raised conflict-marker-size makes the same conflict unambiguous", function()
      local path = make_conflict(setext, "merge", "\n", false, "*.txt conflict-marker-size=10\n")
      local conflicted = read_bytes(path)
      ---@diagnostic disable-next-line: undefined-field
      assert.is_truthy(
        conflicted:find("<<<<<<<<<< HEAD", 1, true),
        "fixture: git wrote long markers"
      )

      local bufnr = open(path)
      local regions = conflict.scan(bufnr)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(1, #regions)
      ---@diagnostic disable-next-line: undefined-field
      assert.is_falsy(regions[1].ambiguous)

      for _, side in ipairs({ "ours", "theirs" }) do
        write_bytes(path, conflicted)
        resolve_all(open(path), side)
        vim.cmd("silent write")
        local mine = read_bytes(path)
        write_bytes(path, conflicted)
        git({ "checkout", "--" .. side, "--", FILE }, false)
        ---@diagnostic disable-next-line: undefined-field
        assert.equals(read_bytes(path), mine, ("choose('%s') matches git"):format(side))
      end
    end)
  end)

  -- ── a criss-cross merge nests a conflict in the base section ────────────
  it("diff3: a conflicting virtual ancestor is one region, and resolves like git", function()
    local function g(args, allow_fail)
      return git(args, false, allow_fail)
    end
    local path = repo .. "/" .. FILE
    g({ "init", "-q", "-b", "main" })
    write_bytes(path, "line one\nline two\nline three\nline four\nline five\n")
    g({ "add", "." })
    g({ "commit", "-q", "-m", "base" })

    -- Two branches change the same line differently ...
    g({ "checkout", "-q", "-b", "y" })
    write_bytes(path, "line one\nY two\nline three\nline four\nline five\n")
    g({ "commit", "-q", "-am", "y" })
    g({ "checkout", "-q", "main" })
    g({ "checkout", "-q", "-b", "x" })
    write_bytes(path, "line one\nX two\nline three\nline four\nline five\n")
    g({ "commit", "-q", "-am", "x" })

    -- ... and are merged into each other, each resolved differently: a
    -- criss-cross history (two merge bases), whose virtual ancestor conflicts.
    g({ "checkout", "-q", "-b", "m1", "x" })
    g({ "merge", "-q", "y" }, true)
    write_bytes(path, "line one\nXY two\nline three\nline four\nline five\n")
    g({ "commit", "-q", "-am", "m1 (x then y)" })
    g({ "checkout", "-q", "-b", "m2", "y" })
    g({ "merge", "-q", "x" }, true)
    write_bytes(path, "line one\nYX two\nline three\nline four\nline five\n")
    g({ "commit", "-q", "-am", "m2 (y then x)" })

    g({ "checkout", "-q", "m1" })
    write_bytes(path, "line one\nM1 two\nline three\nline four\nline five\n")
    g({ "commit", "-q", "-am", "m1 edit" })
    g({ "checkout", "-q", "m2" })
    write_bytes(path, "line one\nM2 two\nline three\nline four\nline five\n")
    g({ "commit", "-q", "-am", "m2 edit" })

    local _, code = g({ "-c", "merge.conflictStyle=diff3", "merge", "m1" }, true)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(code ~= 0, "fixture: the criss-cross merge must conflict")
    local conflicted = read_bytes(path)
    local markers = count_markers(conflicted)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(
      markers >= 2,
      "fixture: git must nest the virtual ancestor's conflict inside the base section"
    )

    local bufnr = open(path)
    local regions = conflict.scan(bufnr)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(1, #regions, "the nested markers belong to the outer conflict's base")
    ---@diagnostic disable-next-line: undefined-field
    assert.is_falsy(regions[1].ambiguous)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("diff3", regions[1].style)

    -- git wrote the inner conflict with LONGER markers; they are base text.
    local base =
      vim.api.nvim_buf_get_lines(bufnr, regions[1].base_first, regions[1].base_last + 1, false)
    local inner_start = false
    for _, line in ipairs(base) do
      if line:match("^<<<<<<<<<") then inner_start = true end
    end
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(inner_start, "the nested conflict's markers are inside the base section")

    for _, side in ipairs({ "ours", "theirs" }) do
      write_bytes(path, conflicted)
      local buf = open(path)
      resolve_all(buf, side)
      vim.cmd("silent write")
      local mine = read_bytes(path)
      write_bytes(path, conflicted)
      g({ "checkout", "--" .. side, "--", FILE })
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(read_bytes(path), mine, ("choose('%s') matches `git checkout`"):format(side))
    end
  end)
end)
