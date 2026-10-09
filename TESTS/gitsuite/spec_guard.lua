-- TESTS/gitsuite/spec_guard.lua -- puts back what a spec patched, whatever the test did. Not a
-- spec (no `_spec` suffix): a spec loads it with
--
--   local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
--   local G = dofile(dir_of_spec .. "spec_guard.lua")()
--
-- and names, once per `describe`, the fields its tests patch:
--
--   G.install({
--     { vim.ui, "select" },                       -- a table and the keys to guard
--     { vim, "notify", "cmd" },
--     { package.preload, "sessions.core" },
--     { "gitsuite.util.notify", "warn", "error" }, -- or a module, by name
--   })
--
-- Before each test the values are noted, after each test (also when it threw) every field that
-- differs is set back. A test that restores by hand is not affected; one that throws between the
-- patch and its own restore no longer leaves the patch behind for the tests after it.
return function()
  local G = {}

  ---@param target table  `{ tbl|module_name, key, ... }`
  ---@return table|nil tbl
  ---@return string|nil module  The module name, when the target was given by one.
  local function resolve(target)
    local t = target[1]
    if type(t) ~= "string" then return t, nil end
    local ok, mod = pcall(require, t)
    if ok and type(mod) == "table" then return mod, t end
    return nil, nil
  end

  ---Guard the given fields for every test of the enclosing `describe`.
  ---@param targets table[]
  function G.install(targets)
    local noted = {}

    before_each(function()
      noted = {}
      for _, target in ipairs(targets) do
        local tbl, module = resolve(target)
        if tbl then
          for i = 2, #target do
            local key = target[i]
            noted[#noted + 1] = { tbl = tbl, module = module, key = key, value = tbl[key] }
          end
        end
      end
    end)

    after_each(function()
      for _, n in ipairs(noted) do
        -- A module the spec reloaded is a different table now: its fields are its own.
        local same = n.module == nil or package.loaded[n.module] == n.tbl
        if same and n.tbl[n.key] ~= n.value then n.tbl[n.key] = n.value end
      end
      noted = {}
    end)
  end

  return G
end
