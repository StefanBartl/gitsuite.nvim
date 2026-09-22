# Requirements

| | |
| --- | --- |
| Neovim | **0.10+** — `lib.nvim.git`/`lib.nvim.cross.run_argv` use `vim.system()` unguarded on the paths gitsuite.nvim calls, and `lib.nvim` itself requires 0.10 |
| [lib.nvim](https://github.com/StefanBartl/lib.nvim) | **required** — the `:Git` command layer is built on `usercmd.composer`, and every feature's git calls go through `lib.nvim.git`/`lib.nvim.cross.run_argv` (argv, no shell). `require("gitsuite")` cannot succeed without it; `:checkhealth gitsuite` reports it missing as an error, not a warning |
| [diff.nvim](https://github.com/StefanBartl/diff.nvim) | **required** — `:Git diff *` and `:Git hunk *` call into it directly; there is no fallback |
| `git` on `$PATH` | **required** — every feature shells out to the real `git` binary (via `lib.nvim.git`); there is no bundled or vendored git |

Optional, each detected at runtime and degrading to a clear error or a
narrower feature set rather than a crash:

| | |
| --- | --- |
| [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) | Backs `:Git hunk stage\|reset\|stage-buffer\|reset-buffer\|toggle-deleted` — gitsigns' own hunk engine is never reimplemented (see [architecture.md](architecture.md)). Without it, those five actions are unavailable; every other hunk/blame/diff action still works through the native adapter |
| [diffview.nvim](https://github.com/sindrets/diffview.nvim) | Backs `:Git ui diffview open\|close` — without it, those two fall back to `diff.nvim`'s own `split()`/`clear()` |
| [neogit](https://github.com/NeogitOrg/neogit) | Backs `:Git ui neogit` (the staging UI) — without it, that one action reports "not installed" |
| `lazygit` executable | Backs `:Git ui lazygit` (a real `lazygit` TUI in a float) — without it, that action reports a clear error, nothing else is affected |
| `nvr` (neovim-remote, `pip install neovim-remote`) | Lets `:Git ui lazygit`'s `O`/`<C-o>` open a file in the *parent* Neovim from inside the float — see [docs/lazygit-config.yml](lazygit-config.yml). Without it, lazygit still opens; those two keys just don't reach back into the editor |
| [open.nvim](https://github.com/StefanBartl/open.nvim) | Backs `:Git browse *` (opening a file/selection/repo on its web host) — without it, `:Git browse *` reports a clear error; every other feature family is unaffected |
| [pickers.nvim](https://github.com/StefanBartl/pickers.nvim) | Gives `:Git branch switch` a real picker (snacks/telescope/fzf-lua, whichever is installed) with preview — without it, the picker is a bare `vim.ui.select` over the branch list |
| [insights.nvim](https://github.com/StefanBartl/insights.nvim) | Backs `:Git conflict list` (repo-wide unresolved-conflict scan in the quickfix list) and `:Git status todos` (TODO/FIXME/... annotations, filtered to the changed files) — without it, those two actions report "not installed"; buffer-local conflict scanning (`has_conflicts()`, `choose()`, `next()`/`prev()`) is unaffected |
| [color_my_ascii.nvim](https://github.com/StefanBartl/color_my_ascii.nvim) | Filters conflict-marker-shaped text inside a fenced code block (a Markdown documentation example) out of the buffer scan — without it, such an example is treated as one more conflict to resolve |
| [filetree.nvim](https://github.com/StefanBartl/filetree.nvim) | Backs `:Git status relink` (fix Markdown/Lua/Python/TS-JS references after a git-detected rename) via its reference engine — without it, that one action reports "not installed" |
| [sessions.nvim](https://github.com/StefanBartl/sessions.nvim) | Backs `branch.sessions` (opt-in, default off — see [configuration.md](configuration.md)): saves/loads the window/tab layout around a `:Git branch switch` checkout — without it, that opt-in setting is silently inert |

None of the optional row's absence is reported by `:checkhealth gitsuite` as
a warning — see [health.md](health.md) for exactly what is and isn't
checked, and why.

## See also

- [Installation](installation.md) — a spec per plugin manager.
- [Health check](health.md) — what `:checkhealth gitsuite` reports, line by line.
