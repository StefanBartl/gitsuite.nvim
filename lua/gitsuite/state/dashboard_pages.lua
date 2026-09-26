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
---
--- Every path is compared via `repos.normalize_path`, never raw string
--- equality: `a` persists whatever the user typed (unexpanded, whichever
--- separator), while `x` passes the fully resolved `record.path` -- without
--- normalizing both sides first, the two would almost never match the same
--- entry.
---
--- No process-lifetime cache: every call re-reads the file fresh and, for a
--- mutation, writes it straight back. Two Neovim instances with the
--- dashboard open at once (a common workflow -- one per project/terminal
--- tab) each editing a *different* page would otherwise silently clobber
--- each other's change with a stale in-memory snapshot on whichever saved
--- last. The extra I/O is the trade worth making here -- these are
--- interactive, human-paced writes (one `a`/`x` keypress at a time), never
--- a hot path.

local json = require("lib.nvim.fs.json")
local normalize_path = require("gitsuite.features.dashboard.repos").normalize_path

---@class GitSuiteDashboardPagesState
local M = {}

---@return string
local function state_path()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "gitsuite", "dashboard_pages.json")
end

---@return table<string, { added: string[], removed: string[] }>
local function load()
  local data = json.read(state_path())
  return (type(data) == "table") and data or {}
end

---@param data table<string, { added: string[], removed: string[] }>
---@return boolean ok
local function save(data)
  local dir = vim.fs.dirname(state_path())
  vim.fn.mkdir(dir, "p")
  return json.write(state_path(), data)
end

---@param data table<string, { added: string[], removed: string[] }>
---@param key string
---@return { added: string[], removed: string[] }
local function entry(data, key)
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
  local e = entry(load(), key)
  ---@type table<string, boolean>
  local removed = {}
  for _, p in ipairs(e.removed) do
    removed[normalize_path(p)] = true
  end

  local out = {}
  ---@type table<string, boolean>
  local present = {}
  for _, p in ipairs(static_paths or {}) do
    local key_ = normalize_path(p)
    if not removed[key_] then
      out[#out + 1] = p
      present[key_] = true
    end
  end

  -- An added entry that (under some other spelling) is already in `out` is
  -- not appended a second time.
  for _, p in ipairs(e.added) do
    local key_ = normalize_path(p)
    if not present[key_] then
      present[key_] = true
      out[#out + 1] = p
    end
  end
  return out
end

---Adds `add_path` to page `key`, persisted immediately. A no-op if it is
---already there (compared via `normalize_path`, not raw string equality).
---@param key string
---@param add_path string
---@return boolean ok
function M.add(key, add_path)
  local data = load()
  local e = entry(data, key)
  local norm = normalize_path(add_path)
  for _, p in ipairs(e.added) do
    if normalize_path(p) == norm then return true end
  end
  e.added[#e.added + 1] = add_path
  return save(data)
end

---Hides `remove_path` from page `key`: drops it from `added` if it was
---added at runtime, otherwise records it in `removed` so a statically
---configured entry stays hidden without editing `setup()`. Matched via
---`normalize_path` in both directions, since `remove_path` (the resolved
---`record.path` a dashboard row carries) rarely shares the exact spelling
---of whatever `add`/config used.
---@param key string
---@param remove_path string
---@return boolean ok
function M.remove(key, remove_path)
  local data = load()
  local e = entry(data, key)
  local norm = normalize_path(remove_path)

  for i, p in ipairs(e.added) do
    if normalize_path(p) == norm then
      table.remove(e.added, i)
      return save(data)
    end
  end
  for _, p in ipairs(e.removed) do
    if normalize_path(p) == norm then return true end
  end
  e.removed[#e.removed + 1] = remove_path
  return save(data)
end

return M
