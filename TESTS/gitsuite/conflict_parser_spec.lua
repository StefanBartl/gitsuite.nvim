-- TESTS/gitsuite/conflict_parser_spec.lua -- pure conflict-marker parsing.
-- The one module in gitsuite.nvim with real correctness risk: exact
-- row-offset assertions throughout, not just "found N regions".
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
describe("gitsuite.features.conflict.parser", function()
  local parser = require("gitsuite.features.conflict.parser")

  it("parses a merge-style conflict (no base section)", function()
    local lines = {
      "line before", -- 1 (row 0)
      "<<<<<<< HEAD", -- 2 (row 1)
      "our line 1", -- 3 (row 2)
      "our line 2", -- 4 (row 3)
      "=======", -- 5 (row 4)
      "their line 1", -- 6 (row 5)
      ">>>>>>> feature-branch", -- 7 (row 6)
      "line after", -- 8 (row 7)
    }
    local regions = parser.parse(lines)
    assert.equals(1, #regions)
    local r = regions[1]
    assert.equals("merge", r.style)
    assert.equals(1, r.start_line)
    assert.equals("HEAD", r.ours_label)
    assert.equals(2, r.ours_first)
    assert.equals(3, r.ours_last)
    assert.is_nil(r.base_first)
    assert.equals(4, r.sep_line)
    assert.equals(5, r.theirs_first)
    assert.equals(5, r.theirs_last)
    assert.equals("feature-branch", r.theirs_label)
    assert.equals(6, r.end_line)

    -- Cross-check every row against the actual source lines.
    assert.equals("<<<<<<< HEAD", lines[r.start_line + 1])
    assert.equals("our line 1", lines[r.ours_first + 1])
    assert.equals("our line 2", lines[r.ours_last + 1])
    assert.equals("=======", lines[r.sep_line + 1])
    assert.equals("their line 1", lines[r.theirs_first + 1])
    assert.equals(">>>>>>> feature-branch", lines[r.end_line + 1])
  end)

  it("parses a diff3-style conflict (with a base section)", function()
    local lines = {
      "<<<<<<< HEAD", -- row 0
      "our line", -- row 1
      "||||||| merged common ancestors", -- row 2
      "base line 1", -- row 3
      "base line 2", -- row 4
      "=======", -- row 5
      "their line", -- row 6
      ">>>>>>> feature-branch", -- row 7
    }
    local regions = parser.parse(lines)
    assert.equals(1, #regions)
    local r = regions[1]
    assert.equals("diff3", r.style)
    assert.equals(1, r.ours_first)
    assert.equals(1, r.ours_last)
    assert.equals(3, r.base_first)
    assert.equals(4, r.base_last)
    assert.equals(5, r.sep_line)
    assert.equals(6, r.theirs_first)
    assert.equals(6, r.theirs_last)

    assert.equals("base line 1", lines[r.base_first + 1])
    assert.equals("base line 2", lines[r.base_last + 1])
  end)

  it("parses a zdiff3-style conflict identically to diff3 (same markers)", function()
    -- zdiff3 differs from diff3 only in how much unchanged context git
    -- includes around the base hunk -- the marker grammar is identical, so
    -- this is really the same code path as the diff3 test, kept separate
    -- because the concept doc explicitly calls out testing all three styles.
    local lines = {
      "<<<<<<< ours",
      "changed by us",
      "||||||| base",
      "original",
      "=======",
      "changed by them",
      ">>>>>>> theirs",
    }
    local regions = parser.parse(lines)
    assert.equals(1, #regions)
    assert.equals("diff3", regions[1].style)
    assert.equals("original", lines[regions[1].base_first + 1])
  end)

  it("parses multiple, sequential conflicts in one buffer", function()
    local lines = {
      "before",
      "<<<<<<< HEAD",
      "a-ours",
      "=======",
      "a-theirs",
      ">>>>>>> branch",
      "between",
      "<<<<<<< HEAD",
      "b-ours",
      "=======",
      "b-theirs",
      ">>>>>>> branch",
      "after",
    }
    local regions = parser.parse(lines)
    assert.equals(2, #regions)
    assert.equals("a-ours", lines[regions[1].ours_first + 1])
    assert.equals("b-ours", lines[regions[2].ours_first + 1])
    assert.is_true(
      regions[2].start_line > regions[1].end_line,
      "regions are in buffer order, non-overlapping"
    )
  end)

  it("handles an empty side (ours deleted everything) without a bogus range", function()
    local lines = {
      "<<<<<<< HEAD",
      "=======",
      "their line",
      ">>>>>>> branch",
    }
    local r = parser.parse(lines)[1]
    -- ours_first > ours_last signals "empty", per the module's own contract.
    assert.is_true(r.ours_first > r.ours_last)
  end)

  it("skips an unclosed <<<<<<< (no ======= before EOF), does not raise", function()
    local lines = { "<<<<<<< HEAD", "dangling", "no closing markers here" }
    local ok, regions = pcall(parser.parse, lines)
    assert.is_true(ok)
    assert.equals(0, #regions)
  end)

  it("skips an unclosed <<<<<<< followed by a second, real conflict", function()
    local lines = {
      "<<<<<<< HEAD", -- dangling, no ======= before the next <<<<<<<
      "dangling ours",
      "<<<<<<< HEAD", -- the real one
      "real ours",
      "=======",
      "real theirs",
      ">>>>>>> branch",
    }
    local regions = parser.parse(lines)
    assert.equals(1, #regions, "only the well-formed conflict is reported")
    assert.equals("real ours", lines[regions[1].ours_first + 1])
  end)

  it("returns an empty list for a buffer with no conflict markers", function()
    local regions = parser.parse({ "just", "some", "ordinary", "lines" })
    assert.equals(0, #regions)
  end)

  it("returns an empty list for an empty buffer", function()
    assert.equals(0, #parser.parse({}))
  end)

  -- A line that is exactly `=======` is ordinary content in Markdown (the
  -- underline of a setext heading), so a side of a conflict can legitimately
  -- contain one. The parser must never take such a line for the separator
  -- and silently move text across the boundary -- `choose("ours")` would then
  -- delete lines that belong to our side.
  describe("a `=======` line that is content, not the separator", function()
    ---@param lines string[]
    ---@param first integer 0-indexed, inclusive
    ---@param last integer 0-indexed, inclusive
    ---@return string[]
    local function slice(lines, first, last)
      if last < first then return {} end
      return vim.list_slice(lines, first + 1, last + 1)
    end

    it("outside any conflict never starts a region", function()
      local regions = parser.parse({ "Title", "=======", "text", "=======", "more" })
      assert.equals(0, #regions)
    end)

    it(
      "diff3: one in OUR side is still resolved exactly (the base marker disambiguates)",
      function()
        local lines = {
          "<<<<<<< HEAD",
          "Title",
          "=======", -- content of our side
          "our text",
          "||||||| base",
          "base text",
          "=======", -- the real separator
          "their text",
          ">>>>>>> other",
        }
        local regions = parser.parse(lines)
        assert.equals(1, #regions)
        local r = regions[1]
        assert.is_falsy(r.ambiguous)
        assert.equals("diff3", r.style)
        assert.same({ "Title", "=======", "our text" }, slice(lines, r.ours_first, r.ours_last))
        assert.same({ "base text" }, slice(lines, r.base_first, r.base_last))
        assert.same({ "their text" }, slice(lines, r.theirs_first, r.theirs_last))
        assert.equals(6, r.sep_line)
      end
    )

    it("diff3: one in THEIR side is not mistaken for the separator either", function()
      local lines = {
        "<<<<<<< HEAD",
        "our text",
        "||||||| base",
        "base text",
        "=======", -- the real separator
        "Title",
        "=======", -- content of their side
        "their text",
        ">>>>>>> other",
      }
      local regions = parser.parse(lines)
      assert.equals(1, #regions)
      local r = regions[1]
      assert.is_true(
        r.ambiguous,
        "two candidates after the base marker: which one ends the base section is not decidable"
      )
      -- GS-28: the base marker itself is NOT ambiguous here (exactly one
      -- `|||||||`) -- base_first is set on the ambiguous region too, so a
      -- caller that disambiguates `separators` down to one can reconstruct
      -- a concrete region without re-deriving it.
      assert.equals(3, r.base_first)
      assert.same({ 4, 6 }, r.separators)
    end)

    it("merge style: one in a side makes the separator ambiguous, and says so", function()
      local lines = {
        "<<<<<<< HEAD",
        "Title",
        "=======", -- candidate 1 (row 2)
        "our text",
        "=======", -- candidate 2 (row 4)
        "their text",
        ">>>>>>> other",
      }
      local regions = parser.parse(lines)
      assert.equals(1, #regions, "the conflict is still reported, it is not silently dropped")
      local r = regions[1]
      assert.is_true(r.ambiguous)
      assert.equals(0, r.start_line)
      assert.equals(6, r.end_line)
      assert.same({ 2, 4 }, r.separators)
      -- No section is claimed: a guessed boundary is exactly the bug.
      assert.is_nil(r.ours_first)
      assert.is_nil(r.theirs_first)
      assert.is_nil(r.sep_line)
      assert.is_nil(r.base_first, "merge style: no base marker exists to be unambiguous about")
    end)

    it("merge style: a `|||||||` line in their side is content, not a base marker", function()
      local lines = {
        "<<<<<<< HEAD",
        "our text",
        "=======",
        "|||||||", -- e.g. a table rule; no separator follows it
        "their text",
        ">>>>>>> other",
      }
      local regions = parser.parse(lines)
      assert.equals(1, #regions)
      local r = regions[1]
      assert.is_falsy(r.ambiguous)
      assert.equals("merge", r.style)
      assert.same({ "|||||||", "their text" }, slice(lines, r.theirs_first, r.theirs_last))
    end)
  end)

  -- Git records a conflicting *virtual ancestor* (criss-cross merges) as a
  -- conflict inside the base section of the outer one -- with markers two
  -- characters LONGER, so the two levels can be told apart. This is the shape
  -- a real `git merge` writes (see conflict_git_spec.lua for the real thing).
  describe("a conflict nested in the base section (longer markers)", function()
    local lines = {
      "before", -- 0
      "<<<<<<< HEAD", -- 1
      "ours", -- 2
      "||||||| merged common ancestors", -- 3
      "<<<<<<<<< Temporary merge branch 1", -- 4
      "x", -- 5
      "||||||||| c4aebe5", -- 6
      "base", -- 7
      "=========", -- 8
      "y", -- 9
      ">>>>>>>>> Temporary merge branch 2", -- 10
      "=======", -- 11
      "theirs", -- 12
      ">>>>>>> other", -- 13
      "after", -- 14
    }

    it("is one region: the outer conflict, the inner markers stay inside its base", function()
      local regions = parser.parse(lines)
      assert.equals(1, #regions)
      local r = regions[1]
      assert.equals("diff3", r.style)
      assert.equals(1, r.start_line)
      assert.equals(13, r.end_line)
      assert.equals(11, r.sep_line)
      assert.equals(4, r.base_first)
      assert.equals(10, r.base_last)
      assert.is_falsy(r.ambiguous)
      assert.equals("ours", lines[r.ours_first + 1])
      assert.equals("theirs", lines[r.theirs_first + 1])
    end)

    it("does not swallow a well-formed conflict that follows it", function()
      local more = vim.list_extend(vim.deepcopy(lines), {
        "<<<<<<< HEAD",
        "second ours",
        "=======",
        "second theirs",
        ">>>>>>> other",
      })
      local regions = parser.parse(more)
      assert.equals(2, #regions)
      assert.equals("second ours", more[regions[2].ours_first + 1])
    end)

    it("a second `<<<<<<<` of the SAME size is a malformed region, not a nested one", function()
      local regions = parser.parse({
        "<<<<<<< HEAD",
        "ours",
        "=======",
        "<<<<<<< dangling",
        "theirs",
        ">>>>>>> other",
      })
      assert.equals(0, #regions)
    end)
  end)

  -- `conflict-marker-size` (a git attribute) raises the marker length; it is
  -- git's own remedy for files whose text contains `=======`. Markers of the
  -- wrong length are text, so the ambiguity disappears.
  describe("a conflict with a raised marker size", function()
    local lines = {
      "<<<<<<<<<< HEAD", -- 0 (10 markers)
      "Title",
      "=======", -- text: 7 is not this conflict's marker length
      "our text",
      "==========", -- the separator
      "Their title",
      "=======", -- text
      "their text",
      ">>>>>>>>>> other", -- 8
    }

    it("is not ambiguous: only a run of the same length is a marker", function()
      local regions = parser.parse(lines)
      assert.equals(1, #regions)
      local r = regions[1]
      assert.is_falsy(r.ambiguous)
      assert.equals(4, r.sep_line)
      assert.same({ "Title", "=======", "our text" }, vim.list_slice(lines, 2, 4))
      assert.equals(1, r.ours_first)
      assert.equals(3, r.ours_last)
      assert.equals(5, r.theirs_first)
      assert.equals(7, r.theirs_last)
    end)

    it("a 7-marker conflict inside a longer-marker file is not confused with it", function()
      local regions = parser.parse({
        "<<<<<<< HEAD",
        "ours",
        "=======",
        "theirs",
        ">>>>>>> other",
        "<<<<<<<<<< HEAD",
        "ours",
        "==========",
        "theirs",
        ">>>>>>>>>> other",
      })
      assert.equals(2, #regions)
    end)
  end)

  it("strips the carriage return from the labels of a CRLF file loaded as unix", function()
    local regions = parser.parse({
      "<<<<<<< HEAD\r",
      "our line\r",
      "=======\r",
      "their line\r",
      ">>>>>>> feature\r",
    })
    assert.equals(1, #regions)
    assert.equals("HEAD", regions[1].ours_label)
    assert.equals("feature", regions[1].theirs_label)
  end)
end)
