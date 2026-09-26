# Quickstart

`setup()` is optional — every default in [configuration.md](configuration.md)
is already what you want unless you know otherwise. After installing (see
[installation.md](installation.md)), the fastest way to see gitsuite.nvim
work:

```vim
:Git status repo
```

Prints the current branch, ahead/behind count and whether the working tree
is dirty — a good one-liner to confirm `:Git` itself is wired up. From a
file inside a repo with unresolved merge conflicts:

```vim
:Git conflict list
```

Fills the quickfix list with every file that still has a conflict marker.
Put the cursor inside a conflict region and:

```vim
:Git conflict ours
```

resolves it, keeping "ours". The default keymap `<leader>gb` runs `:Git
blame full` (full-file blame), and `<leader>lg` opens the real `lazygit`
TUI in a float via `:Git ui lazygit` — both work with zero configuration.

If you have a whole folder of clones rather than just the current
repository:

```vim
:Git dashboard $REPOS_DIR
```

Shows a git-status row per repository (branch, ahead/behind, dirty state),
with `p`/`P`/`f` to push/pull/fetch the one under the cursor or a marked
set, `gu` to update everything at once. `<Tab>` on the directory argument
offers `$REPOS_DIR` ahead of real completion when that env var is set.

`<Tab>` completes every `:Git <scope> <action>` at each level, so typing
`:Git ` and pressing `<Tab>` is itself a way to explore what's there — the
same route tree also generates [BINDINGS.md](BINDINGS.md), the full
reference.

## See also

- [Commands](commands.md) — how the `:Git <scope> <action>` tree itself works.
- [Bindings cheatsheet](BINDINGS.md) — every subcommand and keymap.
- [What you get with the defaults](what-you-get.md) — the handful of things worth knowing on day one.
