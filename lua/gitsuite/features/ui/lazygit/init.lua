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

---@internal
--- The directory lazygit is rooted at: the repo containing `repo_dir` or,
--- without one, the repo of the current cwd.
---@param repo_dir string|nil
---@return string|nil root
---@return string|nil err
local function resolve_repo_dir(repo_dir)
  local git = require("lib.nvim.git")

  if repo_dir == nil or repo_dir == "" then
    if not git.in_git_repo() then return nil, "not inside a git repository" end
    return git.repo_root() or vim.fn.getcwd()
  end

  local dir = vim.fs.normalize(repo_dir)
  local stat = vim.uv.fs_stat(dir)
  if not stat or stat.type ~= "directory" then return nil, "not a directory: " .. repo_dir end
  if not git.in_git_repo({ dir = dir }) then
    return nil, "not inside a git repository: " .. repo_dir
  end
  return git.repo_root({ dir = dir }) or dir
end

---@internal
--- terminal.nvim's facade when it is installed and new enough to offer
--- `run(argv, { direct = true })`; nil otherwise (optional dependency, the
--- own float below is the fallback).
---@return table|nil
local function terminal_facade()
  local ok, term = pcall(require, "terminal")
  if ok and type(term) == "table" and type(term.run) == "function" then return term end
  return nil
end

---@internal
--- Start lazygit through terminal.nvim: it owns the float, the job, the
--- exit handling (`close = "always"`) and the identity (a second
--- `:Git ui lazygit` replaces the earlier one instead of stacking floats).
--- A failure is reported by terminal.nvim itself, so nothing is added here.
---@param term table terminal.nvim's facade
---@param root string repo root
---@return nil
local function open_via_terminal(term, root)
  ---@type table<string, string>|nil
  local env
  -- The `nvr` bridge (O/<C-o>) needs $NVIM. A native terminal gets it from
  -- Neovim anyway; a multiplexer pane (tmux/WezTerm backend) does not.
  if vim.v.servername ~= "" then env = { NVIM = vim.v.servername } end
  term.run(build_argv(root), {
    direct = true,
    name = "lazygit",
    title = "lazygit",
    cwd = root,
    layout = "float",
    float = { width = 0.9, height = 0.9 },
    close = "always",
    env = env,
    on_open = function(handle)
      -- Multiplexer backends have no Neovim buffer to map keys in.
      local bufnr = type(handle) == "table" and handle.bufnr or nil
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then setup_terminal_keymaps(bufnr) end
    end,
  })
end

---@internal
--- Fallback without terminal.nvim: an own float around `jobstart`.
---@param repo_dir string repo root
---@return nil
local function open_own_float(repo_dir)
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

---Open lazygit in a floating terminal. Without `repo_dir` it is rooted at the
---repo of the current cwd; with one, at the repo containing that directory
---(any subdirectory of a work tree works, not only its root). With
---terminal.nvim installed the float is terminal.nvim's
---(`require("terminal").run(argv, { direct = true })`); without it,
---gitsuite.nvim's own.
---@param repo_dir? string
---@return nil
function M.open(repo_dir)
  if vim.fn.executable("lazygit") ~= 1 then
    notify.error(
      'ui lazygit: the "lazygit" executable is not on $PATH -- see https://github.com/jesseduffield/lazygit#installation'
    )
    return
  end

  local root, err = resolve_repo_dir(repo_dir)
  if not root then
    notify.error("ui lazygit: " .. err)
    return
  end

  local term = terminal_facade()
  if term then
    open_via_terminal(term, root)
    return
  end
  open_own_float(root)
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
    complete = "file",
    desc = "[gitsuite] Add file to buffer list (called via nvr from lazygit)",
  })

  usercmd.create("GitsuiteLazygitReplace", function(opts)
    require("gitsuite.features.ui.lazygit.replace").run(opts.args)
  end, {
    nargs = 1,
    complete = "file",
    desc = "[gitsuite] Replace visible editor buffer with file (called via nvr from lazygit)",
  })
end

return M
