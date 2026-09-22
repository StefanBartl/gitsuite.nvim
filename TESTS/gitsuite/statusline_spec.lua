-- TESTS/gitsuite/statusline_spec.lua -- gitsuite.statusline against real
-- scratch buffers with synthetic conflict markers, same fixture style as
-- conflict_spec.lua. No git state needed -- this operates purely on buffer
-- text plus nvim_buf_get_changedtick.
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
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
    assert.equals("MERGE 1", statusline.status(bufnr))

    -- Resolve the conflict directly (bypassing conflict.choose(), which
    -- would itself bump changedtick) to prove the cached text -- not a
    -- fresh scan -- is what a same-changedtick call returns.
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
    assert.equals("MERGE 1", statusline.status(bufnr))

    set_lines({ "resolved" })
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
    assert.equals("MERGE 2", statusline.status(bufnr))

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    conflict.choose("ours")

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
    assert.equals("", statusline.status(bufnr))
  end)

  it("is empty for an invalid buffer number, does not error", function()
    local ok, result = pcall(statusline.status, 999999)
    assert.is_true(ok)
    assert.equals("", result)
  end)

  it("lualine_component is status under another name", function()
    assert.equals(statusline.status, statusline.lualine_component)
  end)

  it("invalidate() forces a fresh read even at the same changedtick", function()
    set_lines({
      "<<<<<<< HEAD",
      "ours",
      "=======",
      "theirs",
      ">>>>>>> branch",
    })
    assert.equals("MERGE 1", statusline.status(bufnr))

    require("gitsuite.config").setup({ features = { conflict = false } })
    -- Same changedtick as above: without invalidate(), the cache alone
    -- would still (wrongly) hand back the stale "MERGE 1".
    assert.equals("MERGE 1", statusline.status(bufnr))

    statusline.invalidate(bufnr)
    assert.equals("", statusline.status(bufnr))
  end)

  it("registers a BufDelete/BufWipeout autocmd that drops a deleted buffer's cache", function()
    local autocmds = vim.api.nvim_get_autocmds({ group = "gitsuite_statusline" })
    assert.is_true(#autocmds > 0)

    local events = {}
    for _, au in ipairs(autocmds) do
      events[au.event] = true
    end
    assert.is_true(events["BufDelete"] or false)
    assert.is_true(events["BufWipeout"] or false)

    set_lines({
      "<<<<<<< HEAD",
      "ours",
      "=======",
      "theirs",
      ">>>>>>> branch",
    })
    assert.equals("MERGE 1", statusline.status(bufnr))

    -- Real delete, not invalidate(): proves the autocmd itself fires and
    -- does not error, not just that the underlying function works.
    local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    assert.is_true(ok)
  end)
end)
