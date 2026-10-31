-- TESTS/gitsuite/editor_scope.lua -- puts the editor's layout back after each test: the tab pages,
-- windows and buffers a test created are closed and wiped, the window it started in shows its
-- buffer again. Not a spec (no `_spec` suffix): a spec loads it with
--
--   local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
--   local editor_scope = dofile(dir_of_spec .. "editor_scope.lua")
--
-- and calls `editor_scope.install()` once at the top of each top-level `describe`. Its
-- `before_each` runs before the tests' own, its `after_each` after theirs, so a test that cleans up
-- by hand is not affected; one that throws halfway no longer leaves its windows behind.
--
-- One thing it cannot undo: `:edit {file}` in the start window's empty, unnamed buffer reuses that
-- buffer (Vim's `curbuf_reusable()`), so wiping the file buffer later leaves the window a fresh
-- `[No Name]`. A test that edits a real file opens it with `editor_scope.open_file()` instead.
local M = {}

---@param list integer[]
---@return table<integer, boolean>
local function set_of(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

---Open `path` in the current window in a buffer of its own (never the reused start buffer).
---@param path string
---@return integer bufnr
function M.open_file(path)
  local bufnr = vim.fn.bufadd(path)
  vim.bo[bufnr].buflisted = true
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

---@type table|nil  What the editor looked like when the running test started.
local snap

---Put the editor back as the running test found it: close the tab pages and windows it opened,
---show the start buffer in the start window again, wipe every buffer created since. Runs after
---each test; a test that needs a clean slate halfway (open a second file on its own) calls it too.
function M.restore()
  local s = snap
  if not s then return end
  if vim.api.nvim_tabpage_is_valid(s.tab) then pcall(vim.api.nvim_set_current_tabpage, s.tab) end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if not s.tabs[tab] and #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd.tabclose, { args = { vim.api.nvim_tabpage_get_number(tab) }, bang = true })
    end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not s.wins[win] and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_set_current_win, s.win)
    if vim.api.nvim_buf_is_valid(s.buf) then pcall(vim.api.nvim_win_set_buf, s.win, s.buf) end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not s.bufs[buf] then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
end

---Register the snapshot (`before_each`) and the clean-up (`after_each`) for the enclosing describe.
function M.install()
  before_each(function()
    snap = {
      bufs = set_of(vim.api.nvim_list_bufs()),
      wins = set_of(vim.api.nvim_list_wins()),
      tabs = set_of(vim.api.nvim_list_tabpages()),
      tab = vim.api.nvim_get_current_tabpage(),
      win = vim.api.nvim_get_current_win(),
      buf = vim.api.nvim_get_current_buf(),
    }
  end)

  after_each(function()
    M.restore()
    snap = nil
  end)
end

return M
