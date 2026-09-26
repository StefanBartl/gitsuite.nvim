# Commands

Full sub-command reference: → [BINDINGS.md](BINDINGS.md)

## One command tree, one dispatch needle

Every `:Git <scope> <action>` invocation — `conflict`, `hunk`, `blame`,
`diff`, `browse`, `branch`, `ui`, `status`, `dashboard` — is a leaf in a
single route tree registered through `lib.nvim.bindings.usercmd.composer`.
That one tree drives three things at once, never out of sync with each
other:

- Dispatch — what actually runs.
- `<Tab>` completion at every level (`:Git <Tab>` lists the nine scopes,
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
