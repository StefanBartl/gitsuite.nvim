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

---@internal
---True only for a genuine list -- every key a sequential integer `1..#v`,
---nothing else. `ipairs()` alone silently skips a hash-keyed table (e.g.
---`{ foo = "bar" }`) as though it were an empty, valid list, so a checker
---that only loops with `ipairs()` would accept a malformed config value
---with zero warning instead of rejecting it the way a non-list value
---already is.
---@param v table
---@return boolean
local function is_proper_list(v)
  local count = 0
  for _ in pairs(v) do
    count = count + 1
  end
  return count == #v
end

---@internal
---A table whose every entry is a non-empty string -- e.g.
---`dashboard.extra_paths`. Rejecting a wrongly-shaped *entry* here, not just
---a wrongly-typed outer value, matters because `repos.to_absolute()` (a
---non-string entry would crash on `:gsub`) and `dashboard_pages.apply()`'s
---`ipairs` both run over this list unchecked once `setup()` has accepted it.
---@param v any
---@return boolean
local function is_list_of_strings(v)
  if type(v) ~= "table" or not is_proper_list(v) then return false end
  for _, item in ipairs(v) do
    if type(item) ~= "string" or item == "" then return false end
  end
  return true
end

---@internal
---A table of `dashboard.groups` entries: each must be `{ name: string,
---paths?: string[] }`. `paths`, when present, goes through the same
---`is_list_of_strings` check `extra_paths` does -- `features/dashboard/
---init.lua`'s `build_pages()` passes it straight to `dashboard_pages.apply()`
---(`for _, p in ipairs(static_paths or {})`), which raises on anything that
---isn't a table at all, and would misbehave silently on a table of
---non-strings.
---@param v any
---@return boolean
local function is_valid_groups(v)
  if type(v) ~= "table" or not is_proper_list(v) then return false end
  for _, group in ipairs(v) do
    if type(group) ~= "table" then return false end
    if type(group.name) ~= "string" or group.name == "" then return false end
    if group.paths ~= nil and not is_list_of_strings(group.paths) then return false end
  end
  return true
end

---@internal
---A whole number from 1 to `max` (a count, or a timeout in milliseconds). The
---upper bound keeps `math.huge`, `1e300` and `2^63` out: they pass a bare
---"is it integral" test, then break the git command line or print as garbage.
---@param max integer
---@return fun(v: any): boolean
local function int_in(max)
  return function(v)
    return type(v) == "number" and v >= 1 and v <= max and v == math.floor(v)
  end
end

---@internal
---`plugins.mode`: what a report compares.
---@param v any
---@return boolean
local function is_report_mode(v)
  return v == "updated" or v == "pending"
end

---@internal
---`plugins.after_sync`: what happens after `:Lazy sync`.
---@param v any
---@return boolean
local function is_after_sync(v)
  return v == "off" or v == "toast" or v == "open"
end

---@internal
---A list of `vim.regex` patterns that all compile (`plugins.breaking.ignore`):
---a broken pattern is reported at setup, not skipped silently on every report.
---@param v any
---@return boolean
local function is_patterns(v)
  if not is_list_of_strings(v) then return false end
  for _, p in ipairs(v) do
    if not pcall(vim.regex, p) then return false end
  end
  return true
end

---@internal
---`plugins.breaking.plugins`: per plugin name `{ ignore?, force?, style? }`.
---@param v any
---@return boolean
local function is_breaking_plugins(v)
  if type(v) ~= "table" then return false end
  for name, spec in pairs(v) do
    if type(name) ~= "string" or name == "" or type(spec) ~= "table" then return false end
    for key, value in pairs(spec) do
      if key == "ignore" then
        if not is_patterns(value) then return false end
      elseif key == "force" then
        if not is_list_of_strings(value) then return false end
        for _, sha in ipairs(value) do
          if not sha:match("^%x+$") or #sha < 7 or #sha > 64 then return false end
        end
      elseif key == "style" then
        if value ~= "none" and value ~= "conventional" then return false end
      else
        return false
      end
    end
  end
  return true
end

---@internal
---`dashboard.pull_scope`: which choice `gP`'s prompt focuses first.
---@param v any
---@return boolean
local function is_pull_scope(v)
  return v == "behind" or v == "all"
end

---@internal
---`plugins.summarize`: the AI summary hook -- a function, or `false` for off.
---@param v any
---@return boolean
local function is_summarize_hook(v)
  return v == false or type(v) == "function"
end

