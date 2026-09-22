# Contributing to gitsuite.nvim

Thank you for your interest! Bugs, ideas and questions are welcome in the
[issue tracker](https://github.com/StefanBartl/gitsuite.nvim/issues); pull
requests very welcome.

## Getting the repository into a session

Clone `lib.nvim` and `diff.nvim` alongside it (both hard dependencies),
then add all three to the runtime path:

```lua
vim.opt.rtp:prepend("/path/to/lib.nvim")
vim.opt.rtp:prepend("/path/to/diff.nvim")
vim.opt.rtp:prepend("/path/to/gitsuite.nvim")
require("gitsuite").setup({})
```

## Ground rules

- Lua only, idiomatic Neovim Lua. 2-space indentation, `stylua`-formatted.
- **A feature never names an adapter plugin directly.** Everything under
  `features/` goes through `gitsuite.adapter`'s `resolve`/`resolve_first`;
  the moment a feature branches on `if package.loaded["gitsigns"]` outside
  the adapter layer, the whole point of the registry is gone.
- **Availability is checked via `package.loaded`, never `require`.**
  Checking whether a foreign plugin is loaded must not be what *loads* it
  — see [architecture.md](architecture.md).
- **A dependency never points back up.** An adapted plugin (gitsigns,
  `diff.nvim`, diffview, neogit) must never gain a hook that calls back
  into gitsuite.nvim — that closes a cycle. A sister plugin that wants to
  react to gitsuite.nvim subscribes to its `User` autocmd events
  (`gitsuite.events`) instead; see [architecture.md](architecture.md) for
  the concrete cases this rule has already prevented.
- Every git call goes through `lib.nvim.git`/`lib.nvim.cross.run_argv`
  (argv, never a shell string) — no `vim.fn.system("git " .. ...)`
  anywhere in this codebase.
- Commands are registered through `lib.nvim.bindings.usercmd.composer` —
  one route tree drives dispatch, `<Tab>` completion and
  [BINDINGS.md](BINDINGS.md) at once (see [commands.md](commands.md)).
- Descriptive commit messages.

## Project layout

| Path | Contains |
| --- | --- |
| `lua/gitsuite/adapter/` | The registry, plus one file per backend: gitsigns, diffview, neogit, lazygit, native |
| `lua/gitsuite/features/` | Every `:Git` scope's implementation, written against the adapter registry |
| `lua/gitsuite/integrations/` | Soft-dependency bridges (context menu, pickers.nvim) — see [integrations.md](integrations.md) |
| `lua/gitsuite/bindings/` | The `:Git` route tree, keymaps |
| `lua/gitsuite/config/` | Defaults, the `setup()` option schema |
| `lua/gitsuite/events.lua` | Every `User` autocmd event this plugin fires |
| `lua/gitsuite/health.lua` | `:checkhealth gitsuite` |
| `docs/` | Everything the README links to |
| `TESTS/` | The spec suite |

## Adding a `:Git` scope or action

1. Write the feature under `features/<scope>/`, against `gitsuite.adapter`
   if it needs an external backend, or `lib.nvim.git` directly if it
   doesn't.
2. Add its route(s) to `lua/gitsuite/bindings/usrcmds.lua` — this alone
   wires up dispatch, `<Tab>` completion and regenerates
   [BINDINGS.md](BINDINGS.md).
3. Add it to the `features` table in `config/DEFAULTS.lua` if the whole
   scope should be toggleable.
4. Give it a keymap entry in `config/DEFAULTS.lua`'s `keymaps` table if a
   default binding makes sense.
5. Add a spec under `TESTS/gitsuite/`.
6. Update [commands.md](commands.md)/[configuration.md](configuration.md)
   if the change is user-visible beyond the generated
   [BINDINGS.md](BINDINGS.md).

## Adding an adapter

Implement `GitSuite.Adapter` (`name`, `is_available()`, and whatever
action methods the feature family needs) in a new file under
`lua/gitsuite/adapter/`, checked against `package.loaded`, never
`require`d, to resolve availability. Register it (built-ins self-register
on first `resolve()`/`resolve_first()` call) and add it to
`health.lua`'s adapter list.

## Tests

`TESTS/` is a [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
busted-style suite, run with:

```bash
LIB_NVIM_DIR=/path/to/lib.nvim DIFF_NVIM_DIR=/path/to/diff.nvim \
PLENARY_DIR=/path/to/plenary.nvim bash scripts/test.sh [TESTS/gitsuite/x_spec.lua]
```

Most specs run against this repository's own real git state (its actual
branch, its actual conflict-free tree) rather than mocked output — see
existing specs under `TESTS/gitsuite/` for the pattern before adding a
mock where a real temp repo would do. [GitHub Actions](../.github/workflows/ci.yml)
runs the full suite on Linux, Windows and macOS on every push and PR to
`main`.

## Workflow

1. Fork the repository.
2. Branch as `feature/<name>`.
3. Make the change, add a spec, update the affected pages under `docs/`
   and regenerate [BINDINGS.md](BINDINGS.md) if a route changed.
4. `stylua --check .` and `luacheck lua TESTS` clean.
5. Open a PR with a clear description of what changed and why.
