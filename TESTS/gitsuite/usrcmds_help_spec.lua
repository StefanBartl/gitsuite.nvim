-- TESTS/gitsuite/usrcmds_help_spec.lua -- every flag of `:Git` has a line in lib.nvim's option
-- float.
--
-- The text comes from the `desc` of each FlagSpec in gitsuite.bindings.usrcmds (`dashboard --out`
-- and `--to`). A new flag without one shows up as a bare row in the cheatsheet, so this fails until
-- it is described.
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
describe("gitsuite.bindings.usrcmds option float", function()
  it("describes every flag and key=value pair of :Git", function()
    local composer = require("lib.nvim.bindings.usercmd.composer")

    -- A lib.nvim older than `help.undocumented` cannot answer the question; that is a missing
    -- feature of the dependency, not a defect of this plugin.
    if type(composer.help.undocumented) ~= "function" then return end

    require("gitsuite.config").setup({ commands = { git = "Git" } })
    require("gitsuite.bindings.usrcmds").register(require("gitsuite.config").get())
    assert.is_not_nil(composer.registry().Git, ":Git is registered through the composer")

    local missing = {}
    for _, m in ipairs(composer.help.undocumented("Git")) do
      missing[#missing + 1] = ("%s %s"):format(m.route, m.name)
    end
    pcall(vim.api.nvim_del_user_command, "Git")
    assert.equals(0, #missing, ":Git options without a help text: " .. table.concat(missing, ", "))
  end)
end)
