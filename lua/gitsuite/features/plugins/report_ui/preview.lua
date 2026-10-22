---@module 'gitsuite.features.plugins.report_ui.preview'
--- The file list of one commit for the report's preview: one `git diff-tree`
--- per commit, never more.
---
---   * In a partial clone (lazy.nvim clones `--filter=blob:none`) only the trees
---     are local, so only `--raw` (status and path) works offline; line counts
---     would need the contents of both sides and git would fail (it never fetches
---     here: `gitlog.run` runs without lazy fetching). In a full clone
---     `--raw --numstat` gives both in the same one process.
---   * Results are kept per `dir@sha` (LRU, `CACHE_MAX`): moving back over a
---     commit costs nothing.
---   * `request` waits `DEBOUNCE_MS` before it runs anything, so holding `j`
---     over thirty commits starts one process, not thirty, and only the newest
---     request is answered (an older answer is cached, not shown).
---
--- The SHA comes from the stored report, i.e. from a file: it is checked before
--- it reaches git.

local gitfs = require("gitsuite.features.plugins.gitfs")
local gitlog = require("gitsuite.features.plugins.gitlog")
local text = require("gitsuite.features.plugins.text")

local M = {}

M.CACHE_MAX = 200
M.DEBOUNCE_MS = 80
---Most files listed for one commit (a vendored dependency can touch thousands).
M.MAX_FILES = 500

---@class GitSuite.ReportUi.File
---@field status string   `M`, `A`, `D`, `T` ... (git's raw status letter)
---@field path string
---@field adds? integer   Lines added (full clones only)
---@field dels? integer
---@field binary? boolean A binary file (`-` counts)

---@class GitSuite.ReportUi.Files
---@field files? GitSuite.ReportUi.File[]
---@field counts boolean      Line counts were asked for and are there.
---@field partial? boolean    A partial clone: why there are no line counts.
---@field more? integer       Files not listed beyond `MAX_FILES`.
---@field error? string

---The argv after `git` for `sha`.
---@param sha string
---@param counts boolean also `--numstat`
---@return string[]
function M.args(sha, counts)
  local args = { "diff-tree", "-r", "--no-commit-id", "--root", "--raw", "-z", "--no-renames" }
  if counts then args[#args + 1] = "--numstat" end
  args[#args + 1] = sha
  return args
end

---Parse `diff-tree -r --raw [-z --numstat]` output: the raw entries (`:mode
---mode sha sha S` then the path) in order, the numstat entries (`adds TAB dels
---TAB path`, `-` for a binary file) matched to them by path. Pure.
---@param out string
---@return GitSuite.ReportUi.File[] files
---@return integer more  entries past `MAX_FILES`
function M.parse(out)
  local tokens = vim.split(out or "", "\0", { plain = true })
  local files, by_path, more = {}, {}, 0
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    if tok:sub(1, 1) == ":" then
      local status = tok:match("(%S+)$") or "?"
      local path = tokens[i + 1] or ""
      i = i + 2
      if #files < M.MAX_FILES then
        local f = { status = status:sub(1, 1), path = path }
        files[#files + 1] = f
        by_path[path] = f
      else
        more = more + 1
      end
    else
      local adds, dels, path = tok:match("^([%d%-]+)\t([%d%-]+)\t(.*)$")
      local f = path and by_path[path]
      if f then
        if adds == "-" or dels == "-" then
          f.binary = true
        else
          f.adds, f.dels = tonumber(adds), tonumber(dels)
        end
      end
      i = i + 1
    end
  end
  return files, more
end

---@class GitSuite.ReportUi.PreviewLoader
---@field cached fun(self, dir: string, sha: string): GitSuite.ReportUi.Files|nil
---@field request fun(self, dir: string, sha: string, on_done: fun(files: GitSuite.ReportUi.Files))
---@field stop fun(self)

---A loader. `opts.run(args, dir, on_done(result, err))` runs git (default
---`gitlog.run`, the read-only runner), `opts.partial(dir)` tells a partial
---clone (default `gitfs.partial_clone`), `opts.defer(fn, ms)` waits (default
---`vim.defer_fn`; a spec can make it immediate).
---@param opts? table See above (run, partial, defer).
---@return GitSuite.ReportUi.PreviewLoader
function M.new(opts)
  opts = opts or {}
  local run = opts.run or gitlog.run
  local partial_of = opts.partial or gitfs.partial_clone
  local defer = opts.defer or vim.defer_fn

  local cache, order = {}, {}
  local token = 0
  local running

  local function key(dir, sha)
    return dir .. "@" .. sha
  end

  local function put(k, v)
    if cache[k] == nil then
      order[#order + 1] = k
      if #order > M.CACHE_MAX then cache[table.remove(order, 1)] = nil end
    end
    cache[k] = v
  end

  local L = {}

  function L:cached(dir, sha)
    return cache[key(dir, sha)]
  end

  function L:stop()
    token = token + 1
    if running then pcall(running.stop) end
    running = nil
  end

  function L:request(dir, sha, on_done)
    token = token + 1
    local mine = token
    local k = key(dir, sha)
    if cache[k] then return on_done(cache[k]) end
    if not gitfs.valid_sha(sha) then
      local bad = { counts = false, error = "not a commit hash" }
      put(k, bad)
      return on_done(bad)
    end
    defer(function()
      -- A newer request came in while this one waited: it never runs.
      if mine ~= token then return end
      local partial = partial_of(dir) == true
      local counts = not partial
      running = run(M.args(sha, counts), dir, function(res, err)
        running = nil
        local v
        if err or not res or res.code ~= 0 then
          local why = err or (res and vim.trim(tostring(res.stderr or ""))) or ""
          why = text.one_line((why:match("[^\n]*$") or why))
          v = {
            counts = false,
            error = why ~= "" and ("not available locally (" .. why .. ")")
              or "not available locally",
          }
        else
          local files, more = M.parse(res.stdout)
          v = {
            files = files,
            more = more > 0 and more or nil,
            counts = counts,
            partial = partial or nil,
          }
        end
        put(k, v)
        -- Cached either way; shown only if nothing newer was asked for since.
        if mine == token then on_done(v) end
      end)
    end, M.DEBOUNCE_MS)
  end

  return L
end

return M
