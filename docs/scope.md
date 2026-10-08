# What it does and what not

## Does

Ten `:Git <scope> <action>` families, each a real implementation unless
noted:

- **`conflict`** — merge-conflict detection, highlighting and resolution
  in the current buffer. Own parser (diff3/zdiff3-aware, marker-length
  aware for nesting, `.gitattributes`' `conflict-marker-size` respected).
- **`hunk`** — stage/reset/preview a hunk or the whole buffer, toggle
  inline diff. Delegates to gitsigns' engine; no native fallback for
  stage/reset/stage-buffer/reset-buffer/toggle-deleted/inline (that would
  mean reimplementing gitsigns' git-index writes and deleted-line
  tracking, never done here) — only `preview` degrades gracefully, to
  `:Git diff head` (diff.nvim), when gitsigns is not installed.
- **`blame`** — full-file and current-line blame. Own implementation
  (`git blame --porcelain`), not delegated to gitsigns or fugitive.
- **`diff`** — diffing against HEAD, the previous commit, or an arbitrary
  revision; file history. Delegates to `diff.nvim` (a hard dependency).
- **`browse`** — open the current file, a visual selection (with line
  range) or the repository root on its web host. Own pure URL grammar
  (`lib.nvim.git.remote`), no git-hosting API client.
- **`branch`** — list, switch to, and show the current local branch. A
  real picker (pickers.nvim) when installed, `vim.ui.select` otherwise.
- **`ui`** — launchers for `lazygit` (a real TUI in a float, with an `nvr`
  bridge back into the parent Neovim), `neogit` and `diffview.nvim`, each
  a thin pass-through to the real plugin/binary.
- **`status`** — repository status (branch, ahead/behind, dirty) and a
  quickfix export of the same, via `lib.nvim.git.status_porcelain`.
- **`plugins`** — what changed in the plugins a plugin manager installed.
  `:Git plugins log` shows the newest commits of one plugin (or of any clone),
  single-repository like `ui lazygit [dir]` — the target is named explicitly
  instead of being the current buffer's repository. `:Git plugins report`
  looks across *all* installed plugins: what the last update changed, or what
  the next one would bring, with the commits of each. Both read the clones
  (lazy.nvim, `vim.pack` or plain folders) and nothing else: **plugins reads
  only local repository state; no install, update, pin or clean** — it never
  fetches, never changes a clone.
- **`dashboard`** — a multi-repo git-status panel (branch, ahead/behind,
  dirty, last-commit age) across a whole directory of clones, or a
  configured set of named pages (`dashboard.groups`), with row/marked-set/
  whole-page push, pull and fetch. Moved here from reposcope.nvim, which
  stays scoped to GitHub/GitLab/Codeberg discovery. One of the two
  [multi-repository scopes](#multi-repository-scopes).

## Does not

- **No staging UI.** neogit owns that; `:Git ui neogit` opens it, nothing
  here reimplements it.
- **No side-by-side diff engine.** diffview.nvim and `diff.nvim` own that.
- **No interactive rebase, no commit editor.** Outside every one of the
  ten families above — `lazygit` or the terminal is the intended tool for
  those.
- **Cross-repository views are the exception, and there are two.**
  `dashboard` and `plugins report` look at many repositories at once; every
  other family operates on the one repository the current buffer belongs to
  (`plugins log` and `ui lazygit [dir]` take one explicitly named). See
  [Multi-repository scopes](#multi-repository-scopes) and
  [around-it.md](around-it.md) for the contrast with reposcope.nvim.
- **No plugin management.** `plugins` never installs, updates, pins, cleans or
  fetches: lazy.nvim (or whatever manager you use) does that, and `plugins
  report` reads what it left behind.
- **No git-hosting API integration** (issues, PRs, CI status). `:Git
  browse *` only ever builds a URL and hands it to a browser opener —
  nothing here authenticates against GitHub/GitLab/Codeberg.

## Multi-repository scopes

Two families step outside "one repository per command", for different
reasons:

| | `dashboard` | `plugins report` |
| --- | --- | --- |
| Question | What is the git state of all these repositories? | What did the plugins I installed change? |
| Repositories | A directory (`dashboard.base_dir`, `$REPOS_DIR`) or configured groups | The clones a plugin manager installed |
| Acts on them | Yes — push, pull and fetch, per row, marked set or page | **No** — reads files and `git log`; nothing is fetched or changed |
| Keeps | Only the per-page paths you add or hide with `a`/`x` (`stdpath("data")/gitsuite/dashboard_pages.json`); the table itself is a live view | Reports under `stdpath("state")/gitsuite/` |
| Switch | No `features.*` flag — always registered | No `features.*` flag — always registered |

Both are bounded by the same rule: they work on the repositories they were
pointed at, they do not discover or host anything (that stays reposcope.nvim's
job), and neither calls a hosting API.

## See also

- [Around it](around-it.md) — the same boundary, described against each specific sibling plugin.
- [Architecture](architecture.md) — why the "own implementation vs. thin adapter" split falls exactly where it does.
