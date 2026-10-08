---@module 'gitsuite.features.plugins.links'
--- Web links for the commits of a local clone: the commit's page. Only builds
--- URLs and hands them to the browser -- the same boundary `:Git browse` keeps:
--- no hosting API, no authentication, no request from here.
---
--- The remote URL comes from the clone's own `.git/config`, i.e. from the
--- author of the repository. Two consequences:
---   * it is read as a file (`util.repos.origin_url`), never by running git --
---     no process, no timeout to forget, nothing git does with a hostile
---     configuration can happen;
---   * owner and repo are validated against a plain name class before they go
---     into a URL, and every message that quotes the remote is cleaned
---     (`text`): a `$VAR` in the path would be expanded by the opener, an ESC
---     would reach the screen.

local remote = require("lib.nvim.git.remote")
local repos = require("gitsuite.util.repos")
local text = require("gitsuite.features.plugins.text")

local M = {}

---An owner/namespace (`a`, `a/b/c` for GitLab subgroups) or a repo name:
---letters, digits, `.`, `_`, `-` only.
---@param s string
---@param allow_slash boolean
---@return boolean
local function plain_name(s, allow_slash)
  if s == "" or (not allow_slash and s:find("/", 1, true)) then return false end
  for segment in (s .. "/"):gmatch("(.-)/") do
    if segment == "" or segment == "." or segment == ".." or not segment:match("^[%w._-]+$") then
      return false
    end
  end
  return true
end

---The forge the clone at `dir` was cloned from.
---@param dir string
---@return { kind: "github"|"gitlab"|"codeberg", remote: { host: string, owner: string, repo: string } }|nil
---@return string|nil err
function M.forge(dir)
  local url = repos.origin_url(dir)
  if not url then return nil, "no 'origin' remote" end
  local parsed = remote.parse_remote(url)
  if not parsed then return nil, "could not parse the remote URL: " .. text.one_line(url) end
  if not plain_name(parsed.owner, true) or not plain_name(parsed.repo, false) then
    return nil,
      "the remote's owner or repository name has unusual characters: " .. text.one_line(url)
  end
  local kind = remote.host_kind(parsed.host, require("gitsuite.config").get().browse.hosts)
  if not kind then
    return nil,
      ("unrecognized host '%s' -- add it to browse.hosts in setup()"):format(
        text.one_line(parsed.host)
      )
  end
  return { kind = kind, remote = parsed }, nil
end

---The web page of one commit.
---@param dir string
---@param sha string
---@return string|nil url
---@return string|nil err
function M.commit_url(dir, sha)
  if type(sha) ~= "string" or not sha:match("^%x+$") then return nil, "not a commit hash" end
  local forge, err = M.forge(dir)
  if not forge then return nil, err end
  return remote.commit_url(forge.kind, forge.remote, sha), nil
end

---Open a URL with the system's default application. Hands the URL over and
---returns; whether a browser then shows it is the system's business.
---@param url string
---@return boolean ok
---@return string|nil err
function M.open(url)
  return require("lib.nvim.cross.open_default")(url)
end

return M
