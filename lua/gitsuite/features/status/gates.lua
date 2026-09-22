---@module 'gitsuite.features.status.gates'
--- `:Git status todos|lint|spell` -- pre-commit-style gates over the
--- currently changed files (`git status`), not the whole tree.
---
--- Two real constraints shape what each gate can actually check (verified
--- against real usage before writing this, not assumed):
---
--- 1. **LSP diagnostics only exist for a LOADED buffer** -- there is no way
---    to ask a language server "what would you say about this file" without
---    opening it and waiting for a client to attach and publish. `lint`
---    checks whichever changed files already have a loaded buffer and says
---    how many it had to skip, rather than pretending to be a full
---    pre-commit linter.
--- 2. **`insights.todos.scan()` is a whole-tree ripgrep pass, not a
---    file-list query** -- there is no insights.nvim API to scan just N
---    files. `todos` runs the normal whole-tree scan and filters its
---    results down to the changed set afterwards; ripgrep is fast enough
---    that the extra work is not worth a new insights.nvim API for this.
---
--- `spell`, unlike the other two, needs neither: `vim.spell.check()` works
--- on plain text via `'spelllang'`, so it reads each changed file's
--- on-disk content directly (`vim.fn.readfile`) -- exactly what would be
--- committed, not a possibly-unsaved buffer.

local git = require("lib.nvim.git")
local notify = require("gitsuite.util.notify")

local M = {}

---@internal
---Absolute paths of every changed file `git status` reports, except
---deletions (there is nothing left on disk to check).
---@return string[]|nil paths
---@return string|nil err
local function changed_files()
  if not git.in_git_repo() then return nil, "not inside a git repository" end
  local status = git.status_porcelain()
  if not status then return nil, "nothing to report (clean working tree, or not a git repo)" end
  local root = git.repo_root()
  if not root then return nil, "could not resolve the repository root" end

  local paths = {}
  for path, entry in pairs(status) do
    if entry.code:sub(1, 1) ~= "D" and entry.code:sub(2, 2) ~= "D" then
      paths[#paths + 1] = vim.fs.normalize(vim.fs.joinpath(root, path))
    end
  end
  table.sort(paths)
  return paths, nil
end

---@internal
---@param items table[] quickfix-shaped items
---@param title string
local function show_quickfix(items, title)
  vim.fn.setqflist({}, "r", { title = title, items = items })
  vim.cmd("copen")
end

---Pre-commit gate: TODO/FIXME/... annotations in the changed files only,
---via insights.nvim (optional soft dep).
---@return nil
function M.todos()
  local paths, err = changed_files()
  if not paths then
    notify.info("status: todos: " .. err)
    return
  end
  if #paths == 0 then
    notify.info("status: todos: no changed files to check")
    return
  end

  local ok_req, insights_todos = pcall(require, "insights.todos")
  if not ok_req then
    notify.error(
      'status: todos: insights.nvim is not installed -- install "StefanBartl/insights.nvim" to use :Git status todos'
    )
    return
  end

  local root = git.repo_root()
  local entries, scan_err = insights_todos.scan({ cwd = root })
  if scan_err then
    notify.error("status: todos: scan failed: " .. scan_err)
    return
  end

  local wanted = {}
  for _, p in ipairs(paths) do
    wanted[p] = true
  end

  local items = {}
  for _, e in ipairs(entries) do
    local abs = vim.fs.normalize(e.filename)
    if not wanted[abs] then
      -- insights.todos.scan() reports paths as ripgrep echoed them back for
      -- the given search root; fall back to joining onto the repo root in
      -- case a future insights.nvim version starts reporting root-relative
      -- paths instead of the absolute ones the current one does.
      abs = vim.fs.normalize(vim.fs.joinpath(root, e.filename))
    end
    if wanted[abs] then
      items[#items + 1] = {
        filename = abs,
        lnum = e.lnum,
        col = e.col,
        text = ("[%s] %s"):format(e.keyword, e.text),
      }
    end
  end

  if #items == 0 then
    notify.info("status: todos: none in the changed files")
    return
  end
  show_quickfix(items, "gitsuite: status todos")
end

---Pre-commit gate: LSP diagnostics for the changed files that already have
---a loaded buffer. Files with no loaded buffer are counted, not silently
---dropped -- see the module doc for why they cannot be checked at all.
---@return nil
function M.lint()
  local paths, err = changed_files()
  if not paths then
    notify.info("status: lint: " .. err)
    return
  end
  if #paths == 0 then
    notify.info("status: lint: no changed files to check")
    return
  end

  local diagnostics = {}
  local skipped = 0
  for _, path in ipairs(paths) do
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      vim.list_extend(diagnostics, vim.diagnostic.get(bufnr))
    else
      skipped = skipped + 1
    end
  end

  if #diagnostics == 0 then
    if skipped > 0 then
      notify.info(
        ("status: lint: no diagnostics in the %d open changed file(s) -- %d changed file(s) skipped (not open, so no LSP diagnostics available)"):format(
          #paths - skipped,
          skipped
        )
      )
    else
      notify.info("status: lint: no diagnostics in the changed files")
    end
    return
  end

  show_quickfix(vim.diagnostic.toqflist(diagnostics), "gitsuite: status lint")
  if skipped > 0 then
    notify.warn(
      ("status: lint: %d changed file(s) skipped -- not open, so no LSP diagnostics available"):format(
        skipped
      )
    )
  end
end

---@internal
---Git's own binary heuristic: a NUL byte in the first 8000 bytes. `changed_files()`
---has no reason to exclude a binary file (an image, a lockfile-adjacent
---blob) from the *set* of changed paths, but spell-checking one wastes work
---and floods the quickfix list with noise from bytes that were never text.
---@param path string
---@return boolean
local function looks_binary(path)
  local fh = io.open(path, "rb")
  if not fh then return false end
  local chunk = fh:read(8000) or ""
  fh:close()
  return chunk:find("\0", 1, true) ~= nil
end

---Pre-commit gate: misspellings (`vim.spell.check`, current `'spelllang'`)
---in the changed files' on-disk content. Binary files (see `looks_binary`)
---are skipped, not read as text.
---@return nil
function M.spell()
  local paths, err = changed_files()
  if not paths then
    notify.info("status: spell: " .. err)
    return
  end
  if #paths == 0 then
    notify.info("status: spell: no changed files to check")
    return
  end

  local items = {}
  for _, path in ipairs(paths) do
    local ok_read, lines
    if not looks_binary(path) then
      ok_read, lines = pcall(vim.fn.readfile, path)
    end
    if ok_read and type(lines) == "table" then
      for lnum, line in ipairs(lines) do
        local ok_check, bad = pcall(vim.spell.check, line)
        if ok_check then
          for _, w in ipairs(bad) do
            if w[2] == "bad" then
              items[#items + 1] = { filename = path, lnum = lnum, col = w[3], text = w[1] }
            end
          end
        end
      end
    end
  end

  if #items == 0 then
    notify.info("status: spell: no misspellings in the changed files")
    return
  end
  show_quickfix(items, "gitsuite: status spell")
end

return M
