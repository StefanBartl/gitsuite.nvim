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

## `branch`

```lua
branch = {
  -- GS-24, opt-in: save the current branch's window/tab layout
  -- (sessions.nvim, optional soft dep) before a branch.switch() checkout,
  -- load the target branch's layout after. Off by default -- an automatic
  -- load can discard unsaved buffers.
  sessions = false,
},
```

With `sessions.nvim` installed and `sessions = true`, switching branches via
`:Git branch switch` calls `sessions.core.save(nil)` right before the
checkout (while still on the branch being left) and `sessions.core.load(nil)`
right after (once HEAD has moved) — `sessions.nvim`'s own branch-aware
naming (`branch_aware`, on by default there) does the actual per-branch
bookkeeping; this only calls `save`/`load` at the right two moments.
Silently inert without `sessions.nvim` installed.

## `dashboard`

```lua
dashboard = {
  base_dir = "",     -- directory :Git dashboard/:Git dashboard update scan by default; "" -> $REPOS_DIR
  extra_paths = {},  -- repos merged onto the default page's scan; each entry must itself be a repository
  groups = {},       -- additional named pages, see below
},
```

Unlike every other family, `dashboard` operates across a whole directory
of repositories rather than the one the current buffer belongs to — see
[scope.md](scope.md#multi-repository-scopes). There is
deliberately no `features.dashboard` flag: the scope is always registered.

`base_dir` defaults to `$REPOS_DIR` (via `lib.nvim.system.env`) when unset.
If it resolves to a repository itself, only that one is reported; otherwise
its immediate subdirectories are scanned (non-recursive). `extra_paths`
adds repositories outside that scan — e.g. a Neovim config, which is a git
repo of its own but never a checkout cloned into `base_dir` — each entry
must itself be a repository; one that isn't is reported and skipped.

```lua
dashboard = {
  groups = {
    { name = "personal plugins", paths = { "$REPOS_DIR" } },
    { name = "notes", paths = { "~/notes", "~/wiki.nvim" } },
  },
},
```

Each `groups` entry is a named page `:Git dashboard` can flip to with
`<C-l>`/`<Right>` (next) and `<C-h>`/`<Left>` (previous), alongside the
default (unnamed) `base_dir` page. A group's `paths` apply the more
permissive rule `base_dir` itself uses: each entry is either a repository,
or a directory whose immediate git-repository children are all included —
unlike `extra_paths`, which never scans a plain directory. The `a`/`x` keys
inside the dashboard add/remove paths per page at runtime, layered on top
of this config without ever rewriting it — see
[BINDINGS.md](BINDINGS.md#dashboard-keys-component-local).

## `plugins`

```lua
plugins = {
  sources = "auto",  -- "auto" or a list of "lazy", "pack", "clones"
  roots = {},        -- folders of clones for the "clones" source
  log_limit = 50,    -- commits `:Git plugins log` shows when no count is given
  timeout_ms = 30000, -- timeout of each git process
  -- `:Git plugins report`
  include_local = false, -- also take `dir`-mode plugins (usually your own repos)
  mode = "updated",      -- "updated" (what the last update changed) | "pending" (what the next would bring)
  max_commits = 1000,    -- commits kept per plugin in a report; more are cut and marked
  parallel = 4,          -- git processes at once while a report is built
  run_window_s = 300,    -- plugins updated this close together form one update run
  merges = false,        -- keep merge commits in the commit lists
  keep_reports = 20,     -- stored reports, newest first
  max_age_days = 365,    -- older stored reports are dropped (the newest never is)
},
```

`:Git plugins` needs to know which clones are your plugins. `"auto"` takes the
first available of **lazy.nvim** (read from its in-memory plugin table — nothing
is called into lazy, nothing is required), **`vim.pack`** (only when it manages
something) and plain **clones**; an explicit list is the union of those sources,
deduplicated by path. `roots` replaces the folders the `clones` source scans
(default: `stdpath("data")/lazy` and `stdpath("data")/site/pack/*/{start,opt}`);
only a child with its own `.git` directory counts, a worktree (`.git` file) is
skipped. `timeout_ms` bounds every git process so a clone on a network drive
cannot hang the request.

The report options: `mode` is the default for `:Git plugins report`
(`--mode=` overrides it per call). `include_local = false` keeps `dir`-mode
plugins out — lazy.nvim never updates them, so "what the update changed" does
not apply; `--all` includes them for one call. `parallel` bounds the git
processes of one report (a machine with a virus scanner may want 2);
`max_commits` bounds what is kept per plugin. `keep_reports`/`max_age_days`
bound the stored reports (`stdpath("state")/gitsuite/plugins_reports.json`;
the file itself is also capped at 8 MiB, oldest report first) — the newest
report is always kept. The report store is **per machine** (clones, reflogs and
the lock file are machine-local); a store written on another host is kept
aside, not used. An unknown key or a wrong-typed value is dropped with a
warning, like everywhere else.

## `progress_style`

```lua
progress_style = "auto", -- "auto" | "notify" | "statusline" | "fidget" | "float" | "kit"
```

Indicator style for `:Git dashboard`/`:Git dashboard update` over many
repositories — both walk a whole directory and run `git` once or twice per
repository, which adds up to a wait long enough to look like a hang without
one. Backed by
[`lib.nvim.progress`](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/progress/README.md);
`lib.nvim` is a hard dependency of gitsuite.nvim already, so this is never a
no-op in practice.

## See also

- [What you get with the defaults](what-you-get.md) — the short version of this page.
- [Commands](commands.md) / [Bindings cheatsheet](BINDINGS.md)
- [Health check](health.md) — where a rejected option surfaces.
