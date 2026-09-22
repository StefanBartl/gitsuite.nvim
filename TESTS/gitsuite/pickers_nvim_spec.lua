-- TESTS/gitsuite/pickers_nvim_spec.lua -- gitsuite.integrations.pickers_nvim.
--
-- pickers.nvim is not a sibling checkout in this test environment (like
-- open.nvim in browse_spec.lua), so every engine-specific override is
-- exercised against fake "pickers.engines"/"pickers.builtins"/telescope
-- modules injected via package.loaded, not the real plugin. What's under
-- test either way: does the opts table this module hands to
-- `pickers.builtins.run()` actually reroute a confirmed selection through
-- `on_confirm` instead of the engine's own checkout action.
local STUBBED = {
  "pickers.engines",
  "pickers.builtins",
  "telescope.actions",
  "telescope.actions.state",
}

describe("gitsuite.integrations.pickers_nvim", function()
  local pickers_nvim
  local saved

  before_each(function()
    saved = {}
    for _, name in ipairs(STUBBED) do
      saved[name] = package.loaded[name]
      package.loaded[name] = nil
    end
    package.loaded["gitsuite.integrations.pickers_nvim"] = nil
    pickers_nvim = require("gitsuite.integrations.pickers_nvim")
  end)

  after_each(function()
    for _, name in ipairs(STUBBED) do
      package.loaded[name] = saved[name]
    end
  end)

  it("available() is false when pickers.nvim is not installed", function()
    ---@diagnostic disable-next-line: undefined-field
    assert.is_false(pickers_nvim.available())
  end)

  it("available() is true once both pickers.nvim modules load", function()
    package.loaded["pickers.engines"] = {}
    package.loaded["pickers.builtins"] = {}
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(pickers_nvim.available())
  end)

  it("branch_picker() returns false when no engine resolves", function()
    package.loaded["pickers.engines"] = {
      load = function()
        return nil, nil
      end,
    }
    package.loaded["pickers.builtins"] = {
      run = function()
        error("must not run")
      end,
    }
    ---@diagnostic disable-next-line: undefined-field
    assert.is_false(pickers_nvim.branch_picker(function() end))
  end)

  it("branch_picker() returns false for an engine it has no override for", function()
    package.loaded["pickers.engines"] = {
      load = function()
        return {}, "mystery-engine"
      end,
    }
    package.loaded["pickers.builtins"] = {
      run = function()
        error("must not run")
      end,
    }
    ---@diagnostic disable-next-line: undefined-field
    assert.is_false(pickers_nvim.branch_picker(function() end))
  end)

  it("snacks: routes a confirmed item through on_confirm and closes the picker", function()
    package.loaded["pickers.engines"] = {
      load = function()
        return {}, "snacks"
      end,
    }
    local captured
    package.loaded["pickers.builtins"] = {
      run = function(name, opts, engine_name)
        captured = { name = name, opts = opts, engine_name = engine_name }
      end,
    }

    local chosen
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(pickers_nvim.branch_picker(function(branch)
      chosen = branch
    end))
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("git_branches", captured.name)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("snacks", captured.engine_name)

    local closed = false
    local fake_picker = {
      close = function()
        closed = true
      end,
    }
    captured.opts.confirm(fake_picker, { branch = "feature/x" })
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(closed)
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("feature/x", chosen)
  end)

  it("snacks: falls back to item.commit when there is no branch (detached HEAD entry)", function()
    package.loaded["pickers.engines"] = {
      load = function()
        return {}, "snacks"
      end,
    }
    local captured
    package.loaded["pickers.builtins"] = {
      run = function(_, opts)
        captured = opts
      end,
    }
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(pickers_nvim.branch_picker(function() end))

    local chosen
    package.loaded["pickers.builtins"].run = function(_, opts)
      captured = opts
    end
    pickers_nvim.branch_picker(function(branch)
      chosen = branch
    end)
    captured.confirm({ close = function() end }, { commit = "abc1234" })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("abc1234", chosen)
  end)

  it(
    "telescope: replaces select_default so on_confirm runs instead of the engine's checkout",
    function()
      package.loaded["pickers.engines"] = {
        load = function()
          return {}, "telescope"
        end,
      }
      local captured
      package.loaded["pickers.builtins"] = {
        run = function(_, opts)
          captured = opts
        end,
      }

      local replaced
      package.loaded["telescope.actions"] = {
        select_default = {
          replace = function(_self, fn)
            replaced = fn
          end,
        },
        close = function() end,
      }
      local selected_value = "feature/y"
      package.loaded["telescope.actions.state"] = {
        get_selected_entry = function()
          return { value = selected_value }
        end,
      }

      local chosen
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(pickers_nvim.branch_picker(function(branch)
        chosen = branch
      end))

      local map_calls = 0
      local ok = captured.attach_mappings(0, function()
        map_calls = map_calls + 1
      end)
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok)
      ---@diagnostic disable-next-line: undefined-field
      assert.is_function(replaced)

      replaced() -- simulate <CR> after select_default was replaced
      ---@diagnostic disable-next-line: undefined-field
      assert.equals("feature/y", chosen)
    end
  )

  it("fzf: parses the branch name out of a `git branch -vv` result line", function()
    package.loaded["pickers.engines"] = {
      load = function()
        return {}, "fzf"
      end,
    }
    local captured
    package.loaded["pickers.builtins"] = {
      run = function(_, opts)
        captured = opts
      end,
    }

    local chosen
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(pickers_nvim.branch_picker(function(branch)
      chosen = branch
    end))

    captured.actions["enter"]({ "* main                d2b2b7b some message" })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("main", chosen)

    captured.actions["enter"]({ "  feature/z            aaaa111 other message" })
    ---@diagnostic disable-next-line: undefined-field
    assert.equals("feature/z", chosen)
  end)
end)
