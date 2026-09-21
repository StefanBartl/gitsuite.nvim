---@module 'gitsuite.features.blame'
--- Native blame: `line` (one-shot notify), `toggle` (persistent current-line
--- virtual text), `full` (scroll-synced blame split). No adapter needed --
--- `lib.nvim.git.blame_porcelain` (added alongside this feature, see
--- lib.nvim's git_spec.lua) covers all three.

local git = require("lib.nvim.git")
local notify = require("gitsuite.util.notify")

local M = {}

local NS = vim.api.nvim_create_namespace("gitsuite_blame")

---@internal
--- `-C <dir>` plus a dir-relative path lets every call below skip repo-root
--- math entirely: git resolves `path` relative to `dir` once cwd is switched
--- there, whether or not `dir` itself is the repo root.
---@param bufnr integer
---@return string|nil dir
---@return string|nil rel_path
local function file_location(bufnr)
  local abspath = vim.api.nvim_buf_get_name(bufnr)
  if abspath == "" then return nil, nil end
  return vim.fs.dirname(abspath), vim.fs.basename(abspath)
end

---@internal
---@param entry Lib.Git.BlameEntry
---@return string
local function format_entry(entry)
  if entry.sha:match("^0+$") then return "uncommitted" end
  local short_sha = entry.sha:sub(1, 8)
  local date = entry.author_time and os.date("%Y-%m-%d", entry.author_time) or "?"
  return ("%s %s %-15s %s"):format(short_sha, date, entry.author or "?", entry.summary or "")
end

---@internal
---@param entries Lib.Git.BlameEntry[]
---@param lnum integer
---@return Lib.Git.BlameEntry|nil
local function pick_line(entries, lnum)
  for _, entry in ipairs(entries) do
    if entry.line == lnum then return entry end
  end
  return entries[1]
end

---Blame one line of a file, without any buffer: who last changed line `lnum`
---of `path` (relative to `dir`, or absolute), in the repo containing `dir`.
---
---Without `cb` the call blocks and returns `entry, err`; with `cb` it runs
---asynchronously, returns the job handle and calls `cb(entry, err)` from the
---main loop. In both forms: `entry` is nil with `err` nil when git has no data
---for the line (empty range), and nil with `err` set when blame failed (not a
---repo, untracked file, line past the end) or the arguments are invalid.
---An uncommitted line comes back with an all-zero `sha`.
---@overload fun(dir: string|nil, path: string, lnum: integer): Lib.Git.BlameEntry|nil, string|nil
---@param dir string|nil Directory to run git in (`git -C`); nil = the cwd.
---@param path string
---@param lnum integer 1-based
---@param cb fun(entry: Lib.Git.BlameEntry|nil, err: string|nil)
---@return { stop: fun() } handle
function M.for_location(dir, path, lnum, cb)
  if
    type(path) ~= "string"
    or path == ""
    or type(lnum) ~= "number"
    or lnum < 1
    or lnum % 1 ~= 0
  then
    local err = "invalid location (need a file path and a 1-based integer line)"
    if not cb then return nil, err end
    vim.schedule(function()
      cb(nil, err)
    end)
    return { stop = function() end }
  end

  local opts = { dir = dir, first = lnum, last = lnum }
  if not cb then
    local entries, err = git.blame_porcelain(path, opts)
    if not entries then return nil, err or "git blame failed" end
    return pick_line(entries, lnum), nil
  end
  return git.blame_porcelain_async(path, opts, function(entries, err)
    if not entries then
      cb(nil, err or "git blame failed")
      return
    end
    cb(pick_line(entries, lnum), nil)
  end)
end

---Blame the current line, as a notification.
---@return nil
function M.line()
  local bufnr = vim.api.nvim_get_current_buf()
  local dir, path = file_location(bufnr)
  if not dir then
    notify.error("blame: buffer has no file")
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local entry, err = M.for_location(dir, path, lnum)
  if err then
    notify.error("blame: " .. err)
    return
  end
  if not entry then
    notify.info("blame: no data for this line")
    return
  end
  notify.info(format_entry(entry))
end

---Toggle a persistent current-line blame virtual text, refreshed on cursor
---move / buffer re-entry. Buffer-local: toggling it in one buffer never
---affects another.
---@return nil
function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()

  if vim.b[bufnr].gitsuite_blame_active then
    vim.b[bufnr].gitsuite_blame_active = nil
    local group = vim.b[bufnr].gitsuite_blame_augroup
    if group then
      pcall(vim.api.nvim_del_augroup_by_id, group)
      vim.b[bufnr].gitsuite_blame_augroup = nil
    end
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    return
  end

  vim.b[bufnr].gitsuite_blame_active = true
  local group = vim.api.nvim_create_augroup(("gitsuite_blame_%d"):format(bufnr), { clear = true })
  vim.b[bufnr].gitsuite_blame_augroup = group

  -- LUA-15/ERR-32: this refresh fires on every CursorHold/CursorHoldI/
  -- BufEnter while blame is on -- a *blocking* git call here would freeze
  -- the UI on every cursor move, so this uses the async primitive instead.
  -- `generation` guards against the out-of-order result a slower, older
  -- request could otherwise deliver after a newer one already rendered
  -- (the cursor moves again before the first request returns).
  local generation = 0

  local function refresh()
    -- LUA-13: buffer may have gone invalid between the autocmd firing and
    -- this callback running (CursorHold can be delayed by 'updatetime').
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local dir, path = file_location(bufnr)
    if not dir then return end
    local lnum = vim.api.nvim_win_get_cursor(0)[1]

    generation = generation + 1
    local this_generation = generation
    M.for_location(dir, path, lnum, function(entry)
      if this_generation ~= generation then return end
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
      if not entry then return end
      vim.api.nvim_buf_set_extmark(bufnr, NS, lnum - 1, -1, {
        virt_text = { { "  " .. format_entry(entry), "Comment" } },
        virt_text_pos = "eol",
      })
    end)
  end

  vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI", "BufEnter" }, {
    group = group,
    buffer = bufnr,
    callback = refresh,
  })
  refresh()
end

---Show blame for the whole current file in a scroll-synced split to the left.
---@return nil
function M.full()
  local bufnr = vim.api.nvim_get_current_buf()
  local dir, path = file_location(bufnr)
  if not dir then
    notify.error("blame: buffer has no file")
    return
  end
  local entries, err = git.blame_porcelain(path, { dir = dir })
  if not entries then
    notify.error("blame: " .. (err or "git blame failed"))
    return
  end

  local lines = {}
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = format_entry(entry)
  end

  local src_win = vim.api.nvim_get_current_win()
  local blame_bufnr, blame_win = require("lib.nvim.window.open_scratch_split")(
    lines,
    { split = "left", filetype = "gitsuite-blame" }
  )

  vim.wo[blame_win].wrap = false
  vim.wo[blame_win].scrollbind = true
  vim.wo[blame_win].cursorbind = true
  vim.wo[src_win].scrollbind = true
  vim.wo[src_win].cursorbind = true
  pcall(vim.api.nvim_win_set_cursor, blame_win, vim.api.nvim_win_get_cursor(src_win))

  local group =
    vim.api.nvim_create_augroup(("gitsuite_blame_full_%d"):format(blame_bufnr), { clear = true })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = blame_bufnr,
    once = true,
    callback = function()
      -- LUA-13: the source window may have closed too by the time this fires.
      if vim.api.nvim_win_is_valid(src_win) then
        vim.wo[src_win].scrollbind = false
        vim.wo[src_win].cursorbind = false
      end
    end,
  })
end

return M
