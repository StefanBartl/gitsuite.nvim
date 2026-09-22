-- TESTS/gitsuite/statusline_spec.lua -- gitsuite.statusline against real
-- scratch buffers with synthetic conflict markers, same fixture style as
-- conflict_spec.lua. No git state needed -- this operates purely on buffer
-- text plus nvim_buf_get_changedtick.
describe("gitsuite.statusline", function()
  local statusline
  local bufnr

  local function set_lines(lines)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end

  before_each(function()
    package.loaded["gitsuite.statusline"] = nil
    package.loaded["gitsuite.features.conflict"] = nil
    statusline = require("gitsuite.statusline")
    require("gitsuite.config").setup({})
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("is empty for a buffer with no conflicts", function()
    set_lines({ "just", "ordinary", "lines" })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("", statusline.status(bufnr))
  end)

  it("reports the region count once markers are added", function()
    set_lines({
      "<<<<<<< HEAD",
      "ours",
      "=======",
      "theirs",
      ">>>>>>> branch",
    })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("MERGE 1", statusline.status(bufnr))
  end)

  it("counts more than one region", function()
    set_lines({
      "<<<<<<< HEAD",
      "ours",
      "=======",
      "theirs",
      ">>>>>>> branch",
      "unrelated",
      "<<<<<<< HEAD",
      "ours2",
      "=======",
      "theirs2",
      ">>>>>>> branch",
    })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("MERGE 2", statusline.status(bufnr))
  end)

  it("is cached: a stale-but-still-current changedtick does not re-scan", function()
    set_lines({
      "<<<<<<< HEAD",
      "ours",
      "=======",
      "theirs",
      ">>>>>>> branch",
    })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("MERGE 1", statusline.status(bufnr))

    -- Resolve the conflict directly (bypassing conflict.choose(), which
    -- would itself bump changedtick) to prove the cached text -- not a
    -- fresh scan -- is what a same-changedtick call returns.
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("MERGE 1", statusline.status(bufnr))
  end)

  it("invalidates once the buffer's changedtick moves (an edit happened)", function()
    set_lines({
      "<<<<<<< HEAD",
      "ours",
      "=======",
      "theirs",
      ">>>>>>> branch",
    })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("MERGE 1", statusline.status(bufnr))

    set_lines({ "resolved" })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("", statusline.status(bufnr))
  end)

  it("resolving one of two conflicts (no GitsuiteConflictsResolved fired) still updates", function()
    -- The gap the card's original "GS-06 events + BufWritePost" sketch
    -- would have had: gitsuite.events.conflicts_resolved only fires once
    -- the *last* region in a buffer is resolved, not for every choose()
    -- call -- so an event-only cache would still say "MERGE 2" here.
    local conflict = require("gitsuite.features.conflict")
    set_lines({
      "<<<<<<< HEAD",
      "ours",
      "=======",
      "theirs",
      ">>>>>>> branch",
      "unrelated",
      "<<<<<<< HEAD",
      "ours2",
      "=======",
      "theirs2",
      ">>>>>>> branch",
    })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("MERGE 2", statusline.status(bufnr))

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    conflict.choose("ours")

    ---@diagnostic disable-next-line: undefined-field
    assert.equals("MERGE 1", statusline.status(bufnr))
  end)

  it("is empty when features.conflict is off", function()
    require("gitsuite.config").setup({ features = { conflict = false } })
    set_lines({
      "<<<<<<< HEAD",
      "ours",
      "=======",
      "theirs",
      ">>>>>>> branch",
    })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("", statusline.status(bufnr))
  end)

  it("is empty for an invalid buffer number, does not error", function()
    local ok, result = pcall(statusline.status, 999999)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("", result)
  end)

  it("lualine_component is status under another name", function()
    ---@diagnostic disable-next-line: undefined-field
    assert.equals(statusline.status, statusline.lualine_component)
  end)
end)
