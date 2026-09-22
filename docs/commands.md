# Commands

Full sub-command reference: → [BINDINGS.md](BINDINGS.md)

## One command tree, one dispatch needle

Every `:Git <scope> <action>` invocation — `conflict`, `hunk`, `blame`,
`diff`, `browse`, `branch`, `ui`, `status` — is a leaf in a single route
tree registered through `lib.nvim.bindings.usercmd.composer`. That one
tree drives three things at once, never out of sync with each other:

- Dispatch — what actually runs.
- `<Tab>` completion at every level (`:Git <Tab>` lists the eight scopes,
  `:Git conflict <Tab>` lists its actions).
- [BINDINGS.md](BINDINGS.md) itself, generated from the same tree rather
  than hand-maintained.

A `features.<scope> = false` in `setup()` (see
[configuration.md](configuration.md)) removes that scope's routes from the
tree entirely — `<Tab>` no longer offers it, and invoking it fails the same
way an unrecognized scope would.

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
