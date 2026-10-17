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
:Git plugins report [--mode=updated|pending] [--all] [--last] [--out=buffer|clipboard|path] [--to=<path>] [--no-open] [--fetch [--yes]]
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
  (`:Lazy check` fetches; gitsuite only with `--fetch`) and the report says how
  old that is.
- `--fetch` (with `--mode=pending` only, never a default): first `git fetch
  --all --prune` every clone the report looks at, then build the report — the
  ages it shows are then fresh. This is the one place gitsuite uses the
  network, and it moves remote-tracking refs (never HEAD or the work tree).
  From `plugins.fetch_confirm` (5) clones on it asks first; `--yes` skips the
  question. `plugins.fetch_jobs` (2) at a time, each killed with its child
  processes after `plugins.fetch_timeout_ms` (60 s); no credential prompt can
  appear, so a private or vanished repository fails and the others go on. The
  report says how many clones were fetched, and names each failed one (which
  then does not count as fetched) and each skipped one (an `index.lock` is
  held). Refused while lazy.nvim is working on plugins. Without gitsuite:
  `:Lazy check`, then `:Git plugins report --mode=pending`.
- `--all` also takes `dir`-mode plugins (usually your own repositories;
  `plugins.include_local`). `--last` shows the newest stored report without
  scanning. `--out=path` writes the Markdown to `--to` (default a file in
  `stdpath("cache")/gitsuite/`); `--to=<file>` alone implies `--out=path`, and
  with another `--out` it is ignored with a warning. Only one report runs at a
  time; a second `:Git plugins report` meanwhile says `already running` (the
  `:Lazy sync` hook instead waits and builds afterwards). The picker of
  `plugins log` shows at most the newest 1000 commits (use `--out=buffer` for
  all).
- `--no-open` opens no buffer: it builds and stores the report and fires the
  event, and shows only a one-line summary; `--last` opens it later. An explicit
  `--out=clipboard` or `--out=path` (also implied by `--to=<file>`) still
  copies or writes the report; `--out=buffer` is ignored with a warning. With
  `--last`, `--no-open` shows only the stored report's summary. Meant for
  scripts and hooks; to run it automatically after every `:Lazy sync`, see
  `plugins.after_sync` ([integrations.md](integrations.md#lazy-sync-hook)).

Each plugin is read from files first (HEAD, refs, reflog — about 100 ms for fifty
clones); only a plugin that **changed** costs git processes: one
`git log from...to --left-right --topo-order --name-status`, which also tells
the direction, plus — only when the clone has tags at all — two
`git for-each-ref --merged/--no-merged` for its releases, and one short
`git log` of the newest subjects when the update itself has fewer than 100
commits (for the convention check below); at most `plugins.parallel` plugins at
a time. A range seen in an earlier report is taken from the store.

#### Breaking changes in the report

Every changed plugin gets a summary that is computed, not written by an AI, and
is the same for the same commits: commits per conventional type, top scopes,
authors (with the share of bots), changed directories, the releases of the
range — `MAJOR v1.9.1 → v2.0.0`, or `no release tag in this update (last
v0.9.3)`; pre-release tags are left out — and a breaking-change digest. The
overview table has a **Breaking** column (`!3` breaking, `?1` probably,
`~23` grouped).

| Tier | What counts | Shown |
| --- | --- | --- |
| breaking | `type(scope)!:` (also `feat(a,b)!:`), a `BREAKING CHANGE:` / `BREAKING-CHANGE:` / `BREAKING_CHANGE:` footer (upper case), a subject that starts with `BREAKING` | listed |
| probably breaking | "drop support/compat", "requires Neovim x", a lower-case `breaking change:` footer, "by default" in the subject, a misplaced marker (`fix!(lsp):`) | listed |
| hint | remove/rename/deprecate in the subject, a removed Lua module, "breaking" in the body — scored | folded, best 5 first |
| parser updates | a `!` on a tree-sitter parser bump (`feat(kdl)!: update parser and queries`) | one folded group, with the installed languages |

Reverts never count, a `!` elsewhere in the subject (`buffer!`, `:!`) or in the
body is no marker, CI/docs/test/chore commits without a marker of their own get
no tier, and commit bodies with CRLF line ends are normalized first. A subject
that repeats `plugins.breaking.collapse_repeats` (5) times or more is folded into
one group — except a commit with a breaking marker, which always stays listed.
Each flagged commit carries its place in the update (`17/86`, oldest first, in
the order git applied them; only when the list is complete) and, where it can
be told offline, whether it concerns you: "drops Neovim 0.11; you run 0.12.2
(does not affect you)", "requires Neovim 0.13 (NOT met)", or the installed
languages of a parser commit.

This is a heuristic over commit messages. On a hand-labelled corpus of real
plugin commits (`TESTS/fixtures/breaking/`) "breaking" is right about nine
times in ten and "probably breaking" about every other time — but only about
half of what a person calls breaking carries a marker at all, so **0 hits does
not mean no breaking changes**; the report says so in its header. A plugin
whose newest 100 subjects are mostly not conventional commits is marked "no
marker convention recognized". Per-plugin overrides (`force`, `ignore`,
`style`) are in [configuration.md](configuration.md#plugins). The direction is stated, not assumed: **rolled back** (the old state
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
