# Cross-platform notes

CI runs the full test suite on `ubuntu-latest`, `windows-latest` and
`macos-latest` on every push (see
[.github/workflows/ci.yml](../.github/workflows/ci.yml)) — all three are a
gate, not just Linux with the other two as a courtesy.

## Every git call is argv, never a shell string

Both this plugin and `lib.nvim.git`/`lib.nvim.cross.run_argv` underneath it
build git invocations as argument arrays (`vim.system(cmd, ...)`), never by
interpolating a command string. This sidesteps the usual cross-platform
shell-quoting divergence (`cmd.exe` vs. POSIX shells) entirely — there is
no shell in the loop to quote for.

## Text vs. bytes

git output that is *messages* (branch names, status codes, blame text) goes
through `lib.nvim`'s text-mode capture, which normalizes `\r\n` → `\n` the
same way on every platform. git output that *is data* — a file's content at
a revision (`:Git browse *` never needs this, but `lib.nvim.git.show` that
other consumers use does) — goes through byte-exact capture instead, so a
CRLF file's line endings and a binary blob's bytes both survive intact
regardless of host.

## `:Git ui lazygit`'s `nvr` bridge

The `O`/`<C-o>` bridge from inside the lazygit float back into the parent
Neovim depends on `nvr` (`pip install neovim-remote`), which is itself
cross-platform (pure Python + a socket connection) — but a real `lazygit`
binary and a real `nvr` round-trip on Windows specifically has not yet
been verified end-to-end against this plugin (CI stubs the `jobstart` call
for that test, on all three platforms). The float itself, and every other
feature family, has run green on all three CI platforms.

## See also

- [Requirements](requirements.md) — the `nvr` and `lazygit` optional-dependency rows.
- [Health check](health.md) — `git executable on PATH` is checked the same way on every platform.
