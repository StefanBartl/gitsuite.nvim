---@module 'gitsuite.config'
--- Runtime configuration store for gitsuite.nvim.
---
--- Merges user options over the immutable DEFAULTS and exposes the active
--- config via `get()`. Keeps no global state outside this module (PRIN-10).

local DEFAULTS = require("gitsuite.config.DEFAULTS")

-- Resolved here, not inline in DEFAULTS.lua, so requiring that module alone
-- stays pure data (no env read at require time) -- same reasoning
-- reposcope.nvim's `clone.std_dir` follows. Via lib.nvim's env snapshot, not
-- a bare `os.getenv`, so this agrees with whatever `$REPOS_DIR`
-- Tab-completion elsewhere in the ecosystem already resolves to.
DEFAULTS.dashboard.base_dir = require("lib.nvim.system.env").get().repo_base
  or DEFAULTS.dashboard.base_dir

local M = {}

---@type GitSuite.Config|nil
local _active = nil

---@internal
---@param v any
---@return boolean
local function is_boolean(v)
  return type(v) == "boolean"
end

---@internal
---@param v any
---@return boolean
local function is_string(v)
  return type(v) == "string" and v ~= ""
end

---@internal
---@param v any
---@return boolean
local function is_string_or_empty(v)
  return type(v) == "string"
end

---Schema for `setup()`'s top-level and one-level-nested keys (ERR-50/ERR-22):
---an unknown key or a value that fails its check is dropped before the merge
---so the built-in default underneath actually applies, instead of silently
---vanishing into a typo.
---  - `true`                     accept any value at that leaf, unchecked
---  - `{ ok, expect }`           accept only a value `ok()` approves
---  - `table<string, Schema>`    nested table, validated recursively
---@alias GitSuite.Config.Check { ok: fun(v: any): boolean, expect: string }
---@alias GitSuite.Config.Schema true|GitSuite.Config.Check|table<string, GitSuite.Config.Schema>
---@type table<string, GitSuite.Config.Schema>
local KNOWN = {
  features = {
    conflict = { ok = is_boolean, expect = "a boolean" },
    hunk = { ok = is_boolean, expect = "a boolean" },
    blame = { ok = is_boolean, expect = "a boolean" },
    diff = { ok = is_boolean, expect = "a boolean" },
    browse = { ok = is_boolean, expect = "a boolean" },
    branch = { ok = is_boolean, expect = "a boolean" },
    ui = { ok = is_boolean, expect = "a boolean" },
    status = { ok = is_boolean, expect = "a boolean" },
  },
  commands = {
    git = { ok = is_string, expect = "a non-empty string" },
  },
  -- Per-action keymap: a string lhs, a list of lhs strings, or `false` to
  -- disable that action's default mapping entirely.
  keymaps = true,
  browse = {
    hosts = true,
  },
  branch = {
    sessions = { ok = is_boolean, expect = "a boolean" },
  },
  dashboard = {
    base_dir = { ok = is_string_or_empty, expect = "a string" },
    extra_paths = true,
    groups = true,
  },
  progress_style = { ok = is_string, expect = "a non-empty string" },
}

---@internal
---@param opts table
---@param schema table<string, GitSuite.Config.Schema>
---@param prefix string
---@return table clean
---@return string[] found_issues
local function sanitize(opts, schema, prefix)
  local clean, found_issues = {}, {}
  for key, value in pairs(opts) do
    local expected = schema[key]
    if expected == nil then
      found_issues[#found_issues + 1] = ("unknown option '%s%s'"):format(prefix, tostring(key))
    elseif expected == true then
      clean[key] = value
    elseif type(expected) == "table" and expected.ok ~= nil then
      if expected.ok(value) then
        clean[key] = value
      else
        found_issues[#found_issues + 1] = ("option '%s%s' must be %s, got %s -- using the default"):format(
          prefix,
          tostring(key),
          expected.expect,
          vim.inspect(value)
        )
      end
    elseif type(value) ~= "table" then
      found_issues[#found_issues + 1] = ("option '%s%s' must be a table, got %s -- using the default"):format(
        prefix,
        tostring(key),
        type(value)
      )
    else
      local sub_clean, sub_issues = sanitize(value, expected, prefix .. tostring(key) .. ".")
      clean[key] = sub_clean
      vim.list_extend(found_issues, sub_issues)
    end
  end
  return clean, found_issues
end

---@type string[]
local _issues = {}

---Whatever the last `setup()` call rejected -- one message per issue, empty
---when everything validated. For `:checkhealth gitsuite`.
---@return string[]
function M.issues()
  return vim.deepcopy(_issues)
end

---Merge user options over the defaults and store the result.
---@param user_opts? GitSuite.Opts
---@return GitSuite.Config
function M.setup(user_opts)
  if type(user_opts) ~= "table" then
    user_opts = {} --[[@as table]]
  end

  local clean, found_issues = sanitize(user_opts, KNOWN, "")
  table.sort(found_issues)
  _issues = found_issues

  _active = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), clean)
  return _active
end

---Return the active configuration, falling back to defaults if `setup` was
---never called.
---@return GitSuite.Config
function M.get()
  if _active == nil then _active = vim.deepcopy(DEFAULTS) end
  return _active
end

return M
