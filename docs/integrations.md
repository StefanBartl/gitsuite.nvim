# Integrations

`lua/gitsuite/integrations/` is where gitsuite.nvim knows about a foreign
plugin by name — the rest of the codebase never does (LUA-05: one module
per foreign plugin, not a `pcall(require, ...)` scattered across features).

## `menu.lua` — context-menu contributor

Builds a `Lib.ContextMenu.Item[]` list of gitsuite's git actions
(conflict resolution, blame, diff, hunk stage/reset where gitsigns backs
it). "Contributes only": nothing in this module opens or binds a menu
itself — a host (this user's own config, or another plugin) composes the
returned items into its own context menu.

Built against `lib.nvim.contextmenu`, not `ui.nvim`'s `ui.contextmenu`:
gitsuite.nvim already treats `lib.nvim` as a hard dependency, and the two
renderers' item tables are field-for-field identical, so a list built
against either opens fine on either — adding `ui.nvim` as a dependency
just to build the same shape would have bought nothing.

Every entry routes through gitsuite's own `:Git ...` commands (respecting
a renamed `commands.git`), never a raw `gitsigns.<fn>()` call — only the
entries with no native fallback at all (stage/reset a hunk, toggle
deleted lines: gitsigns' own hunk engine, never reimplemented) gate on
gitsigns being loaded. Blame and diff stay offered either way.

## `pickers_nvim.lua` — branch-switch picker bridge

The one module that knows [pickers.nvim](https://github.com/StefanBartl/pickers.nvim)
exists. `gitsuite.features.branch.switch()` asks it for a real picker
(whichever engine — snacks, telescope, fzf-lua — pickers.nvim resolves)
over `git_branches`, and degrades to a bare `vim.ui.select` when
pickers.nvim is missing or no engine resolves.

Each engine's own picker defaults its confirm action to a raw `git
checkout`; this bridge overrides that per engine (snacks: `opts.confirm`,
telescope: `opts.attach_mappings`, fzf-lua: `opts.actions["enter"]`) so
the checkout goes through gitsuite's own error handling and fires
`GitsuiteBranchSwitched` — verified against each engine's actual source,
not assumed from documentation.

## See also

- [Architecture](architecture.md) — the "adapter vs. integration" naming and the dependency-direction rule both are built on.
- [Configuration](configuration.md) — `browse.hosts` and the other options these integrations respect.
