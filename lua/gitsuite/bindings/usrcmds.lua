---@module 'gitsuite.bindings.usrcmds'
--- Registers the `:Git` compound command via `lib.nvim.bindings.usercmd.composer`
--- (UI-21, PRIN-07 "Ein Dispatch-Nadelöhr"/SSOT). One route tree drives
--- dispatch, `<Tab>` completion and generated docs at once -- see
--- `docs/BINDINGS.md`.
---
--- Every route currently in the tree covers a scope from the old, scattered
--- surface this plugin replaces (git-conflict.nvim's nine commands,
--- vim-fugitive's `:Git blame`, vim-rhubarb's `:Gbrowse`, diffview's/neogit's/
--- lazygit's launchers -- see gitsuite.nvim's README). `run` bodies land
--- feature by feature; until a feature module exists, its route calls the
--- shared `stub()` so the full command surface is typeable and completable
--- from day one, matching every historical entry point onto exactly one name.

local composer = require("lib.nvim.bindings.usercmd.composer")
local notify = require("gitsuite.util.notify")

local M = {}

---@internal
---Placeholder for a route whose feature has not landed yet.
---@param label string human-readable route description, e.g. "conflict ours"
---@return fun(ctx: table)
local function stub(label)
  return function(_)
    notify.info(("'%s' is not implemented yet."):format(label))
  end
end

---@internal
---@return table[] routes
local function build_routes()
  return {
    -- conflict: buffer-local merge-conflict resolution (own implementation, phase 2)
    {
      path = { "conflict", "ours" },
      desc = "Resolve the conflict under the cursor: keep ours",
      run = stub("conflict ours"),
    },
    {
      path = { "conflict", "theirs" },
      desc = "Resolve the conflict under the cursor: keep theirs",
      run = stub("conflict theirs"),
    },
    {
      path = { "conflict", "both" },
      desc = "Resolve the conflict under the cursor: keep both",
      run = stub("conflict both"),
    },
    {
      path = { "conflict", "base" },
      desc = "Resolve the conflict under the cursor: keep the common ancestor (diff3/zdiff3 only)",
      run = stub("conflict base"),
    },
    {
      path = { "conflict", "none" },
      desc = "Resolve the conflict under the cursor: keep neither",
      run = stub("conflict none"),
    },
    {
      path = { "conflict", "next" },
      desc = "Jump to the next conflict marker in this buffer",
      run = stub("conflict next"),
    },
    {
      path = { "conflict", "prev" },
      desc = "Jump to the previous conflict marker in this buffer",
      run = stub("conflict prev"),
    },
    {
      path = { "conflict", "list" },
      desc = "List every file with unresolved conflicts in the quickfix list",
      run = stub("conflict list"),
    },
    {
      path = { "conflict", "refresh" },
      desc = "Re-scan the current buffer for conflict markers",
      run = stub("conflict refresh"),
    },

    -- hunk: delegated to the gitsigns adapter when available, else native (phase 4)
    {
      path = { "hunk", "stage" },
      desc = "Stage the hunk under the cursor",
      run = stub("hunk stage"),
    },
    {
      path = { "hunk", "reset" },
      desc = "Reset the hunk under the cursor",
      run = stub("hunk reset"),
    },
    {
      path = { "hunk", "preview" },
      desc = "Preview the hunk under the cursor",
      run = stub("hunk preview"),
    },
    {
      path = { "hunk", "stage-buffer" },
      desc = "Stage every hunk in the current buffer",
      run = stub("hunk stage-buffer"),
    },
    {
      path = { "hunk", "reset-buffer" },
      desc = "Reset every hunk in the current buffer",
      run = stub("hunk reset-buffer"),
    },
    {
      path = { "hunk", "toggle-deleted" },
      desc = "Toggle showing deleted lines inline",
      run = stub("hunk toggle-deleted"),
    },

    -- blame: own implementation, native `git blame --porcelain` (phase 4)
    {
      path = { "blame", "line" },
      desc = "Show blame for the current line",
      run = stub("blame line"),
    },
    {
      path = { "blame", "toggle" },
      desc = "Toggle current-line blame virtual text",
      run = stub("blame toggle"),
    },
    {
      path = { "blame", "full" },
      desc = "Show full blame for the current file",
      run = stub("blame full"),
    },

    -- diff: thin alias onto diff.nvim's :Diff (phase 4)
    {
      path = { "diff", "head" },
      desc = "Diff the current file against HEAD",
      run = stub("diff head"),
    },
    {
      path = { "diff", "last" },
      desc = "Diff the current file against the previous commit",
      run = stub("diff last"),
    },
    {
      path = { "diff", "rev" },
      args = { { name = "rev", type = "STRING" } },
      desc = "Diff the current file against an arbitrary revision",
      run = stub("diff rev"),
    },
    { path = { "diff", "split" }, desc = "Open the diff view", run = stub("diff split") },
    {
      path = { "diff", "history" },
      desc = "Show file history (diff.nvim :DiffHistory)",
      run = stub("diff history"),
    },

    -- branch: extracted from ui.nvim's git_clickable statusline module (phase 5)
    {
      path = { "branch", "switch" },
      desc = "Switch to another local branch",
      run = stub("branch switch"),
    },
    { path = { "branch", "list" }, desc = "List local branches", run = stub("branch list") },
    {
      path = { "branch", "current" },
      desc = "Show the current branch",
      run = stub("branch current"),
    },

    -- browse: new -- remote-URL resolution for GitHub/GitLab/Codeberg (phase 5)
    {
      path = { "browse", "file" },
      desc = "Open the current file on its web host",
      run = stub("browse file"),
    },
    {
      path = { "browse", "selection" },
      desc = "Open the current visual selection (with line range) on its web host",
      run = stub("browse selection"),
    },
    {
      path = { "browse", "repo" },
      desc = "Open the repository root on its web host",
      run = stub("browse repo"),
    },

    -- ui: TUI launchers -- lazygit float owned by gitsuite, neogit/diffview are thin adapters (phase 3)
    {
      path = { "ui", "lazygit" },
      desc = "Open lazygit in a floating terminal",
      run = stub("ui lazygit"),
    },
    { path = { "ui", "neogit" }, desc = "Open neogit", run = stub("ui neogit") },
    { path = { "ui", "diffview" }, desc = "Open diffview", run = stub("ui diffview") },

    -- status: lib.nvim.git.status_porcelain + insights.nvim.conflicts (phase 5)
    {
      path = { "status", "repo" },
      desc = "Show repo status (branch, ahead/behind, dirty)",
      run = stub("status repo"),
    },
    {
      path = { "status", "quickfix" },
      desc = "Export repo status to the quickfix list",
      run = stub("status quickfix"),
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
