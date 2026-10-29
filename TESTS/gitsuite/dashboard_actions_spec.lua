-- TESTS/gitsuite/dashboard_actions_spec.lua -- what fetch/pull/update of the dashboard
-- (gitsuite.features.dashboard.actions) hand the batch summary, from the `changed` flag
-- lib.nvim.git reports: false is unchanged, true or unknown (nil) is the action's label.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.

describe("gitsuite.features.dashboard.actions fetch/pull/update summary detail", function()
  local git = require("lib.nvim.git")
  local actions = require("gitsuite.features.dashboard.actions")

  local CASES = {
    { action = "fetch", lib = "fetch_async", label = "fetched new refs" },
    { action = "pull", lib = "pull_async", label = "pulled new commits" },
    { action = "update", lib = "update_async", label = "fast-forwarded" },
  }

  ---@type table<string, function>
  local saved = {}

  before_each(function()
    for _, c in ipairs(CASES) do
      saved[c.lib] = git[c.lib]
    end
  end)

  after_each(function()
    for name, fn in pairs(saved) do
      git[name] = fn
    end
  end)

  ---Runs `actions[name]` with lib.nvim's function answering `(ok, err, changed)`.
  ---@param c table
  ---@param ok boolean
  ---@param err string|nil
  ---@param changed boolean|nil
  ---@return table answer `{ ok, err, detail, skipped }`
  local function run(c, ok, err, changed)
    git[c.lib] = function(opts, on_done)
      assert.equals("/repo", opts.dir)
      on_done(ok, err, changed)
    end
    local answer
    actions[c.action]("/repo", function(...)
      answer = { ... }
    end)
    assert.is_not_nil(answer, c.action .. " answered synchronously with the stub")
    return answer
  end

  for _, c in ipairs(CASES) do
    it(c.action .. ": changed == false is unchanged (no detail)", function()
      local a = run(c, true, nil, false)
      assert.is_true(a[1])
      assert.is_nil(a[3])
      assert.is_nil(a[4])
    end)

    it(c.action .. ": changed == true and unknown both report the label", function()
      assert.equals(c.label, run(c, true, nil, true)[3])
      assert.equals(c.label, run(c, true, nil, nil)[3])
    end)

    it(c.action .. ": a failure passes the reason on, without a detail", function()
      local a = run(c, false, "boom", nil)
      assert.is_false(a[1])
      assert.equals("boom", a[2])
      assert.is_nil(a[3])
    end)
  end
end)
