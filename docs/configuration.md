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
  pull_scope = "behind", -- gP's focused default: "behind" (only repos behind upstream) or "all"
  fetch_jobs = 4,    -- gf fetches this many repositories at once (1 to 16); push and pull stay one by one
  context_menu = true, -- <RightMouse> opens the dashboard's own menu; false disables the binding only
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

`pull_scope` decides which button `gP` (pull the whole page) focuses first.
`gP` always asks "Only behind (N)" or "All (M)"; "behind" counts the
repositories whose upstream is ahead of them as of their last fetch. A
repository without an upstream, or one that shows nothing behind but has no
fetch recorded yet (no non-empty `FETCH_HEAD`), has no trustworthy behind
count: the prompt names it, and "Only behind" skips it — fetch first (`gf`)
or pick "All". A repository that already shows commits behind is pulled by
"Only behind" either way.

`context_menu` controls `<RightMouse>` on the dashboard buffer: on by
default, it opens a menu of the same row/batch actions the keys already run
(`lib.nvim.contextmenu.bind_buffer`), acting on whatever is marked (or the
Visual selection) when either is non-empty, otherwise the row under the
mouse pointer — see [BINDINGS.md](BINDINGS.md#dashboard-keys-component-local).
`false` disables the binding only; every key still works.

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
  fetch_jobs = 2,        -- `report --fetch`: fetches at once
  fetch_timeout_ms = 60000, -- `report --fetch`: timeout of each clone's fetch
  fetch_confirm = 5,     -- `report --fetch` asks first from this many clones on (`--yes` skips it)
  run_window_s = 300,    -- plugins updated this close together form one update run
  merges = false,        -- keep merge commits in the commit lists
  keep_reports = 20,     -- stored reports, newest first
  max_age_days = 365,    -- older stored reports are dropped (the newest never is)
  seen_ttl_days = 180,   -- the report tab's seen marks (m/M) are kept this many days
  ascii = false,         -- the report tab's glyphs as ^ v x @ * (the words stay)
  after_sync = "off",    -- after :Lazy sync: "off" | "toast" | "open"
  summarize = false,     -- function(input, done) for an AI summary of one plugin; see integrations.md
  summarize_key = "gS",  -- the key in the report buffer that asks for it
  breaking = {           -- the breaking-change heuristic of the report
    collapse_repeats = 5, -- fold a subject repeated this often into one group
    ignore = {},          -- vim.regex patterns on the subject: never flagged
    plugins = {},         -- per plugin: { ignore = {...}, force = { "<hash>" }, style = "none"|"conventional" }
  },
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

The numeric options take whole numbers within a range; a value outside it is
dropped with a `setup()` issue and the default applies: `log_limit` and
`max_commits` 1–1000000, `timeout_ms` 1–2147483647, `parallel` 1–64,
`run_window_s` 1–31536000, `keep_reports` 1–10000, `max_age_days` 1–36500, `seen_ttl_days` 1–36500,
`fetch_jobs` 1–16, `fetch_timeout_ms` 1–3600000, `fetch_confirm` 1–100000
(`math.huge` is not "no limit").

The `fetch_*` options only matter for `:Git plugins report --mode=pending
--fetch` — gitsuite never fetches without that flag. It runs one `git fetch
--all --prune` per clone (only remote-tracking refs and `FETCH_HEAD` move; HEAD
and the work tree stay), `fetch_jobs` at a time (a machine with a virus scanner
is happier with few), each killed after `fetch_timeout_ms` together with its
child processes (`git-remote-https`; the process group on POSIX, `taskkill /T`
on Windows). No credential prompt can appear (`GIT_TERMINAL_PROMPT=0`,
`GCM_INTERACTIVE=never`): a private repository fails like a timeout, the other
plugins go on, and the report lists every failed and skipped clone. From
`fetch_confirm` clones on it asks first (`fetch_confirm = 1`: always); `--yes`
skips the question. Nothing is fetched while lazy.nvim is working on plugins,
and a clone whose `index.lock` is held is skipped. A clone whose fetch failed
never counts as fetched, so the report does not call its remote state current.

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

`after_sync` is the optional `:Lazy sync` hook. `"off"` (default) registers
nothing: a report is built only when you ask for one. `"toast"` builds and
stores the `updated` report after every `:Lazy sync` that updated something and
shows a toast that never takes focus (`5 of 50 updated, 87 commits -> :Git
plugins report --last`; a sync that updated nothing stores nothing and only says
so); `"open"` also opens the report. Never in a headless instance. With a
lazy-loaded gitsuite, add `"User LazySync"` to its `event` list: the sync that
loads it is reported too (`setup()` notices it runs inside that event) — see
[integrations.md](integrations.md#lazy-sync-hook).

`breaking` tunes the breaking-change digest of each plugin in the report (see
[commands.md](commands.md#breaking-changes-in-the-report)). `collapse_repeats`
(1–1000) folds a subject that repeats this often (without its `type(scope):`
prefix) into one expandable group; a commit with a `BREAKING CHANGE:` footer is
never folded. `ignore` is a list of `vim.regex` patterns matched against the
subject (a pattern that does not compile is a `setup()` issue). `plugins` holds
per-plugin overrides by plugin name:

```lua
breaking = {
  plugins = {
    ["vim-matchup"] = { force = { "da04528e" } },   -- always breaking (7+ hex digits)
    neogit = { style = "none" },                    -- no conventional commits here
    ["mini.ai"] = { ignore = { [[\v^docs]] } },     -- more ignore patterns
  },
},
```

`style = "none"` marks the project as not using conventional commits (the
report then says the classifier sees little there), `"conventional"` as using
them; without it the newest 100 subjects decide (less than half conventional =
"no marker convention recognized").

## `progress_style`

```lua
progress_style = "auto", -- "auto" | "notify" | "statusline" | "fidget" | "float" | "kit"
```

Indicator style for `:Git dashboard`/`:Git dashboard update` over many
repositories — both walk a whole directory and run `git` once or twice per
repository, which adds up to a wait long enough to look like a hang without
one. Backed by
[`lib.nvim.progress`](https://github.com/WKDSteve/lib.nvim/blob/main/lua/lib/nvim/progress/README.md);
`lib.nvim` is a hard dependency of gitsuite.nvim already, so this is never a
no-op in practice.

## See also

- [What you get with the defaults](what-you-get.md) — the short version of this page.
- [Commands](commands.md) / [Bindings cheatsheet](BINDINGS.md)
- [Health check](health.md) — where a rejected option surfaces.
