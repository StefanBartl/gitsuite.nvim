-- TESTS/gitsuite/usrcmds_help_spec.lua -- every flag and every positional argument of `:Git` has a
-- line in lib.nvim's option float.
--
-- The flag text comes from the `desc` of each FlagSpec in gitsuite.bindings.usrcmds (`dashboard
-- --out` and `--to`), the argument text from the `desc` of the ArgSpec (`diff rev`, `dashboard
-- [dir]`) or of its type (`GITSUITE_DASHBOARD_DIR`). A new flag or argument without one shows up as
-- a bare row in the cheatsheet, so this fails until it is described.
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

    -- The positional arguments too (`diff rev`, `dashboard [dir]`, `dashboard update [dir]`): a
    -- text of their own or of their type (`GITSUITE_DASHBOARD_DIR`); `DIR` explains itself.
    local missing_args = {}
    for _, m in ipairs(composer.help.undocumented("Git", { args = true })) do
      missing_args[#missing_args + 1] = ("%s %s"):format(m.route, m.name)
    end

    -- House style of the argument texts: one line, no trailing period, at most 80 characters.
    local texts = {}
    for _, route in ipairs(composer.registry().Git:spec().routes) do
      for _, arg in ipairs(route.args or {}) do
        if arg.desc then texts[#texts + 1] = arg.desc end
      end
    end
    local def = require("lib.nvim.bindings.usercmd.composer.argtypes").get("GITSUITE_DASHBOARD_DIR")
    assert.is_not_nil(def, "GITSUITE_DASHBOARD_DIR is a registered argument type")
    assert.is_truthy(def.desc and def.desc ~= "", "GITSUITE_DASHBOARD_DIR has a help text")
    texts[#texts + 1] = def.desc
    local malformed = {}
    for _, text in ipairs(texts) do
      if text:find("\n", 1, true) or text:sub(-1) == "." or #text > 80 then
        malformed[#malformed + 1] = text
      end
    end

    pcall(vim.api.nvim_del_user_command, "Git")
    assert.equals(0, #missing, ":Git options without a help text: " .. table.concat(missing, ", "))
    assert.equals(
      0,
      #missing_args,
      ":Git arguments without a help text: " .. table.concat(missing_args, ", ")
    )
    assert.is_true(#texts >= 3, "the argument texts were found (rev, dashboard dir, the type)")
    assert.equals(
      0,
      #malformed,
      "argument texts must be one line, without a trailing period, <= 80 characters: "
        .. table.concat(malformed, " | ")
    )
  end)
end)
