# What you get with the defaults

The handful of things worth knowing before reading anything else.

- **One command tree replaces four plugins.** `:Git <scope> <action>`
  covers what vim-fugitive (`:Git blame`), vim-rhubarb (`:Gbrowse`),
  git-conflict.nvim (`:GitConflict*` + `co`/`ct`/`cb`/`c0`/`]x`/`[x`) and
  lazygit.nvim (the float + the `nvr` `O`/`<C-o>` bridge) used to cover
  separately — see [around-it.md](around-it.md) for what's genuinely new
  code versus a thin adapter.

- **Conflict markers are detected the moment a buffer is read**, not only
  after you type `:Git` — `event = { "BufReadPost", "BufNewFile" }` in the
  install spec. `<leader>gb` (full blame) and `<leader>lg` (lazygit) work
  immediately too.

- **`git conflict *` is a real parser**, not a regex over `<<<<<<<`/
  `=======`/`>>>>>>>`: it understands `diff3`/`zdiff3` styles (the base
  version between "ours" and "theirs"), nested/nested-in-nested conflicts
  via marker length, and reads `.gitattributes`' `conflict-marker-size` for
  non-default marker widths.

- **`:Git ui lazygit` opens the real `lazygit` binary** in a float, not a
  reimplementation — and its own `O`/`<C-o>` open a file in the *parent*
  Neovim via `nvr`, not a second nested editor. See
  [docs/lazygit-config.yml](lazygit-config.yml).

- **`:Git browse *` needs no git-hosting plugin** — GitHub, GitLab,
  Codeberg and any self-hosted instance you add to `browse.hosts` are all
  handled by [lib.nvim.git.remote](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/git/README.md)'s
  pure URL grammar, not a per-host API client.

- **Every feature works with zero adapter plugins installed.** gitsigns,
  diffview and neogit each make one narrow slice better (gitsigns' own
  hunk engine, diffview's side-by-side view, neogit's staging UI) but
  nothing *requires* them — the native adapter (plain `git`, via
  `lib.nvim.git`) covers the rest. See [architecture.md](architecture.md).

- **`:Git dashboard` is the one command that isn't about the current
  repository.** A git-status panel (branch, ahead/behind, dirty,
  last-commit age) across a whole folder of clones, or a configured set
  of named pages (`dashboard.groups`) you flip between with
  `<C-l>`/`<C-h>` — with push/pull/fetch per row, per marked set, or for
  the whole page. See [configuration.md](configuration.md) for
  `dashboard.*` and [BINDINGS.md](BINDINGS.md#dashboard-keys-component-local)
  for its own keys.

- **A rejected `setup()` option never breaks the default.** An unknown key
  or a wrong-typed value is dropped with a warning (surfaced through
  `:checkhealth gitsuite`), and the built-in default underneath still
  applies.

## See also

- [Configuration](configuration.md) — every option this list only samples.
- [Quickstart](quickstart.md) — the first commands to actually run.
