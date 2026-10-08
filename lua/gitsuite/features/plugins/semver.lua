---@module 'gitsuite.features.plugins.semver'
--- lazy.nvim's own version-range matching, ported so that "which tag does lazy
--- pick for `version = "1.*"`" has the answer lazy gives -- not the one
--- `vim.version.range` would. The two differ on purpose-built corners: lazy
--- reads a bare `1` or `1.2` as `~1` / `~1.2`, treats `.*`/`.x` as absent, and
--- only matches a version whose pre-release tag equals the range's (so a range
--- without one never selects `v2.0.0-rc.1`).
---
--- Pure: strings in, tables out. Source: `lazy/manage/semver.lua` (11.17).

local M = {}

---@class GitSuite.Plugins.Semver
---@field [1] integer major
---@field [2] integer minor
---@field [3] integer patch
---@field prerelease? string
---@field build? string
---@field tag? string  The tag name this version was parsed from.

---@class GitSuite.Plugins.SemverRange
---@field from? GitSuite.Plugins.Semver
---@field to? GitSuite.Plugins.Semver

---Parse a tag or version string (`v1.2.3-rc.1+build`); `nil` when it is not one.
---@param version string
---@return GitSuite.Plugins.Semver|nil
function M.version(version)
  if type(version) ~= "string" then return nil end
  local major, minor, patch, prerelease, build =
    version:match("^v?(%d+)%.?(%d*)%.?(%d*)%-?([^+]*)+?(.*)$")
  if not major then return nil end
  return {
    tonumber(major),
    minor == "" and 0 or tonumber(minor),
    patch == "" and 0 or tonumber(patch),
    prerelease = prerelease ~= "" and prerelease or nil,
    build = build ~= "" and build or nil,
  }
end

---@param a GitSuite.Plugins.Semver
---@param b GitSuite.Plugins.Semver
---@return boolean
function M.lt(a, b)
  for i = 1, 3 do
    if a[i] > b[i] then return false end
    if a[i] < b[i] then return true end
  end
  if a.prerelease and not b.prerelease then return true end
  if b.prerelease and not a.prerelease then return false end
  return (a.prerelease or "") < (b.prerelease or "")
end

---@param a GitSuite.Plugins.Semver
---@param b GitSuite.Plugins.Semver
---@return boolean
function M.eq(a, b)
  for i = 1, 3 do
    if a[i] ~= b[i] then return false end
  end
  return a.prerelease == b.prerelease
end

---@param a GitSuite.Plugins.Semver
---@param b GitSuite.Plugins.Semver
---@return boolean
local function le(a, b)
  return M.lt(a, b) or M.eq(a, b)
end

---The highest of `versions`.
---@param versions GitSuite.Plugins.Semver[]
---@return GitSuite.Plugins.Semver|nil
function M.last(versions)
  local last = versions[1]
  for i = 2, #versions do
    if M.lt(last, versions[i]) then last = versions[i] end
  end
  return last
end

---Whether `version` lies in `range`.
---@param range GitSuite.Plugins.SemverRange
---@param version GitSuite.Plugins.Semver|nil
---@return boolean
function M.matches(range, version)
  if not version or not range.from then return false end
  if version.prerelease ~= range.from.prerelease then return false end
  return le(range.from, version) and (range.to == nil or M.lt(version, range.to))
end

---@param spec string
---@return GitSuite.Plugins.SemverRange|nil
function M.range(spec)
  if type(spec) ~= "string" then return nil end
  if spec == "*" or spec == "" then return { from = M.version("0.0.0") } end

  local hyphen = spec:find(" - ", 1, true)
  if hyphen then
    local a = spec:sub(1, hyphen - 1)
    local b = spec:sub(hyphen + 3)
    local parts = vim.split(b, ".", { plain = true })
    local ra, rb = M.range(a), M.range(b)
    return { from = ra and ra.from, to = rb and (#parts == 3 and rb.from or rb.to) }
  end

  local mods, version = spec:lower():match("^([%^=>~]*)(.*)$")
  version = version:gsub("%.[%*x]", "")
  local parts = vim.split((version:gsub("%-.*", "")), ".", { plain = true })
  if #parts < 3 and mods == "" then mods = "~" end

  local semver = M.version(version)
  if not semver then return nil end
  local from = semver
  local to = vim.deepcopy(semver)
  if mods == "" or mods == "=" then
    to[3] = to[3] + 1
  elseif mods == ">" then
    from[3] = from[3] + 1
    to = nil
  elseif mods == ">=" then
    to = nil
  elseif mods == "~" then
    if #parts >= 2 then
      to[2] = to[2] + 1
      to[3] = 0
    else
      to[1] = to[1] + 1
      to[2] = 0
      to[3] = 0
    end
  elseif mods == "^" then
    for i = 1, 3 do
      if to[i] ~= 0 then
        to[i] = to[i] + 1
        for j = i + 1, 3 do
          to[j] = 0
        end
        break
      end
    end
  end
  return { from = from, to = to }
end

return M
