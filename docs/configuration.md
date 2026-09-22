# Configuration

```lua
require("gitsuite").setup({
  -- defaults shown
})
```

Every option below is optional; an unknown key or a value of the wrong
type is dropped (with a warning surfaced through `:checkhealth gitsuite`,
see [health.md](health.md)) rather than silently applied or raised as an
error — the default underneath still takes effect.

## `features`

Toggle whole feature families off. All eight are `true` by default.

```lua
features = {
  conflict = true,  -- merge-conflict resolution (:Git conflict *)
  hunk = true,      -- hunk stage/reset/preview (:Git hunk *)
  blame = true,     -- full-file and current-line blame (:Git blame *)
  diff = true,      -- diff.nvim-backed diffing (:Git diff *)
  browse = true,    -- open file/selection/repo on its web host (:Git browse *)
  branch = true,    -- list/switch/show the current branch (:Git branch *)
  ui = true,        -- lazygit/neogit/diffview launchers (:Git ui *)
  status = true,     -- repo status / quickfix export (:Git status *)
},
```

A family set to `false` does not register that scope's routes at all —
`:Git conflict ours` with `features.conflict = false` fails the same way
an unrecognized scope would, not with a "disabled" message.

## `commands`

```lua
commands = {
  git = "Git",  -- the top-level user command name
},
```

Rename the command if `:Git` collides with something else in your setup
(vim-fugitive defines its own `:Git`, for instance — one reason gitsuite.nvim
replaces it outright rather than living alongside it). Every keymap default
below still runs through whatever name you set here.

## `keymaps`

```lua
keymaps = {
  blame_full = "<leader>gb",       -- :Git blame full
  ui_lazygit = "<leader>lg",       -- :Git ui lazygit
  hunk_inline = "<leader>di",      -- :Git hunk inline
  diffview_open = "<leader>dv",    -- :Git ui diffview open
  diffview_close = "<leader>dc",   -- :Git ui diffview close
  diff_history = "<leader>dh",     -- :Git diff history
},
```

Each value is a string `lhs`, a list of `lhs` strings (several keys mapped
to the same action), or `false` to disable that one action's default
mapping entirely without touching the others. See
[BINDINGS.md](BINDINGS.md) for what each one runs.

## `browse`

```lua
browse = {
  -- Additional self-hosted GitHub/GitLab/Codeberg(Gitea) instances, keyed
  -- by host. Empty by default -- only github.com/gitlab.com/codeberg.org
  -- are recognized out of the box.
  hosts = {},
  -- hosts = { ["git.example.org"] = "gitlab" },
},
```

Controls which web-URL grammar `:Git browse *` builds for a self-hosted
remote — GitHub's `/blob/`, GitLab's `/-/blob/`, or Codeberg/Gitea's
`/src/branch/`. The three public hosts need no entry here.

## See also

- [What you get with the defaults](what-you-get.md) — the short version of this page.
- [Commands](commands.md) / [Bindings cheatsheet](BINDINGS.md)
- [Health check](health.md) — where a rejected option surfaces.
