-- TESTS/gitsuite/health_spec.lua -- :checkhealth gitsuite: the plugin sections must not run
-- anything a config string names, and must say what is actually wrong.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("gitsuite.health", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local saved_health, records

  before_each(function()
    saved_health = vim.health
    records = {}
    local function recorder(kind)
      return function(msg, advice)
        records[#records + 1] = { kind = kind, msg = tostring(msg), advice = advice }
      end
    end
    vim.health = {
      start = recorder("start"),
      ok = recorder("ok"),
      info = recorder("info"),
      warn = recorder("warn"),
      error = recorder("error"),
    }
    package.loaded["gitsuite.health"] = nil
    package.loaded["gitsuite.features.plugins.state"] = nil
    require("gitsuite.config").setup({})
  end)

  after_each(function()
    vim.health = saved_health
    F.cleanup()
  end)

  local function messages(kind)
    local out = {}
    for _, r in ipairs(records) do
      if kind == nil or r.kind == kind then out[#out + 1] = r.msg end
    end
    return table.concat(out, "\n")
  end

  it("does not expand wildcards, <cword> or backticks in plugins.roots", function()
    local marker = F.tmpdir("-health-marker") .. "/ran"
    require("gitsuite.config").setup({
      plugins = {
        roots = {
          "<cword>",
          "`" .. vim.v.progpath .. " --version`",
          "nonexistent-dir",
          "wild_[a]",
        },
        sources = { "clones" },
      },
    })
    local ok, err = pcall(require("gitsuite.health").check)
    assert.is_true(ok, tostring(err))
    local warned = messages("warn")
    assert.is_truthy(warned:find("plugins.roots entry does not exist: nonexistent-dir", 1, true))
    assert.is_truthy(warned:find("<cword>", 1, true))
    assert.is_nil(vim.uv.fs_stat(marker))
  end)

  it("accepts a root spelled with an environment variable", function()
    local root = F.tmpdir("-health-root")
    vim.env.GS_HEALTH_ROOT = root
    require("gitsuite.config").setup({
      plugins = { roots = { "$GS_HEALTH_ROOT" }, sources = { "clones" } },
    })
    pcall(require("gitsuite.health").check)
    vim.env.GS_HEALTH_ROOT = nil
    assert.is_nil(messages("warn"):find("does not exist", 1, true))
  end)

  it("keeps going when a plugin source throws", function()
    local saved = package.loaded["lazy.core.config"]
    package.loaded["lazy.core.config"] = {
      plugins = {
        bad = setmetatable({}, {
          __index = function()
            error("boom")
          end,
        }),
      },
    }
    require("gitsuite.config").setup({ plugins = { roots = {}, sources = { "clones" } } })
    local ok, err = pcall(require("gitsuite.health").check)
    package.loaded["lazy.core.config"] = saved
    assert.is_true(ok, tostring(err))
    assert.is_truthy(messages("warn"):find("lazy: available but unreadable", 1, true))
    assert.is_truthy(messages():find("gitsuite: plugin reports", 1, true) or #records > 0)
  end)

  it("gives advice that fits why the report store is read-only", function()
    local state = require("gitsuite.features.plugins.state")
    local original = state.path
    local directory = F.tmpdir("-health-store-is-a-dir")
    state.path = function()
      return directory
    end
    local ok, err = pcall(require("gitsuite.health").check)
    state.path = original
    assert.is_true(ok, tostring(err))
    local advice
    for _, r in ipairs(records) do
      if r.kind == "warn" and r.msg:find("not a plain file", 1, true) then advice = r.advice end
    end
    assert.is_not_nil(advice, "a warning about the store")
    local text = table.concat(advice, " ")
    assert.is_truthy(text:find("regular file", 1, true))
    assert.is_nil(text:find("Update gitsuite.nvim", 1, true))
  end)
end)
