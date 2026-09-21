---@module 'gitsuite.adapter'
--- Adapter registry: load, resolve and cache the git-UI backends (gitsigns,
--- diffview, neogit, lazygit, native). Template: filetree.nvim's
--- `adapter/init.lua` (register/resolve/get/list), adjusted for gitsuite's
--- shape -- unlike a file explorer, gitsuite has several independent feature
--- families (hunk, ui, blame, ...) that each prefer a different backend, so
--- there is no single global "auto" winner; `resolve_first` lets a feature
--- module supply its own priority list instead (PRIN-07, "Soft Dependencies
--- zentralisieren": this module is the one place any feature checks for a
--- foreign plugin, never a scattered `pcall(require, "gitsigns")`).
---
--- Low-level module (ERR-04): never calls `notify` itself. An unavailable
--- adapter is not an error here -- whether that deserves a message is a
--- judgment the caller (a feature module, `:checkhealth`) makes.

local M = {}

---@type table<string, GitSuite.Adapter>
local _registry = {}

---Register a custom adapter. Built-in adapters self-register by being
---`require`d (see `resolve`/`resolve_first`): the returned module table IS
---the adapter, matching `GitSuite.Adapter` (name, is_available, ...).
---@param adapter GitSuite.Adapter
function M.register(adapter)
  assert(
    type(adapter.name) == "string" and adapter.name ~= "",
    "adapter.name must be a non-empty string"
  )
  _registry[adapter.name] = adapter
end

---Lazy-load a built-in adapter module by name if it is not registered yet.
---@internal
---@param name string
---@return GitSuite.Adapter|nil
local function load(name)
  if not _registry[name] then
    local ok, mod = pcall(require, "gitsuite.adapter." .. name)
    if ok and type(mod) == "table" then _registry[name] = mod end
  end
  return _registry[name]
end

---Resolve one named adapter. Returns nil if the name is unknown or the
---adapter reports `is_available() == false` (e.g. the foreign plugin isn't
---loaded) -- per `LUA-91`, availability is checked via `is_available()`
---(which itself must only read `package.loaded[...]`), never by `require`ing
---the foreign plugin.
---@param name string
---@return GitSuite.Adapter|nil
function M.resolve(name)
  local adapter = load(name)
  if not adapter or not adapter.is_available() then return nil end
  return adapter
end

---Resolve the first available adapter from an ordered priority list.
---Each feature module supplies its own list (e.g. `{"gitsigns", "native"}`
---for hunks) instead of relying on one hardcoded global order.
---@param candidates string[]
---@return GitSuite.Adapter|nil, string|nil name
function M.resolve_first(candidates)
  for _, name in ipairs(candidates) do
    local adapter = M.resolve(name)
    if adapter then return adapter, name end
  end
  return nil, nil
end

---Return all registered adapter names (only those already `require`d/registered
---at least once, not every theoretically loadable one).
---@return string[]
function M.list()
  local names = {}
  for name in pairs(_registry) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

return M
