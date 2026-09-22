-- TESTS/gitsuite/menu_spec.lua -- gitsuite.integrations.menu. gitsigns.nvim
-- is not a sibling checkout in this test environment (like hunk_spec.lua),
-- so `adapter.resolve("gitsigns")` correctly reports "not installed" without
-- faking anything for the "no gitsigns" cases; a faked `gitsigns` module
-- covers the "installed" ones.
describe("gitsuite.integrations.menu", function()
  local menu
  local real_gitsigns

  before_each(function()
    package.loaded["gitsuite.integrations.menu"] = nil
    package.loaded["gitsuite.adapter"] = nil
    real_gitsigns = package.loaded["gitsigns"]
    package.loaded["gitsigns"] = nil
    menu = require("gitsuite.integrations.menu")
    require("gitsuite.config").setup({ commands = { git = "Git" } })
    require("gitsuite.bindings.usrcmds").register(require("gitsuite.config").get())
  end)

  after_each(function()
    package.loaded["gitsigns"] = real_gitsigns
  end)

  ---@param items Lib.ContextMenu.Item[]
  ---@param name string
  ---@return Lib.ContextMenu.Item|nil
  local function find(items, name)
    for _, item in ipairs(items) do
      if item.name == name then return item end
    end
    return nil
  end

  it("without gitsigns: only Blame and Diff entries are offered", function()
    local items = menu.items()

    ---@diagnostic disable-next-line: undefined-field
    assert.is_nil(find(items, "Stage Hunk"))
    ---@diagnostic disable-next-line: undefined-field
    assert.is_nil(find(items, "Reset Hunk"))
    ---@diagnostic disable-next-line: undefined-field
    assert.is_nil(find(items, "Stage Buffer"))
    ---@diagnostic disable-next-line: undefined-field
    assert.is_nil(find(items, "Reset Buffer"))
    ---@diagnostic disable-next-line: undefined-field
    assert.is_nil(find(items, "Toggle Deleted"))

    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(find(items, "Preview Hunk"))
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(find(items, "Blame Line"))
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(find(items, "Toggle Current Line Blame"))
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(find(items, "Diff Against HEAD"))
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(find(items, "Diff Last Commit"))
  end)

  it("with a faked gitsigns.nvim: every entry is offered", function()
    package.loaded["gitsigns"] = {}
    local items = menu.items()

    local expected = {
      "Stage Hunk",
      "Reset Hunk",
      "Stage Buffer",
      "Reset Buffer",
      "Preview Hunk",
      "Blame Line",
      "Toggle Current Line Blame",
      "Diff Against HEAD",
      "Diff Last Commit",
      "Toggle Deleted",
    }
    for _, name in ipairs(expected) do
      ---@diagnostic disable-next-line: undefined-field
      assert.is_not_nil(find(items, name), name .. " missing")
    end
  end)

  it("an entry's cmd dispatches the matching :Git route, honouring a renamed command", function()
    require("gitsuite.config").setup({ commands = { git = "MyGit" } })
    require("gitsuite.bindings.usrcmds").register(require("gitsuite.config").get())

    local calls = {}
    package.loaded["gitsigns"] = {
      blame_line = function() end,
    }
    local original_cmd = vim.cmd
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.cmd = setmetatable({}, {
      __call = function(_, c)
        calls[#calls + 1] = c
      end,
    })

    local items = menu.items()
    local blame_line = find(items, "Blame Line")
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(blame_line)
    blame_line.cmd()

    vim.cmd = original_cmd

    ---@diagnostic disable-next-line: undefined-field
    assert.same({ "MyGit blame line" }, calls)
  end)

  it("routes to blame.line() through the real :Git dispatch", function()
    local git = require("lib.nvim.git")
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/README.md"))
    local bufnr = vim.api.nvim_get_current_buf()

    local items = menu.items()
    local blame_line = find(items, "Blame Line")
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(blame_line)

    local ok = pcall(blame_line.cmd)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(git.repo_root())
  end)

  it("submenu() wraps items() as one 'Git' fly-out entry", function()
    local sub = menu.submenu()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_not_nil(sub)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("Git", sub.name)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(#sub.items > 0)
  end)
end)
