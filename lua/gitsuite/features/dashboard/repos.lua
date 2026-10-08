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

-- The pure path/repository helpers live in util/repos.lua (shared with
-- features/plugins, which must not import this module); re-exported below so
-- every existing caller keeps its `repos.is_git_repo`/`collect_repos`/
-- `normalize_path`.
local util = require("gitsuite.util.repos")
local to_absolute = require("lib.nvim.cross.fs.to_absolute")
-- Configuration
local config = require("gitsuite.config")

M.is_git_repo = util.is_git_repo
M.collect_repos = util.collect_repos
M.normalize_path = util.normalize_path

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
      -- `resolved` came straight out of `resolve_entry` above, already
      -- absolute -- `comparison_key`, not `M.normalize_path`, so it isn't
      -- run through `to_absolute`'s fnamemodify/expand a second time.
      local key = util.comparison_key(resolved)
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = resolved
      end
    end
  end
  return out
end

return M
