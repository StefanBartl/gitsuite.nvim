# Commands

Full sub-command reference: → [BINDINGS.md](BINDINGS.md)

## One command tree, one dispatch needle

Every `:Git <scope> <action>` invocation — `conflict`, `hunk`, `blame`,
`diff`, `browse`, `branch`, `ui`, `status`, `plugins`, `dashboard` — is a leaf in a
single route tree registered through `lib.nvim.bindings.usercmd.composer`.
That one tree drives three things at once, never out of sync with each
other:

- Dispatch — what actually runs.
- `<Tab>` completion at every level (`:Git <Tab>` lists the ten scopes,
  `:Git conflict <Tab>` lists its actions).
- [BINDINGS.md](BINDINGS.md) itself, generated from the same tree rather
  than hand-maintained.

A `features.<scope> = false` in `setup()` (see
[configuration.md](configuration.md)) removes that scope's routes from the
tree entirely — `<Tab>` no longer offers it, and invoking it fails the same
way an unrecognized scope would. `dashboard` and `plugins` have no such flag — see
[below](#dashboard-a-multi-repo-scope) for why.

## `dashboard`, a multi-repo scope

Most scopes operate on the repository the current buffer belongs
to. `dashboard` is a deliberate exception (`plugins report`, below, is the
other): a git-status panel across a
whole directory of clones (or a configured set of named pages), with
row/marked-set/whole-page push, pull and fetch. Moved here from
reposcope.nvim, which stays scoped to GitHub/GitLab/Codeberg discovery —
see [scope.md](scope.md) for the boundary and [configuration.md](configuration.md)
for `dashboard.base_dir`/`extra_paths`/`groups`.

```vim
:Git dashboard [dir] [--out=popup|buffer|split|vsplit|clipboard|path] [--to=<path>]
:Git dashboard update [dir]
```

`:Git dashboard update` is the headless counterpart: fetch + fast-forward
pull over every repository in `dir`/`dashboard.base_dir`, no UI, one
summary notification when it's done — the same pair the dashboard's own
`gu` key runs without leaving the panel.

### `plugins` — the history of the clones a plugin manager installed

```vim
:Git plugins log [plugin|owner/repo|path] [n] [--count=n] [--out=picker|buffer|clipboard]
```

Shows the newest `n` commits (default `plugins.log_limit`, 50, at most 5000) of one clone:
an installed plugin by name (`<Tab>` completes the names of whatever lazy.nvim,
`vim.pack` or your plugin folders hold — no process is started), the
`owner/repo` of its remote, or a path to the top of a git checkout that has its own `.git` directory (a worktree or submodule, whose `.git` is a file, is refused: point at the main checkout). Without a target
it uses the plugin the current buffer's file belongs to, else asks. The
installed commit (`HEAD`) and release tags are marked. The positional `n` needs
a target before it (`log lazy.nvim 20`); for the buffer's own plugin write
`log --count=20`.

In the **picker** (default) the right pane previews the message and the
changed files of the commit under the cursor; `<CR>` opens the commit on its
web host (or copies the hash when the host is not recognised), `<M-o>` does the
same without closing the list, `<M-y>` copies the hash. There is deliberately no
lazygit key: lazygit can change a clone, this feature never does — use
`:Git ui lazygit <dir>` for that. `--out=buffer` keeps a read-only listing,
`--out=clipboard` copies it.

It only **reads**: one `git log` process per call, never a fetch, never a write
to the clone, and no patch or file-content output (so neither a missing blob in a
blobless clone nor a `textconv`/diff program named in the clone's own config is
ever involved). In a blobless clone it
works offline — it needs commits and file *names*, not file contents. A plugin
that is not installed (`owner/repo` naming something you never installed) is
refused with that reason: gitsuite does not clone or look anything up.

```vim
:Git plugins report [--mode=updated|pending] [--all] [--last] [--out=buffer|clipboard|path] [--to=<path>]
```

The question behind `:Lazy sync`: *which plugins changed, and what did they
bring?* It looks at **every** installed plugin and lists the ones that changed,
each with its commits, as a Markdown report (a read-only buffer by default).

- `--mode=updated` (default, `plugins.mode`): what the **last update** changed.
  The state before the update comes from each clone's own HEAD reflog, which
  lazy.nvim fills with a `git checkout` per update — so it survives a restart,
  which lazy's in-memory "updated" list does not. Plugins updated within
  `plugins.run_window_s` (300 s) of each other form one run; the newest run is
  reported. A freshly installed plugin is "newly installed", not an update (a
  state counts only once it lasted two minutes), and the user's own commits in
  a clone are not updates either. If a clone has no usable reflog, the state of
  the previous stored report stands in, marked `snapshot ~` (approximate).
- `--mode=pending`: what the **next update would bring** — the installed
  commit against the one lazy.nvim would check out for that plugin: its
  `commit`, `tag`, the highest tag matching its `version` range
  (`defaults.version` included) or the tip of its branch. A pinned plugin is
  listed as pinned; one whose target cannot be told is listed as such, never
  compared with some other branch. This is the state **as of the last fetch**
  (`:Lazy check` fetches; gitsuite does not) and the report says how old that
  is.
- `--all` also takes `dir`-mode plugins (usually your own repositories;
  `plugins.include_local`). `--last` shows the newest stored report without
  scanning. `--out=path` writes the Markdown to `--to` (default a file in
  `stdpath("cache")/gitsuite/`).

Each plugin is read from files first (HEAD, refs, reflog — about 100 ms for fifty
clones); only a plugin that **changed** costs a git process (one
`git log from...to --left-right`, which also tells the direction), at most
`plugins.parallel` at a time. A range seen in an earlier report is taken from
the store. The direction is stated, not assumed: **rolled back** (the old state
had commits the new one lacks), **diverged** (both sides have some, e.g. a
`master` → `main` switch) and **old state gone** (a force-push removed the
previous commit) are shown as such, not as "N new commits".

Reports live in `stdpath("state")/gitsuite/plugins_reports.json` — one file per
machine, written atomically, never silently overwritten (an unreadable one is
moved to `.corrupt`; one written on another host is kept aside as `.foreign-<host>.bak` and this machine starts its own; one from a newer gitsuite, or a store that is not a plain file, is not touched and the report is not saved).
`plugins.keep_reports`/`max_age_days` bound it, the newest report is never
rotated out. After each report `User GitsuitePluginsReported` fires (see
`doc/gitsuite.txt` §7).

## Rename the command

```lua
require("gitsuite").setup({
  commands = { git = "Git" },  -- default
})
```

Useful if `:Git` collides with something else already registered (a common
case: vim-fugitive also defines `:Git`, which is one reason gitsuite.nvim
is meant to replace it rather than sit alongside it).

## See also

- [Bindings cheatsheet](BINDINGS.md) — the generated table, and the default keymaps.
- [Configuration](configuration.md) — the full `commands`/`keymaps` option reference.
