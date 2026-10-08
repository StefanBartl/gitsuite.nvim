---@module 'gitsuite.adapter.pack'
--- Plugin source: the plugins Neovim's built-in `vim.pack` manages.
---
--- `vim.pack.get(nil, { info = false })` only reads the lockfile -- no git
--- process, no network (`info = true` would spawn git per plugin).
---
--- Available only when `vim.pack` actually manages something: it is part of
--- Neovim core, so "the function exists" says nothing, and an auto-detected
--- source that is always present but usually empty would hide the `clones`
--- fallback behind it.

---@class GitSuite.PluginSource.Pack : GitSuite.PluginSource
local M = { name = "pack" }

---@internal
---@return table[]|nil
local function entries()
  if type(vim.pack) ~= "table" or type(vim.pack.get) ~= "function" then return nil end
  local ok, plugins = pcall(vim.pack.get, nil, { info = false })
  if not ok or type(plugins) ~= "table" then return nil end
  return plugins
end

---@return boolean
function M.is_available()
  local plugins = entries()
  return plugins ~= nil and #plugins > 0
end

---@param _opts? table
---@return GitSuite.Plugins.Ref[]|nil refs
---@return string|nil err
function M.list(_opts)
  local plugins = entries()
  if not plugins then return nil, "vim.pack is not available" end

  ---@type GitSuite.Plugins.Ref[]
  local refs = {}
  for _, plugin in ipairs(plugins) do
    local spec = type(plugin.spec) == "table" and plugin.spec or {}
    local name = type(spec.name) == "string" and spec.name or nil
    local dir = type(plugin.path) == "string" and plugin.path or nil
    if name and dir then
      local version = spec.version
      refs[#refs + 1] = {
        name = name,
        dir = dir,
        url = type(spec.src) == "string" and spec.src or nil,
        managed_by = "pack",
        is_local = false,
        spec = {
          -- `version` is a branch/tag name or a `vim.VersionRange`; only the
          -- string form is a ref name.
          branch = type(version) == "string" and version or nil,
          version = type(version) == "table" and version or nil,
          pin = false,
        },
      }
    end
  end
  table.sort(refs, function(a, b)
    return a.name < b.name
  end)
  return refs, nil
end

return M
