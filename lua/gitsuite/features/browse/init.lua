---@module 'gitsuite.features.browse'
--- `:Git browse file|selection|repo` -- open the current file/selection/repo
--- on its web host (GitHub, GitLab, Codeberg, or a self-hosted instance
--- declared in `cfg.browse.hosts`). Replaces vim-rhubarb's `:Gbrowse`
--- entirely.
---
--- reposcope.nvim has no file->web-URL mapping to reuse (only hardcoded
--- README-fetch URLs, see README.md) -- the parsing/building logic in
--- `url.lua` is new code. open.nvim is an optional dependency of THIS
--- feature only (LUA-05): gitsuite.nvim as a whole stays usable without it,
--- only `:Git browse *` degrades to a clear error.
---
--- This file is the impure shell (buffer/cursor reads, the actual git
--- calls, opening the browser) around `url.lua`'s pure parsing/building.

local git = require("lib.nvim.git")
local url = require("gitsuite.features.browse.url")
local notify = require("gitsuite.util.notify")

local M = {}

---@internal
---@param bufnr integer
---@return string|nil dir
---@return string|nil basename
local function file_location(bufnr)
  local abspath = vim.api.nvim_buf_get_name(bufnr)
  if abspath == "" then return nil, nil end
  return vim.fs.dirname(abspath), vim.fs.basename(abspath)
end

---@internal
--- Resolve remote/host/branch/relative-path for the current buffer.
--- Every failure reason is distinct (ERR-10/11) so the caller can say
--- exactly what went wrong instead of one generic "browse failed".
---@param bufnr integer
---@return { kind: "github"|"gitlab"|"codeberg", remote: { host: string, owner: string, repo: string }, branch: string, rel_path: string }|nil
---@return string|nil err
local function resolve(bufnr)
  local cfg = require("gitsuite.config").get()
  local dir, basename = file_location(bufnr)
  if not dir then return nil, "buffer has no file" end

  local remote_url = git.remote_url("origin", { dir = dir })
  if not remote_url then return nil, "no 'origin' remote" end
  local remote = url.parse_remote(remote_url)
  if not remote then return nil, "could not parse remote URL: " .. remote_url end

  local kind = url.host_kind(remote.host, cfg.browse.hosts)
  if not kind then
    return nil, ("unrecognized host '%s' -- add it to browse.hosts in setup()"):format(remote.host)
  end

  -- current_ref, not info(dir): info() always pays for a third, unused
  -- `git describe --tags --always` call on top of the two (branch/commit)
  -- actually needed here.
  local branch = git.current_ref(dir)
  if not branch then return nil, "could not determine a branch or commit to link against" end

  local rel_path = git.relative_path(basename, { dir = dir })
  if not rel_path then return nil, "file is not tracked by git" end

  return { kind = kind, remote = remote, branch = branch, rel_path = rel_path }, nil
end

---@internal
---@param web_url string
local function open_url(web_url)
  local ok_req, open_registry = pcall(require, "open.registry")
  if not ok_req then
    notify.error(
      'browse: open.nvim is not installed -- install "StefanBartl/open.nvim" to use :Git browse'
    )
    return
  end
  local ok, dispatch_err = open_registry.dispatch("browser", {
    text = web_url,
    is_url = true,
    is_path = false,
  })
  if not ok then notify.error("browse: " .. (dispatch_err or "could not open a browser")) end
end

---Open the current file on its web host (no line anchor).
---@return nil
function M.file()
  local r, err = resolve(vim.api.nvim_get_current_buf())
  if not r then
    notify.error("browse: " .. err)
    return
  end
  open_url(url.build(r.kind, r.remote, r.branch, r.rel_path))
end

---Open the current visual selection (line range from the `'<`/`'>` marks)
---on its web host.
---@return nil
function M.selection()
  local r, err = resolve(vim.api.nvim_get_current_buf())
  if not r then
    notify.error("browse: " .. err)
    return
  end

  local first = vim.fn.getpos("'<")[2]
  local last = vim.fn.getpos("'>")[2]
  if first == 0 or last == 0 then
    notify.error('browse: no visual selection ("\'<"/"\'>" not set)')
    return
  end
  if first > last then
    first, last = last, first
  end

  open_url(url.build(r.kind, r.remote, r.branch, r.rel_path, first, last))
end

---Open the repository root on its web host.
---@return nil
function M.repo()
  local r, err = resolve(vim.api.nvim_get_current_buf())
  if not r then
    notify.error("browse: " .. err)
    return
  end
  open_url(url.build(r.kind, r.remote, r.branch, nil))
end

return M
