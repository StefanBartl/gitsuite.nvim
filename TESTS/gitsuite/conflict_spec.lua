-- TESTS/gitsuite/conflict_spec.lua -- gitsuite.features.conflict (the
-- impure shell: scan/highlight/choose/navigate) against real scratch
-- buffers with synthetic conflict markers. No git state needed -- this
-- operates purely on buffer text.
describe("gitsuite.features.conflict", function()
  local conflict
  local bufnr

  local function set_lines(lines)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end

  local function get_lines()
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  before_each(function()
    package.loaded["gitsuite.features.conflict"] = nil
    conflict = require("gitsuite.features.conflict")
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("has_conflicts() is false for an ordinary buffer, true once markers are added", function()
    set_lines({ "just", "ordinary", "lines" })
    ---@diagnostic disable-next-line: undefined-field
    assert.is_false(conflict.has_conflicts(bufnr))

    set_lines({ "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch" })
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(conflict.has_conflicts(bufnr))
  end)

  it("refresh() places one extmark per marker/content section", function()
    set_lines({ "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch" })
    conflict.refresh(bufnr)
    local ns = vim.api.nvim_create_namespace("gitsuite_conflict")
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
    -- start marker, ours, sep marker, theirs, end marker = 5
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(5, #marks)
  end)

  it("choose('ours') keeps only the ours side and removes every marker", function()
    set_lines({
      "before",
      "<<<<<<< HEAD",
      "our line",
      "=======",
      "their line",
      ">>>>>>> branch",
      "after",
    })
    vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- cursor inside the conflict
    conflict.choose("ours")
    ---@diagnostic disable-next-line: undefined-field
    assert.same({ "before", "our line", "after" }, get_lines())
  end)

  it("choose('theirs') keeps only the theirs side", function()
    set_lines({ "<<<<<<< HEAD", "our line", "=======", "their line", ">>>>>>> branch" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    conflict.choose("theirs")
    ---@diagnostic disable-next-line: undefined-field
    assert.same({ "their line" }, get_lines())
  end)

  it("choose('both') keeps ours then theirs, in order", function()
    set_lines({ "<<<<<<< HEAD", "our line", "=======", "their line", ">>>>>>> branch" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    conflict.choose("both")
    ---@diagnostic disable-next-line: undefined-field
    assert.same({ "our line", "their line" }, get_lines())
  end)

  it("choose('none') removes the whole region, keeping the buffer's other lines", function()
    set_lines({
      "before",
      "<<<<<<< HEAD",
      "our line",
      "=======",
      "their line",
      ">>>>>>> branch",
      "after",
    })
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    conflict.choose("none")
    ---@diagnostic disable-next-line: undefined-field
    assert.same({ "before", "after" }, get_lines())
  end)

  it("choose('base') keeps the common-ancestor section on a diff3-style conflict", function()
    set_lines({
      "<<<<<<< HEAD",
      "our line",
      "||||||| base",
      "base line",
      "=======",
      "their line",
      ">>>>>>> branch",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    conflict.choose("base")
    ---@diagnostic disable-next-line: undefined-field
    assert.same({ "base line" }, get_lines())
  end)

  it(
    "choose('base') on a merge-style conflict (no base section) errors, changes nothing",
    function()
      local original = { "<<<<<<< HEAD", "our line", "=======", "their line", ">>>>>>> branch" }
      set_lines(original)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local ok = pcall(conflict.choose, "base")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok, "must not raise, just report an error")
      ---@diagnostic disable-next-line: undefined-field
      assert.same(
        original,
        get_lines(),
        "buffer is untouched when the requested side does not exist"
      )
    end
  )

  it("choose() with the cursor outside any conflict reports an error, changes nothing", function()
    local original = { "just", "ordinary", "lines" }
    set_lines(original)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local ok = pcall(conflict.choose, "ours")
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
    ---@diagnostic disable-next-line: undefined-field
    assert.same(original, get_lines())
  end)

  it("choose() only resolves the conflict under the cursor, a second one is untouched", function()
    set_lines({
      "<<<<<<< HEAD", -- 1
      "a-ours", -- 2
      "=======", -- 3
      "a-theirs", -- 4
      ">>>>>>> branch", -- 5
      "between", -- 6
      "<<<<<<< HEAD", -- 7
      "b-ours", -- 8
      "=======", -- 9
      "b-theirs", -- 10
      ">>>>>>> branch", -- 11
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- inside the FIRST conflict
    conflict.choose("ours")
    local lines = get_lines()
    ---@diagnostic disable-next-line: undefined-field
    assert.same(
      { "a-ours", "between", "<<<<<<< HEAD", "b-ours", "=======", "b-theirs", ">>>>>>> branch" },
      lines
    )
  end)

  it("next()/prev() move the cursor to the next/previous conflict's start line", function()
    set_lines({
      "before", -- row 1
      "<<<<<<< HEAD", -- row 2 = conflict A start
      "a",
      "=======",
      "a2",
      ">>>>>>> b",
      "between", -- row 7
      "<<<<<<< HEAD", -- row 8 = conflict B start
      "b",
      "=======",
      "b2",
      ">>>>>>> b", -- row 12
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    conflict.next()
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])

    conflict.next()
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(8, vim.api.nvim_win_get_cursor(0)[1])

    -- No third conflict: cursor stays put, does not raise.
    local ok = pcall(conflict.next)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(8, vim.api.nvim_win_get_cursor(0)[1])

    conflict.prev()
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)
