---@module 'gitsuite.features.ui.lazygit'
--- lazygit float: spawns the real `lazygit` binary in a floating terminal.
--- Replaces kdheepak/lazygit.nvim's wrapper entirely -- the UI itself stays
--- exactly lazygit's own TUI (the part that was worth keeping), only the
--- Neovim-side float/spawn/bridge is gitsuite.nvim's own.
---
--- `GitsuiteLazygitBadd`/`GitsuiteLazygitReplace` are lazygit's `O`/`<C-o>`
--- custom-command targets, called via `nvr` from *inside* lazygit's own
--- process -- see docs/lazygit-config.yml. They are flat commands outside
--- the `:Git` tree on purpose: lazygit's config.yml embeds their exact
--- name, so nesting them under `:Git` would mean users editing a config
--- file most of them never touch, for no benefit (nothing about these two
--- commands is ever typed by a person).

local notify = require("gitsuite.util.notify")
local usercmd = require("lib.nvim.bindings.usercmd")

local M = {}

---@internal
--- DEP-02: `jobstart(argv, {term=true})`, never `termopen()` (deprecated).
--- `argv` is a plain list (SEC-01: no shell string) -- lazygit itself IS
--- the program here, so unlike a general terminal helper there is no
--- Windows "keep the shell open" concern (XP-04): there is no intermediate
--- shell to keep open, only the lazygit process itself, and its own exit
--- is what should close the float (see `on_exit` below).
---@param repo_dir string
---@return string[]
local function build_argv(repo_dir)
  return { "lazygit", "-p", repo_dir }
end

---@internal
---@param bufnr integer
local function setup_terminal_keymaps(bufnr)
  vim.keymap.set(
    "t",
    "<Esc>",
    [[<C-\><C-n>]],
    { buffer = bufnr, silent = true, desc = "[gitsuite] Exit terminal mode" }
  )
  vim.keymap.set(
    "n",
    "q",
    "<Cmd>close<CR>",
    { buffer = bufnr, silent = true, desc = "[gitsuite] Close lazygit" }
  )
end

---Open lazygit in a floating terminal, rooted at the current file's repo
---(or the cwd's repo, for a buffer with no file).
---@return nil
function M.open()
  if vim.fn.executable("lazygit") ~= 1 then
    notify.error(
      'ui lazygit: the "lazygit" executable is not on $PATH -- see https://github.com/jesseduffield/lazygit#installation'
    )
    return
  end

  local git = require("lib.nvim.git")
  if not git.in_git_repo() then
    notify.error("ui lazygit: not inside a git repository")
    return
  end
  local repo_dir = git.repo_root() or vim.fn.getcwd()

  local width = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.9)
  local row = math.floor((vim.o.lines - height) / 2 - 1)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = vim.api.nvim_create_buf(false, true)
  local ok_win, winid = pcall(vim.api.nvim_open_win, bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    style = "minimal",
    title = " lazygit ",
    title_pos = "center",
  })
  if not ok_win then
    notify.error("ui lazygit: failed to open the float")
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return
  end

  local job_id = vim.fn.jobstart(build_argv(repo_dir), {
    term = true,
    cwd = repo_dir,
    on_exit = function()
      vim.schedule(function()
        -- LUA-13: the window may already be gone (closed by hand) by the
        -- time this runs.
        if vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_close(winid, true) end
      end)
    end,
  })
  -- jobstart() returns 0 (invalid arguments) or -1 (not executable) on a
  -- SYNCHRONOUS failure -- on_exit above never fires for either, so without
  -- this check the float is left open around a dead terminal with no error
  -- and no way to close it via the terminal-mode keymaps below (they are
  -- still bound, but there is no shell to send <Esc> to).
  if job_id <= 0 then
    notify.error("ui lazygit: failed to start the lazygit process")
    pcall(vim.api.nvim_win_close, winid, true)
    return
  end

  setup_terminal_keymaps(bufnr)
  vim.cmd("startinsert")
end

---Register the nvr bridge commands. Idempotent; called once from
---`bindings.register`.
---@return nil
function M.setup()
  if vim.fn.executable("nvr") == 0 then
    notify.warn(
      "lazygit: nvr not found on $PATH -- lazygit's O/<C-o> need neovim-remote (pip install neovim-remote)"
    )
  end

  usercmd.create("GitsuiteLazygitBadd", function(opts)
    require("gitsuite.features.ui.lazygit.badd").run(opts.args)
  end, {
    nargs = 1,
    desc = "[gitsuite] Add file to buffer list (called via nvr from lazygit)",
  })

  usercmd.create("GitsuiteLazygitReplace", function(opts)
    require("gitsuite.features.ui.lazygit.replace").run(opts.args)
  end, {
    nargs = 1,
    desc = "[gitsuite] Replace visible editor buffer with file (called via nvr from lazygit)",
  })
end

return M
