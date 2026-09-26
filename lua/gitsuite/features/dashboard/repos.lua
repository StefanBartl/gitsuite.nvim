---@module 'gitsuite.features.dashboard.repos'
---@brief Shared helpers for discovering local git repositories on disk.
---@description
--- Small, dependency-light utilities used by every command that operates on a
--- directory of cloned repositories (`:Git dashboard`, `:Git dashboard
--- update`). Keeping the scanning logic in one place guarantees that every
--- one of them agrees on what counts as a repository, how the base
--- directory is resolved, and which subdirectories are considered.
---
--- Resolution precedence for the base directory is: explicit override argument >
--- configured base directory (`dashboard.base_dir`, itself defaulted from
--- `$REPOS_DIR` in `config/init.lua`). Scanning is non-recursive — only the
--- immediate children of the base directory are inspected.
---
--- Ported from reposcope.nvim's `utils.repos` (dashboard moved to
--- gitsuite.nvim, which is the git-tooling home; reposcope stays the
--- GitHub/GitLab/Codeberg discovery tool).

---@class GitSuiteDashboardRepos
local M = {}

-- Vim Utilities
local uv = vim.uv or vim.loop
local fnamemodify = vim.fn.fnamemodify
local expand = require("lib.nvim.cross.fs.expand_path")
local unify_slashes = require("lib.nvim.cross.fs.separators.unify_slashes")
-- Configuration
local config = require("gitsuite.config")
local is_windows = require("lib.nvim.cross.platform.is_windows")

---@internal
---Resolves `path` to its absolute, trailing-separator-free form. Strips any
---trailing separator *before* handing off to `fnamemodify(..., ":p")`: on
---Windows, a drive-less absolute path (`/tmp/x`) only gets the current
---drive letter prepended when it has *no* trailing separator -- `/tmp/x/`
---comes back unresolved, un-anchored to any drive. Stripping first forces
---both spellings through the same code path, so they resolve to the same
---string instead of two different ones for the same real path.
---@param path string
---@return string
local function to_absolute(path)
  return (fnamemodify(expand(path:gsub("[\\/]+$", "")), ":p"):gsub("[\\/]+$", ""))
end

---Checks whether a directory is a git repository.
---Accepts both a `.git` directory (normal clone) and a `.git` file (worktree/submodule).
---@param path string Absolute path to the candidate directory
---@return boolean
function M.is_git_repo(path)
  local stat = uv.fs_stat(path .. "/.git")
  return stat ~= nil and (stat.type == "directory" or stat.type == "file")
end

---Resolves the base directory whose immediate subdirectories are scanned for repos.
---Precedence: explicit override > configured base directory (`dashboard.base_dir`).
---@param override string|nil Explicit directory passed on the command line
---@return string|nil base_dir Expanded path without trailing separator, or nil if unresolved
function M.resolve_base_dir(override)
  local dir = override

  if not dir or dir == "" then
    dir = config.get().dashboard and config.get().dashboard.base_dir or nil
  end

  if not dir or dir == "" then return nil end

  return to_absolute(dir)
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

    if typ == "directory" then
      local path = base_dir .. "/" .. name
      if M.is_git_repo(path) then repos[#repos + 1] = path end
    end
  end

  return repos
end

---Normalizes a path for *comparison*: expanded (`~`, env vars), absolute,
---no trailing separator, slashes unified, and lowercased on Windows (whose
---filesystem is itself case-insensitive). This is the one key any two
---spellings of "the same path" -- `~/repos/x`, `E:\repos\x`,
---`e:/repos/x/` -- resolve to the same value under, used both for
---deduplicating a scan's results (below) and, more importantly, for
---recognizing "is this the path the user already added/removed" in
---`state/dashboard_pages.lua`: without going through this, a page's
---raw, as-typed `a`/`x` input never reliably matches a resolved
---`record.path`, or a differently-spelled `dashboard.extra_paths`/`groups`
---config entry.
---@param path string
---@return string
function M.normalize_path(path)
  local key = unify_slashes(to_absolute(path))
  if is_windows() then key = key:lower() end
  return key
end

---Resolves one configured entry to the repository path(s) it names: itself,
---if it is already a repository, or every immediate git-repository child of
---it, if it is a plain directory to scan. The one resolution rule every
---dashboard page (the default `base_dir` scan, `extra_paths`, a configured
---group) applies to each of its entries.
---@param raw string A directory or single-repo path, `~`/env-expandable
---@return string[] resolved Absolute paths, empty when `raw` resolves to nothing
local function resolve_entry(raw)
  local resolved = to_absolute(raw)
  if M.is_git_repo(resolved) then return { resolved } end
  return M.collect_repos(resolved)
end

---Resolves a list of configured entries (a group's `paths`, or
---`extra_paths`) into a flat, deduplicated, order-preserving list of
---repository paths. `existing`, when given, is a list of already-known
---repository paths against which the result is deduplicated too -- so
---merging a group's resolution on top of a directory scan never reports the
---same repository twice.
---@param entries string[]
---@param existing? string[]
---@return string[] repos
function M.resolve_group_repos(entries, existing)
  ---@type table<string, boolean>
  local seen = {}
  for _, p in ipairs(existing or {}) do
    seen[M.normalize_path(p)] = true
  end

  ---@type string[]
  local out = {}
  for _, raw in ipairs(entries or {}) do
    for _, resolved in ipairs(resolve_entry(raw)) do
      local key = M.normalize_path(resolved)
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = resolved
      end
    end
  end
  return out
end

return M
