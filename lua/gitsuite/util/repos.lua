---@module 'gitsuite.util.repos'
---@brief Helpers for recognising and enumerating local git repositories (file system only, no process).
---@description
--- Shared by `features/dashboard` (a directory of clones you maintain) and
--- `features/plugins` (the clones a plugin manager installed). Lives in `util/`
--- so neither feature has to import the other: `adapter/` and `features/plugins`
--- must not depend on `features/dashboard`, and a later move of either into its
--- own plugin stays cheap.
---
--- `is_git_repo`, `collect_repos`, `normalize_path` and `comparison_key` were
--- extracted from `features/dashboard/repos.lua`, which re-exports them;
--- `git_marker`, `is_git_dir`, `origin_url` and `rtrim` were added for
--- `features/plugins`. No config access here -- `resolve_base_dir` and the
--- group resolution, which read `dashboard.*`, stay with the dashboard.

local uv = vim.uv or vim.loop
-- Resolves any path spec to its absolute, trailing-separator-free,
-- comparison-ready form -- including the separator-only edge case ("/",
-- "//", "\\\\", "\\/\\", ...). Centralized in lib.nvim so every consumer
-- shares one tested implementation instead of re-deriving it.
local to_absolute = require("lib.nvim.cross.fs.to_absolute")
local unify_slashes = require("lib.nvim.cross.fs.separators.unify_slashes")
local is_windows = require("lib.nvim.cross.platform.is_windows")

local M = {}

---What `<path>/.git` is: `"directory"` (a normal clone), `"file"` (a worktree
---or a submodule checkout, whose `.git` points elsewhere) or `nil`.
---@param path string Absolute path to the candidate directory
---@return "directory"|"file"|nil
function M.git_marker(path)
  local stat = uv.fs_stat(path .. "/.git")
  if stat and (stat.type == "directory" or stat.type == "file") then return stat.type end
  return nil
end

---Checks whether a directory is a git repository.
---Accepts both a `.git` directory (normal clone) and a `.git` file (worktree/submodule).
---@param path string Absolute path to the candidate directory
---@return boolean
function M.is_git_repo(path)
  return M.git_marker(path) ~= nil
end

---Checks whether a directory is a git repository with its own `.git`
---**directory** -- the shape a plugin manager clones. A `.git` file (worktree,
---submodule) is not: its history lives elsewhere, and lazy.nvim itself skips
---such a directory.
---@param path string Absolute path to the candidate directory
---@return boolean
function M.is_git_dir(path)
  return M.git_marker(path) == "directory"
end

---Collects all immediate subdirectories of `base_dir` that are git repositories.
---@param base_dir string Absolute path to scan (without trailing separator)
---@return string[] repos Absolute paths of discovered repositories
function M.collect_repos(base_dir)
  ---@type string[]
  local repos = {}

  local handle = uv.fs_scandir(base_dir)
  if not handle then return repos end

  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then break end

    -- Anything that is not a plain file: a symlinked or junctioned clone
    -- (stow, `ln -s`) reports "link", a file system without d_type reports
    -- nothing. `is_git_repo` stats the candidate and decides.
    if typ ~= "file" then
      local path = base_dir .. "/" .. name
      if M.is_git_repo(path) then repos[#repos + 1] = path end
    end
  end

  return repos
end

---Trailing whitespace removed in ONE linear pass. `s:gsub("%s+$", "")` and
---`line:match("(.-)%s*$")` retry the blank run from every start position -- on
---text somebody else wrote, a long run of blanks followed by one letter takes
---minutes.
---@param s string
---@return string
function M.rtrim(s)
  local last = #s
  while last > 0 do
    local b = s:byte(last)
    if b == 32 or (b >= 9 and b <= 13) then
      last = last - 1
    else
      break
    end
  end
  return s:sub(1, last)
end

---Longest `.git/config` line `origin_url` looks at; a real URL is far shorter.
M.MAX_CONFIG_LINE = 4096

---The value of a `key = value` line as git reads it: a double-quoted value is
---taken up to its closing quote (`\"` and `\\` unescaped); an unquoted one ends
---at the first `;` or `#` (a comment) and loses the whitespace around it.
---@param raw string  Everything after the `=`
---@return string
local function parse_config_value(raw)
  local value = raw:gsub("^%s+", "")
  if value:sub(1, 1) == '"' then
    local out, i = {}, 2
    while i <= #value do
      local c = value:sub(i, i)
      if c == "\\" then
        out[#out + 1] = value:sub(i + 1, i + 1)
        i = i + 2
      elseif c == '"' then
        break
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    return table.concat(out)
  end
  return M.rtrim((value:gsub("[;#].*$", "")))
end

---The URL of the `origin` remote, read from `<dir>/.git/config` **without
---running git** -- so it needs no process, no timeout and cannot be reached by
---anything git does with a hostile configuration. Bounded: only a regular file
---(not a symlink) of at most 256 KiB is read, and no line longer than
---`MAX_CONFIG_LINE`. `nil` when there is no such remote.
---@param dir string
---@return string|nil
function M.origin_url(dir)
  local text =
    require("lib.nvim.fs.read_bounded")(dir .. "/.git/config", 262144, { follow_symlinks = false })
  if not text then return nil end
  local in_origin = false
  for line in (text:gsub("\r\n", "\n")):gmatch("[^\n]+") do
    if #line <= M.MAX_CONFIG_LINE then
      local header, rest = line:match("^%s*%[(.-)%]%s*(.*)$")
      if header then
        -- section names are case-insensitive, the quoted subsection is not
        local name, sub = header:match('^(%S+)%s+"(.*)"$')
        in_origin = name ~= nil and name:lower() == "remote" and sub == "origin"
        line = rest -- `[remote "origin"] url = x` keeps its entry on the header line
      end
      if in_origin then
        local key, value = line:match("^%s*([%w%-]+)%s*=(.*)$")
        if key and key:lower() == "url" then
          local url = parse_config_value(value)
          if url ~= "" then return url end
        end
      end
    end
  end
  return nil
end

---Normalizes a path for *comparison*: expanded (`~`, env vars), absolute,
---no trailing separator, slashes unified, and lowercased on Windows (whose
---filesystem is itself case-insensitive). The one key any two spellings of
---"the same path" -- `~/repos/x`, `E:\repos\x`, `e:/repos/x/` -- resolve to
---the same value under.
---@param path string
---@return string
function M.normalize_path(path)
  local key = unify_slashes(to_absolute(path))
  if is_windows() then key = key:lower() end
  return key
end

---Same comparison key as `normalize_path`, for a `path` already known to be
---absolute -- skips `to_absolute`'s `fnamemodify`/`expand` round-trip a second
---time on a string that already went through it once.
---@param path string
---@return string
function M.comparison_key(path)
  local key = unify_slashes(path)
  if is_windows() then key = key:lower() end
  return key
end

return M
