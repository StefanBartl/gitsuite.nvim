---@module 'gitsuite.adapter.clones'
--- Plugin source: plain directories of git clones. Needs no plugin manager at
--- all, so it is always available -- the fallback when neither lazy.nvim nor
--- `vim.pack` is in use, and the source for "any folder of clones".
---
--- Roots scanned (immediate children only):
---   * `opts.roots`, when given (the `plugins.roots` setting);
---   * otherwise `stdpath("data")/lazy` plus every `start`/`opt` directory of
---     `stdpath("data")/site/pack/*` (what `vim.pack`, packer and mini.deps use).
---
--- Only a child with its own `.git` **directory** counts: a `.git` *file*
--- (worktree, submodule) points at history stored elsewhere, and lazy.nvim
--- skips such a directory itself.

local repos = require("gitsuite.util.repos")
local uv = vim.uv or vim.loop

---@class GitSuite.PluginSource.Clones : GitSuite.PluginSource
local M = { name = "clones" }

---@return boolean
function M.is_available()
  return true
end

---The directories this source scans.
---@param opts? { roots?: string[] }
---@return string[]
function M.roots(opts)
  if opts and opts.roots and #opts.roots > 0 then
    local out = {}
    for _, root in ipairs(opts.roots) do
      out[#out + 1] = vim.fs.normalize(require("lib.nvim.cross.fs.to_absolute")(root))
    end
    return out
  end

  local data = vim.fs.normalize(vim.fn.stdpath("data"))
  local out = { data .. "/lazy" }
  local pack = data .. "/site/pack"
  local handle = uv.fs_scandir(pack)
  while handle do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then break end
    if typ == "directory" then
      out[#out + 1] = ("%s/%s/start"):format(pack, name)
      out[#out + 1] = ("%s/%s/opt"):format(pack, name)
    end
  end
  return out
end

---@param opts? { roots?: string[] }
---@return GitSuite.Plugins.Ref[] refs
function M.list(opts)
  ---@type GitSuite.Plugins.Ref[]
  local refs = {}
  local seen = {}
  for _, root in ipairs(M.roots(opts)) do
    for _, dir in ipairs(repos.collect_repos(root)) do
      dir = vim.fs.normalize(dir)
      local key = repos.comparison_key(dir)
      if repos.is_git_dir(dir) and not seen[key] then
        seen[key] = true
        refs[#refs + 1] = {
          name = vim.fs.basename(dir),
          dir = dir,
          url = repos.origin_url(dir),
          managed_by = "clones",
          is_local = false,
          spec = { pin = false },
        }
      end
    end
  end
  table.sort(refs, function(a, b)
    return a.name < b.name
  end)
  return refs
end

return M