---`plugins.sources`: the word "auto", or a list naming plugin sources.
---@param v any
---@return boolean
local function is_sources(v)
  if v == "auto" then return true end
  if type(v) ~= "table" or not is_proper_list(v) or #v == 0 then return false end
  for _, name in ipairs(v) do
    if name ~= "lazy" and name ~= "pack" and name ~= "clones" then return false end
  end
  return true
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
    extra_paths = { ok = is_list_of_strings, expect = "a table (list of non-empty path strings)" },
    groups = {
      ok = is_valid_groups,
      expect = "a table (list of { name: non-empty string, paths?: list of strings })",
    },
    pull_scope = { ok = is_pull_scope, expect = '"behind" or "all"' },
    fetch_jobs = { ok = int_in(16), expect = "a whole number from 1 to 16" },
  },
  plugins = {
    sources = { ok = is_sources, expect = '"auto" or a list of "lazy", "pack", "clones"' },
    roots = { ok = is_list_of_strings, expect = "a table (list of non-empty path strings)" },
    log_limit = { ok = int_in(1000000), expect = "a whole number from 1 to 1000000" },
    timeout_ms = {
      ok = int_in(2147483647),
      expect = "a whole number of milliseconds (1 to 2147483647)",
    },
    include_local = { ok = is_boolean, expect = "a boolean" },
    mode = { ok = is_report_mode, expect = '"updated" or "pending"' },
    max_commits = { ok = int_in(1000000), expect = "a whole number from 1 to 1000000" },
    parallel = { ok = int_in(64), expect = "a whole number from 1 to 64" },
    fetch_jobs = { ok = int_in(16), expect = "a whole number from 1 to 16" },
    fetch_timeout_ms = {
      ok = int_in(3600000),
      expect = "a whole number of milliseconds (1 to 3600000)",
    },
    fetch_confirm = { ok = int_in(100000), expect = "a whole number from 1 to 100000" },
    run_window_s = { ok = int_in(31536000), expect = "a whole number of seconds (1 to 31536000)" },
    merges = { ok = is_boolean, expect = "a boolean" },
    keep_reports = { ok = int_in(10000), expect = "a whole number from 1 to 10000" },
    seen_ttl_days = { ok = int_in(36500), expect = "a whole number of days from 1 to 36500" },
    max_age_days = { ok = int_in(36500), expect = "a whole number of days (1 to 36500)" },
    after_sync = { ok = is_after_sync, expect = '"off", "toast" or "open"' },
    summarize = { ok = is_summarize_hook, expect = "a function(input, done) or false" },
    summarize_key = { ok = is_string, expect = "a non-empty key string" },
    breaking = {
      collapse_repeats = { ok = int_in(1000), expect = "a whole number from 1 to 1000" },
      ignore = { ok = is_patterns, expect = "a list of valid vim.regex patterns" },
      plugins = {
        ok = is_breaking_plugins,
        expect = 'a table of plugin name -> { ignore = { patterns }, force = { commit hashes }, style = "none"|"conventional" }',
      },
    },
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

--- The sections whose checks are the predicates of `KNOWN` above (list shapes,
--- compiled patterns, ranges of whole numbers, enums with their own wording).
--- To the schema that `lib.lua.config` infers from `DEFAULTS` they are open
--- tables, so it does not second-guess a value `KNOWN` has already accepted
--- (`plugins.sources` is "auto" by default and a list when the user names sources).
--- Unknown top-level keys are still caught there.
---@type table<string, string|table>
local SCHEMA = {}
for key, spec in pairs(KNOWN) do
  if type(spec) == "table" and spec.ok == nil then SCHEMA[key] = { "table" } end
end

-- `keymaps` is a table of actions by default, `false` switches them all off, and a value per action
-- may be a string, a list or `false`: `KNOWN` checks nothing there, so the schema must not either.
SCHEMA.keymaps = "table|false"

local cfg = require("lib.lua.config").new(DEFAULTS, {
  name = "gitsuite",
  schema = SCHEMA,
  -- The checks of KNOWN, before the merge: a wrong value is dropped so the built-in default
  -- underneath applies. `opts` is a private copy, so it is rewritten in place.
  normalize = function(opts, issues)
    local clean, found_issues = sanitize(opts, KNOWN, "")
    for key in pairs(opts) do
      opts[key] = nil
    end
    for key, value in pairs(clean) do
      opts[key] = value
    end
    vim.list_extend(issues, found_issues)
  end,
})

---Whatever the last `setup()` call rejected -- one message per issue, empty
---when everything validated. For `:checkhealth gitsuite`.
---@return string[]
function M.issues()
  return cfg.issues()
end

---Set the options over the defaults and store the result. Every call starts
---from `DEFAULTS`.
---@param user_opts? GitSuite.Opts
---@return GitSuite.Config
function M.setup(user_opts)
  cfg.setup(type(user_opts) == "table" and user_opts or nil)
  return cfg.get()
end

---Return the active configuration, falling back to defaults if `setup` was
---never called.
---@return GitSuite.Config
function M.get()
  return cfg.get()
end

return M
