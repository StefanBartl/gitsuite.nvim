-- TESTS/gitsuite/editor_scope_spec.lua -- the test helper TESTS/gitsuite/editor_scope.lua itself:
-- `install({ manual = true })` leaves the restore to the describe's own after_each, and restore()
-- survives a tab page that an earlier close took with it.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local editor_scope = dofile(dir_of_spec .. "editor_scope.lua")

describe("editor_scope install({ manual = true })", function()
  editor_scope.install({ manual = true })

  local tabs_before

  before_each(function()
    tabs_before = #vim.api.nvim_list_tabpages()
  end)

  after_each(function()
    -- The helper registered its hooks first; in manual mode it must not have restored yet.
    local still_open = #vim.api.nvim_list_tabpages()
    editor_scope.restore()
    assert.are.equal(
      tabs_before + 1,
      still_open,
      "the test's tab is still open in the own after_each"
    )
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages(), "restore() closed it")
  end)

  it("keeps the test's layout until the describe's own after_each", function()
    vim.cmd("tabnew")
    assert.are.equal(tabs_before + 1, #vim.api.nvim_list_tabpages())
  end)
end)

describe("editor_scope restore()", function()
  editor_scope.install()

  local group = vim.api.nvim_create_augroup("editor_scope_spec", { clear = true })

  after_each(function()
    vim.api.nvim_clear_autocmds({ group = group })
  end)

  it("skips a tab page that closing an earlier one already took", function()
    local tabs_before = #vim.api.nvim_list_tabpages()
    vim.cmd("tabnew")
    vim.cmd("tabnew")
    local second = vim.api.nvim_get_current_tabpage()
    local second_win = vim.api.nvim_get_current_win()
    -- A third one keeps more than one tab page open when the loop reaches the closed second.
    vim.cmd("tabnew")
    vim.api.nvim_create_autocmd("TabClosed", {
      group = group,
      once = true,
      callback = function()
        if vim.api.nvim_tabpage_is_valid(second) then vim.api.nvim_win_close(second_win, true) end
      end,
    })
    assert.has_no.errors(editor_scope.restore)
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
  end)
end)
