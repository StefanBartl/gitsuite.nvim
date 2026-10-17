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
    local adapter = require("gitsuite.adapter")
    local original = adapter.resolve
    adapter.resolve = function(name)
      if name == "lazy" then
        return {
          name = "lazy",
          list = function()
            error("boom from the source")
          end,
        }
      end
      return original(name)
    end
    require("gitsuite.config").setup({ plugins = { roots = {}, sources = { "clones" } } })
    local ok, err = pcall(require("gitsuite.health").check)
    adapter.resolve = original
    assert.is_true(ok, tostring(err))
    local warned = messages("warn")
    assert.is_truthy(warned:find("lazy: available but unreadable", 1, true))
    assert.is_truthy(warned:find("boom from the source", 1, true))
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

  it("says whether the :Lazy sync hook listens", function()
    pcall(require("gitsuite.health").check)
    assert.is_truthy(messages("info"):find("lazy integration: off", 1, true))

    local lazy = require("gitsuite.integrations.lazy")
    local cfg = require("gitsuite.config").setup({ plugins = { after_sync = "toast" } })
    records = {}
    pcall(require("gitsuite.health").check)
    assert.is_truthy(messages("info"):find("lazy integration: toast, not listening yet", 1, true))

    lazy.setup(cfg)
    records = {}
    pcall(require("gitsuite.health").check)
    pcall(vim.api.nvim_del_augroup_by_name, lazy.GROUP)
    assert.is_truthy(
      messages("ok"):find("lazy integration: toast (listening on User LazySync)", 1, true)
    )
  end)

  it("reports terminal.nvim as an optional dependency of :Git ui lazygit", function()
    local saved_loaded, saved_preload = package.loaded["terminal"], package.preload["terminal"]
    package.loaded["terminal"] = nil
    package.preload["terminal"] = function()
      error("terminal.nvim is not installed in this spec")
    end
    pcall(require("gitsuite.health").check)
    local absent, absent_warn = messages("info"), messages("warn")

    -- (LuaJIT leaves a sentinel in package.loaded after a loader error)
    package.loaded["terminal"] = nil
    package.preload["terminal"] = function()
      return { run = function() end }
    end
    records = {}
    pcall(require("gitsuite.health").check)
    local present = messages("ok")
    package.loaded["terminal"], package.preload["terminal"] = saved_loaded, saved_preload

    assert.is_truthy(absent:find("terminal not installed: :Git ui lazygit opens in", 1, true))
    assert.is_nil(absent_warn:find("terminal", 1, true))
    assert.is_truthy(present:find("terminal found: :Git ui lazygit runs as", 1, true))
  end)
end)
