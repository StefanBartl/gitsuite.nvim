---@module 'gitsuite.state.dashboard_pages'
---@brief Persists interactive path additions/removals on `:Git dashboard`.
---@description
--- The dashboard's `a`/`x` keys (see `features/dashboard/view.lua`) let a
--- user add or hide a repository path on the page they are currently
--- looking at, without editing `setup()`. Those changes are layered
--- additively over the static `dashboard.groups`/`dashboard.extra_paths`
--- from config -- never rewriting the user's Lua (the one place this
--- ecosystem does that, `:MyPlugins mode`'s single `OVERRIDE = "..."` line,
--- is a deliberate, narrow exception, not a precedent for mutating an
--- arbitrary list) -- so the config stays the single source of truth for
--- what ships in dotfiles, and this file only ever holds this machine's own
--- runtime additions.
---
--- Keyed by page name (`""` for the default, unnamed `base_dir` page); each
--- entry holds `added` (paths the user typed in) and `removed` (static
--- paths hidden from this page without touching config).

local json = require("lib.nvim.fs.json")

---@class GitSuiteDashboardPagesState
local M = {}

---@return string
local function state_path()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "gitsuite", "dashboard_pages.json")
end

---@type table<string, { added: string[], removed: string[] }>|nil
local _cache

---@return table<string, { added: string[], removed: string[] }>
local function load()
  if _cache then return _cache end
  local data = json.read(state_path())
  _cache = (type(data) == "table") and data or {}
  return _cache
end

---@return boolean ok
local function save()
  local dir = vim.fs.dirname(state_path())
  vim.fn.mkdir(dir, "p")
  local ok = json.write(state_path(), _cache or {})
  return ok
end

---@param key string
---@return { added: string[], removed: string[] }
local function entry(key)
  local data = load()
  data[key] = data[key] or { added = {}, removed = {} }
  data[key].added = data[key].added or {}
  data[key].removed = data[key].removed or {}
  return data[key]
end

---Applies this page's persisted overlay to its statically configured paths:
---drops anything hidden via `M.remove`, then appends anything added via
---`M.add`.
---@param key string Page name, `""` for the default page
---@param static_paths string[] The page's `setup()`-declared paths
---@return string[] resolved
function M.apply(key, static_paths)
  local e = entry(key)
  ---@type table<string, boolean>
  local removed = {}
  for _, p in ipairs(e.removed) do
    removed[p] = true
  end

  local out = {}
  for _, p in ipairs(static_paths or {}) do
    if not removed[p] then out[#out + 1] = p end
  end
  vim.list_extend(out, e.added)
  return out
end

---Adds `add_path` to page `key`, persisted immediately. A no-op if it is
---already there.
---@param key string
---@param add_path string
---@return boolean ok
function M.add(key, add_path)
  local e = entry(key)
  for _, p in ipairs(e.added) do
    if p == add_path then return true end
  end
  e.added[#e.added + 1] = add_path
  return save()
end

---Hides `remove_path` from page `key`: drops it from `added` if it was
---added at runtime, otherwise records it in `removed` so a statically
---configured entry stays hidden without editing `setup()`.
---@param key string
---@param remove_path string
---@return boolean ok
function M.remove(key, remove_path)
  local e = entry(key)
  for i, p in ipairs(e.added) do
    if p == remove_path then
      table.remove(e.added, i)
      return save()
    end
  end
  for _, p in ipairs(e.removed) do
    if p == remove_path then return true end
  end
  e.removed[#e.removed + 1] = remove_path
  return save()
end

return M
