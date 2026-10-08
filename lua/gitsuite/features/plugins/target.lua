---@module 'gitsuite.features.plugins.target'
--- Which commit lazy.nvim would move a plugin to on the next update -- worked
--- out from the plugin's spec and the clone's refs, without a process, in
--- lazy's own order (`lazy/manage/git.lua` `get_target`, 11.17):
---
---   1. `commit`   -- that commit;
---   2. `tag`      -- that tag;
---   3. `version`  -- the highest tag matching the range (`defaults.version`
---                    applies when the spec has neither `version` nor `branch`);
---   4. otherwise  -- the tip of `origin/<branch>` (or the local branch when
---                    origin has no such ref), `<branch>` being the spec's
---                    `branch` or the clone's default branch.
---
--- A pinned plugin is not moved at all. When none of this can be decided the
--- answer is `unknown` with the reason -- never "compare with origin/HEAD":
--- for a plugin on a tag range that compares against a branch lazy will never
--- check out (one installation reported 315 phantom commits).
---
--- Reads files only (`gitfs`); no network, no process.

local gitfs = require("gitsuite.features.plugins.gitfs")
local semver = require("gitsuite.features.plugins.semver")

local M = {}

---@class GitSuite.Plugins.TargetResolution
---@field tier "pin"|"commit"|"tag"|"version"|"branch"|"unknown"
---@field rev? string       What git turns into the target commit: a hash, or `refs/tags/<tag>^{commit}`.
---@field sha? string       The commit, when the files alone say so.
---@field certain? boolean  `sha` is known to be a commit (not possibly an annotated-tag object).
---@field label? string     Short human name: the tag, the branch, a short hash.
---@field branch? string
---@field tag? string
---@field reason? string    For `pin` and `unknown`: why there is no target.

---@class GitSuite.Plugins.TargetOpts
---@field defaults_version? any  lazy's `defaults.version` option.
---@field head? GitSuite.Plugins.Head  The clone's HEAD, when the caller has read it already (saves a second read).
---@field cloned? boolean  The caller has checked that `ref.dir` has its own `.git` directory.

---@param reason string
---@return GitSuite.Plugins.TargetResolution
local function unknown(reason)
  return { tier = "unknown", reason = reason }
end

---@param s any
---@return boolean
local function valid_branch(s)
  return type(s) == "string" and s ~= "" and gitfs.valid_refname("refs/heads/" .. s)
end

---A tag as a target.
---@param dir string
---@param tag string
---@param tier "tag"|"version"
---@return GitSuite.Plugins.TargetResolution
local function tag_target(dir, tag, tier)
  local sha, certain = gitfs.tag_commit(dir, tag)
  return {
    tier = tier,
    rev = "refs/tags/" .. tag .. "^{commit}",
    sha = sha,
    certain = certain,
    label = tag,
    tag = tag,
  }
end

---@param ref GitSuite.Plugins.Ref
---@param opts? GitSuite.Plugins.TargetOpts
---@return GitSuite.Plugins.TargetResolution
function M.resolve(ref, opts)
  opts = opts or {}
  local dir = ref.dir
  if opts.cloned ~= true and not gitfs.is_clone(dir) then return unknown("no .git directory") end
  local spec = ref.spec or {}
  local head = opts.head or gitfs.head(dir)

  local function default_branch()
    local target = gitfs.symref(dir, "refs/remotes/origin/HEAD")
    local branch = target and target:match("^refs/remotes/origin/(.+)$")
    if valid_branch(branch) then return branch end
    return head and head.branch or nil
  end

  local function branch_target(branch)
    if not valid_branch(branch) then return unknown("cannot tell which branch it follows") end
    local sha = gitfs.ref(dir, "refs/remotes/origin/" .. branch)
      or gitfs.ref(dir, "refs/heads/" .. branch)
    if not sha then
      local incomplete = gitfs.refs_incomplete(dir)
      if incomplete then return unknown("too many refs to read without git: " .. incomplete) end
      return unknown(("branch '%s' is not known locally"):format(branch))
    end
    return { tier = "branch", rev = sha, sha = sha, certain = true, label = branch, branch = branch }
  end

  -- A `dir`-mode plugin: lazy never updates it; "what is new" is its branch.
  if ref.is_local then
    return branch_target((head and head.branch) or spec.branch or default_branch())
  end

  if spec.pin then return { tier = "pin", reason = "pinned in the plugin spec" } end

  if spec.commit then
    local c = spec.commit
    if type(c) ~= "string" or #c < 7 or #c > 64 or not c:match("^%x+$") then
      return unknown("the spec's commit is not a hash")
    end
    return {
      tier = "commit",
      rev = c,
      sha = gitfs.valid_sha(c) and c or nil,
      certain = gitfs.valid_sha(c),
      label = c:sub(1, 8),
    }
  end

  if spec.tag then
    if type(spec.tag) ~= "string" or not gitfs.valid_refname("refs/tags/" .. spec.tag) then
      return unknown("the spec's tag is not a usable tag name")
    end
    local names, incomplete = gitfs.tag_names(dir)
    if not vim.tbl_contains(names, spec.tag) then
      if incomplete then return unknown("the clone's tag list could not be read completely") end
      return unknown(("tag '%s' is not in the clone (not fetched yet)"):format(spec.tag))
    end
    return tag_target(dir, spec.tag, "tag")
  end

  local version = spec.version
  if version == nil and spec.branch == nil then version = opts.defaults_version end
  -- (an empty string is a range in lazy too: the same as "*")
  if type(version) == "string" then
    local range = semver.range(version)
    if not range then return unknown(("version range '%s' not understood"):format(version)) end
    local matching = {}
    local names, incomplete = gitfs.tag_names(dir)
    for _, name in ipairs(names) do
      local v = semver.version(name)
      if v and semver.matches(range, v) then
        v.tag = name
        matching[#matching + 1] = v
      end
    end
    local best = semver.last(matching)
    if best and incomplete then
      return unknown("the clone's tag list could not be read completely")
    end
    if best then return tag_target(dir, best.tag, "version") end
    -- no tag matches yet: lazy falls through to the branch
  elseif version ~= nil and version ~= false then
    return unknown("this kind of version spec is not supported")
  end

  return branch_target(spec.branch or default_branch())
end

return M
