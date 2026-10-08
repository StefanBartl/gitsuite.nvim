# Commands

Full sub-command reference: → [BINDINGS.md](BINDINGS.md)

## One command tree, one dispatch needle

Every `:Git <scope> <action>` invocation — `conflict`, `hunk`, `blame`,
`diff`, `browse`, `branch`, `ui`, `status`, `dashboard` — is a leaf in a
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
way an unrecognized scope would. `dashboard` has no such flag — see
[below](#dashboard-the-one-multi-repo-scope) for why.

## `dashboard`, the one multi-repo scope

Every other scope operates on the repository the current buffer belongs
to. `dashboard` is the deliberate exception: a git-status panel across a
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
`owner/repo` of its remote, or a path to any git repository. Without a target
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
