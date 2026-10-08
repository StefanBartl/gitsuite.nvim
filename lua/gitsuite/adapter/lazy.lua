---@module 'gitsuite.adapter.lazy'
--- Plugin source: the plugins lazy.nvim has installed, read from its in-memory
--- tables. Used by `features/plugins` to answer "which clones are my plugins".
---
--- Reads DATA only and never calls into lazy (LUA-91):
---   * availability is `package.loaded["lazy.core.config"] ~= nil` -- lazy's
---     `setup()` loads that module, so a `require` here would only ever make
---     a NOT-yet-configured lazy load itself;
---   * `lazy.core.config.plugins` is an undocumented (if de facto stable)
---     structure, so every field is type-guarded and an unexpected shape makes
---     `list()` return `nil, err` -- the next source (`pack`, `clones`) takes
---     over instead of the caller getting wrong data;
---   * a plugin table inherits from its spec through a metatable
---     (`setmetatable(plugin, { __index = super })`), so fields are read by
---     index only -- `pairs`, `vim.deepcopy` or a JSON encode would see a
---     fraction of them.

---@class GitSuite.PluginSource.Lazy : GitSuite.PluginSource
local M = { name = "lazy" }

---@return boolean
function M.is_available()
  return package.loaded["lazy.core.config"] ~= nil
end

---@internal
---@param v any
---@return string|nil
local function str(v)
  return type(v) == "string" and v ~= "" and v or nil
end

---lazy.nvim's own version string, for `:checkhealth` and for a report that
---wants to say what it read the data from.
---@return string|nil
function M.version()
  local config = package.loaded["lazy.core.config"]
  return type(config) == "table" and str(config.version) or nil
end

---Every plugin lazy.nvim has installed (including the `dir`-mode ones, flagged
---`is_local`), sorted by name.
---@param _opts? table
---@return GitSuite.Plugins.Ref[]|nil refs
---@return string|nil err
function M.list(_opts)
  local config = package.loaded["lazy.core.config"]
  if type(config) ~= "table" or type(config.plugins) ~= "table" then
    return nil,
      "lazy.nvim: `lazy.core.config.plugins` is not a table (did lazy.nvim change its internals?)"
  end

  ---@type GitSuite.Plugins.Ref[]
  local refs = {}
  for key, plugin in pairs(config.plugins) do
    if type(plugin) == "table" then
      local name = str(plugin.name) or str(key)
      local dir = str(plugin.dir)
      local state = type(plugin._) == "table" and plugin._ or {}
      -- `virtual` plugins (lazy's own `dir = "/dev/null/..."` placeholders) have
      -- no clone; a plugin lazy knows is not installed has none yet.
      local virtual = plugin.virtual == true or (dir ~= nil and dir:find("^/dev/null") ~= nil)
      if name and dir and not virtual and state.installed ~= false then
        refs[#refs + 1] = {
          name = name,
          dir = dir,
          url = str(plugin.url),
          managed_by = "lazy",
          is_local = state.is_local == true,
          spec = {
            branch = str(plugin.branch),
            tag = str(plugin.tag),
            commit = str(plugin.commit),
            version = plugin.version,
            pin = plugin.pin == true,
          },
        }
      end
    end
  end
  table.sort(refs, function(a, b)
    return a.name < b.name
  end)
  return refs, nil
end

return M
