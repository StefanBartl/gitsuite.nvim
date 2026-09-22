---@module 'gitsuite.bindings.usrcmds'
--- Registers the `:Git` compound command via `lib.nvim.bindings.usercmd.composer`
--- (UI-21, PRIN-07 "Ein Dispatch-Nadelöhr"/SSOT). One route tree drives
--- dispatch, `<Tab>` completion and generated docs at once -- see
--- `docs/BINDINGS.md`.
---
--- Every route covers a scope from the old, scattered surface this plugin
--- replaces (git-conflict.nvim's nine commands, vim-fugitive's
--- `:Git blame`, vim-rhubarb's `:Gbrowse`, diffview's/neogit's/lazygit's
--- launchers -- see gitsuite.nvim's README): every historical entry point
--- onto exactly one name.

local composer = require("lib.nvim.bindings.usercmd.composer")

local M = {}

---@internal
---@return table[] routes
local function build_routes()
  return {
    -- conflict: buffer-local merge-conflict resolution (own implementation)
    {
      path = { "conflict", "ours" },
      desc = "Resolve the conflict under the cursor: keep ours",
      run = function()
        require("gitsuite.features.conflict").choose("ours")
      end,
    },
    {
      path = { "conflict", "theirs" },
      desc = "Resolve the conflict under the cursor: keep theirs",
      run = function()
        require("gitsuite.features.conflict").choose("theirs")
      end,
    },
    {
      path = { "conflict", "both" },
      desc = "Resolve the conflict under the cursor: keep both",
      run = function()
        require("gitsuite.features.conflict").choose("both")
      end,
    },
    {
      path = { "conflict", "base" },
      desc = "Resolve the conflict under the cursor: keep the common ancestor (diff3/zdiff3 only)",
      run = function()
        require("gitsuite.features.conflict").choose("base")
      end,
    },
    {
      path = { "conflict", "none" },
      desc = "Resolve the conflict under the cursor: keep neither",
      run = function()
        require("gitsuite.features.conflict").choose("none")
      end,
    },
    {
      path = { "conflict", "next" },
      desc = "Jump to the next conflict marker in this buffer",
      run = function()
        require("gitsuite.features.conflict").next()
      end,
    },
    {
      path = { "conflict", "prev" },
      desc = "Jump to the previous conflict marker in this buffer",
      run = function()
        require("gitsuite.features.conflict").prev()
      end,
    },
    {
      path = { "conflict", "list" },
      desc = "List every file with unresolved conflicts in the quickfix list",
      run = function()
        require("gitsuite.features.conflict").list()
      end,
    },
    {
      path = { "conflict", "refresh" },
      desc = "Re-scan the current buffer for conflict markers",
      run = function()
        require("gitsuite.features.conflict").refresh()
      end,
    },

    -- hunk: delegated to the gitsigns adapter (Schicht 3, never nachbauen)
    {
      path = { "hunk", "stage" },
      desc = "Stage the hunk under the cursor",
      run = function()
        require("gitsuite.features.hunk").stage()
      end,
    },
    {
      path = { "hunk", "reset" },
      desc = "Reset the hunk under the cursor",
      run = function()
        require("gitsuite.features.hunk").reset()
      end,
    },
    {
      path = { "hunk", "preview" },
      desc = "Preview the hunk under the cursor",
      run = function()
        require("gitsuite.features.hunk").preview()
      end,
    },
    {
      path = { "hunk", "stage-buffer" },
      desc = "Stage every hunk in the current buffer",
      run = function()
        require("gitsuite.features.hunk").stage_buffer()
      end,
    },
    {
      path = { "hunk", "reset-buffer" },
      desc = "Reset every hunk in the current buffer",
      run = function()
        require("gitsuite.features.hunk").reset_buffer()
      end,
    },
    {
      path = { "hunk", "toggle-deleted" },
      desc = "Toggle showing deleted lines inline",
      run = function()
        require("gitsuite.features.hunk").toggle_deleted()
      end,
    },
    {
      path = { "hunk", "inline" },
      desc = "Toggle inline diff: invert word_diff & linehl, preview current hunk inline",
      run = function()
        require("gitsuite.features.hunk").inline()
      end,
    },

    -- blame: own implementation, native `git blame --porcelain`
    {
      path = { "blame", "line" },
      desc = "Show blame for the current line",
      run = function()
        require("gitsuite.features.blame").line()
      end,
    },
    {
      path = { "blame", "toggle" },
      desc = "Toggle current-line blame virtual text",
      run = function()
        require("gitsuite.features.blame").toggle()
      end,
    },
    {
      path = { "blame", "full" },
      desc = "Show full blame for the current file",
      run = function()
        require("gitsuite.features.blame").full()
      end,
    },

    -- diff: thin alias onto diff.nvim's :Diff
    {
      path = { "diff", "head" },
      desc = "Diff the current file against HEAD",
      run = function()
        require("gitsuite.features.diff").head()
      end,
    },
    {
      path = { "diff", "last" },
      desc = "Diff the current file against the previous commit",
      run = function()
        require("gitsuite.features.diff").last()
      end,
    },
    {
      path = { "diff", "rev" },
      args = { { name = "rev", type = "STRING" } },
      desc = "Diff the current file against an arbitrary revision",
      run = function(ctx)
        require("gitsuite.features.diff").rev(ctx.args.rev)
      end,
    },
    {
      path = { "diff", "split" },
      desc = "Open the diff view",
      run = function()
        require("gitsuite.features.diff").split()
      end,
    },
    {
      path = { "diff", "history" },
      desc = "Show file history (diff.nvim :DiffHistory)",
      run = function()
        require("gitsuite.features.diff").history()
      end,
    },
    {
      path = { "diff", "close" },
      desc = "Close every open diff view and leave diff mode (diff.nvim :DiffClear)",
      run = function()
        require("gitsuite.features.diff").close()
      end,
    },

    -- branch: extracted from ui.nvim's git_clickable statusline module
    {
      path = { "branch", "switch" },
      desc = "Switch to another local branch",
      run = function()
        require("gitsuite.features.branch").switch()
      end,
    },
    {
      path = { "branch", "list" },
      desc = "List local branches",
      run = function()
        require("gitsuite.features.branch").list()
      end,
    },
    {
      path = { "branch", "current" },
      desc = "Show the current branch",
      run = function()
        require("gitsuite.features.branch").current()
      end,
    },

    -- browse: remote-URL resolution for GitHub/GitLab/Codeberg
    {
      path = { "browse", "file" },
      desc = "Open the current file on its web host",
      run = function()
        require("gitsuite.features.browse").file()
      end,
    },
    {
      path = { "browse", "selection" },
      desc = "Open the current visual selection (with line range) on its web host",
      run = function()
        require("gitsuite.features.browse").selection()
      end,
    },
    {
      path = { "browse", "repo" },
      desc = "Open the repository root on its web host",
      run = function()
        require("gitsuite.features.browse").repo()
      end,
    },

    -- ui: TUI launchers -- lazygit float owned by gitsuite, neogit/diffview are thin adapters
    {
      path = { "ui", "lazygit" },
      args = { { name = "dir", type = "DIR", optional = true } },
      desc = "Open lazygit in a floating terminal (optionally for the repo containing <dir>)",
      run = function(ctx)
        require("gitsuite.features.ui").lazygit(ctx.args.dir)
      end,
    },
    {
      path = { "ui", "neogit" },
      desc = "Open neogit",
      run = function()
        require("gitsuite.features.ui").neogit()
      end,
    },
    {
      path = { "ui", "diffview", "open" },
      desc = "Open diffview",
      run = function()
        require("gitsuite.features.ui").diffview_open()
      end,
    },
    {
      path = { "ui", "diffview", "close" },
      desc = "Close the current diffview",
      run = function()
        require("gitsuite.features.ui").diffview_close()
      end,
    },

    -- status: lib.nvim.git.status_porcelain
    {
      path = { "status", "repo" },
      desc = "Show repo status (branch, ahead/behind, dirty)",
      run = function()
        require("gitsuite.features.status").repo()
      end,
    },
    {
      path = { "status", "quickfix" },
      desc = "Export repo status to the quickfix list",
      run = function()
        require("gitsuite.features.status").quickfix()
      end,
    },
  }
end

---Register `:Git` (or the configured command name) with the full route tree.
---Idempotent at the nvim level (re-creates cleanly).
---@param cfg GitSuite.Config
function M.register(cfg)
  composer.verb(cfg.commands.git, {
    desc = "[gitsuite.nvim] :" .. cfg.commands.git .. " <scope> <action> -- see docs/BINDINGS.md",
    routes = build_routes(),
  })
end

return M
