-- TESTS/gitsuite/conflict_parser_spec.lua -- pure conflict-marker parsing.
-- The one module in gitsuite.nvim with real correctness risk: exact
-- row-offset assertions throughout, not just "found N regions".
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
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(1, #regions)
    local r = regions[1]
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("merge", r.style)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(1, r.start_line)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("HEAD", r.ours_label)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(2, r.ours_first)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(3, r.ours_last)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_nil(r.base_first)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(4, r.sep_line)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(5, r.theirs_first)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(5, r.theirs_last)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("feature-branch", r.theirs_label)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(6, r.end_line)

    -- Cross-check every row against the actual source lines.
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("<<<<<<< HEAD", lines[r.start_line + 1])
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("our line 1", lines[r.ours_first + 1])
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("our line 2", lines[r.ours_last + 1])
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("=======", lines[r.sep_line + 1])
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("their line 1", lines[r.theirs_first + 1])
    ---@diagnostic disable-next-line: undefined-field
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
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(1, #regions)
    local r = regions[1]
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("diff3", r.style)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(1, r.ours_first)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(1, r.ours_last)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(3, r.base_first)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(4, r.base_last)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(5, r.sep_line)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(6, r.theirs_first)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(6, r.theirs_last)

    ---@diagnostic disable-next-line: undefined-field
    assert.equals("base line 1", lines[r.base_first + 1])
    ---@diagnostic disable-next-line: undefined-field
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
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(1, #regions)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("diff3", regions[1].style)
    ---@diagnostic disable-next-line: undefined-field
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
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(2, #regions)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("a-ours", lines[regions[1].ours_first + 1])
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("b-ours", lines[regions[2].ours_first + 1])
    ---@diagnostic disable-next-line: undefined-field
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
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(r.ours_first > r.ours_last)
  end)

  it("skips an unclosed <<<<<<< (no ======= before EOF), does not raise", function()
    local lines = { "<<<<<<< HEAD", "dangling", "no closing markers here" }
    local ok, regions = pcall(parser.parse, lines)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
    ---@diagnostic disable-next-line: undefined-field
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
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(1, #regions, "only the well-formed conflict is reported")
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("real ours", lines[regions[1].ours_first + 1])
  end)

  it("returns an empty list for a buffer with no conflict markers", function()
    local regions = parser.parse({ "just", "some", "ordinary", "lines" })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(0, #regions)
  end)

  it("returns an empty list for an empty buffer", function()
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(0, #parser.parse({}))
  end)
end)
