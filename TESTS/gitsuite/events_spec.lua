-- TESTS/gitsuite/events_spec.lua -- gitsuite.events, the `User` autocmds
-- gitsuite fires for post-action consumers (D-2). Each case subscribes with
-- a real `autocmd User Gitsuite*` (the same mechanism a consumer plugin
-- would use) and checks both that the event fires and what `event.data`
-- carries -- not just that the call doesn't error.
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
describe("gitsuite.events", function()
  local events
  local group

  before_each(function()
    package.loaded["gitsuite.events"] = nil
    events = require("gitsuite.events")
    group = vim.api.nvim_create_augroup("gitsuite_events_spec", { clear = true })
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end)

  it("branch_switched() fires GitsuiteBranchSwitched with {dir, branch}", function()
    local captured
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "GitsuiteBranchSwitched",
      callback = function(event)
        captured = event.data
      end,
    })

    events.branch_switched("/repo/root", "feature/x")

    assert.is_not_nil(captured)
    assert.equals("/repo/root", captured.dir)
    assert.equals("feature/x", captured.branch)
  end)

  it("conflicts_resolved() fires GitsuiteConflictsResolved with {bufnr}", function()
    local captured
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "GitsuiteConflictsResolved",
      callback = function(event)
        captured = event.data
      end,
    })

    events.conflicts_resolved(42)

    assert.is_not_nil(captured)
    assert.equals(42, captured.bufnr)
  end)

  it("status_changed() fires GitsuiteStatusChanged with {dir}", function()
    local captured
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "GitsuiteStatusChanged",
      callback = function(event)
        captured = event.data
      end,
    })

    events.status_changed("/repo/root")

    assert.is_not_nil(captured)
    assert.equals("/repo/root", captured.dir)
  end)

  it("plugins_reported() fires GitsuitePluginsReported with the report's numbers", function()
    local captured
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "GitsuitePluginsReported",
      callback = function(event)
        captured = event.data
      end,
    })

    events.plugins_reported({
      id = "20261008T120000Z-0001",
      mode = "updated",
      at = 1790000000,
      plugins = 8,
      commits = 120,
      errors = 1,
      saved = true,
    })

    assert.is_not_nil(captured)
    assert.equals("20261008T120000Z-0001", captured.id)
    assert.equals("updated", captured.mode)
    assert.equals(8, captured.plugins)
    assert.equals(120, captured.commits)
    assert.equals(1, captured.errors)
    assert.is_true(captured.saved)
  end)

  it("events do not cross-fire each other's patterns", function()
    local branch_fired, status_fired = false, false
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "GitsuiteBranchSwitched",
      callback = function()
        branch_fired = true
      end,
    })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "GitsuiteStatusChanged",
      callback = function()
        status_fired = true
      end,
    })

    events.conflicts_resolved(1)

    assert.is_false(branch_fired)
    assert.is_false(status_fired)
  end)
end)
