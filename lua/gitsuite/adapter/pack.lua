---@module 'gitsuite.adapter.pack'
--- Plugin source: the plugins Neovim's built-in `vim.pack` manages.
---
--- Read from the lockfile (`nvim-pack-lock.json`, in the config folder) and the
--- folders below `stdpath("data")/site/pack/core/opt` -- NOT through
--- `vim.pack.get`: its first call per session synchronises the lockfile with the
--- disk, which can ask to install plugins, clone them and rewrite the lockfile.
--- A read-only feature must not trigger any of that, and `:checkhealth` asks
--- every adapter whether it is available. Reading the documented file needs no
--- process and no network.
---
--- Available only when `vim.pack` actually manages something that is on disk: it
--- is part of Neovim core, so "the function exists" says nothing, and an
--- auto-detected source that is always present but usually empty would hide the
--- `clones` fallback behind it.

local uv = vim.uv or vim.loop

---@class GitSuite.PluginSource.Pack : GitSuite.PluginSource
local M = { name = "pack" }

---The lockfile is a few hundred bytes per plugin; far more is not a lockfile.
local MAX_LOCK = 1024 * 1024

---@internal
---@return { name: string, dir: string, src?: string, version?: string }[]|nil
local function entries()
  local path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")
  local st = uv.fs_lstat(path)
  if not st or st.type ~= "file" or st.size > MAX_LOCK then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  local ok, lock = pcall(vim.json.decode, raw or "", { luanil = { object = true } })
  if not ok or type(lock) ~= "table" or type(lock.plugins) ~= "table" then return nil end

  local root = vim.fs.joinpath(vim.fn.stdpath("data"), "site", "pack", "core", "opt")
  local out = {}
  for name, info in pairs(lock.plugins) do
    -- (a name is a folder name below `opt`: nothing that could leave it)
    if type(name) == "string" and name:match("^[%w_.%-]+$") and name ~= "." and name ~= ".." then
      local dir = vim.fs.joinpath(root, name)
      local dst = uv.fs_lstat(dir)
      if dst and dst.type == "directory" then
        local version = type(info) == "table" and type(info.version) == "string" and info.version
          or nil
        out[#out + 1] = {
          name = name,
          dir = dir,
          src = type(info) == "table" and type(info.src) == "string" and info.src or nil,
          -- A branch or tag is stored quoted ('main'); anything else is a
          -- serialised version range, which is not a ref name.
          version = version and version:match("^'(.*)'$") or nil,
        }
      end
    end
  end
  return out
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
  if not plugins then return nil, "no vim.pack lockfile" end

  ---@type GitSuite.Plugins.Ref[]
  local refs = {}
  for _, plugin in ipairs(plugins) do
    refs[#refs + 1] = {
      name = plugin.name,
      dir = plugin.dir,
      url = plugin.src,
      managed_by = "pack",
      is_local = false,
      spec = { branch = plugin.version, pin = false },
    }
  end
  table.sort(refs, function(a, b)
    return a.name < b.name
  end)
  return refs, nil
end

return M
