# Around it

How gitsuite.nvim's scope differs from the plugins it sits next to or
replaces.

**gitsigns.nvim** — not replaced, adapted. gitsigns owns the hunk engine
(stage/reset/preview, the sign column) and gitsuite.nvim never rebuilds
it: `:Git hunk *` delegates to gitsigns when it's loaded, and to a native
`git`-only implementation otherwise. Blame and diff are gitsuite's own
either way — gitsigns' current-line blame text is not what `:Git blame *`
uses.

**diffview.nvim** — not replaced, adapted, and a genuinely one-way
relationship: gitsuite.nvim depends on `diff.nvim` (its own sibling) as a
hard dependency for `:Git diff *`/`:Git hunk *`, and `:Git ui diffview
open|close` is a thin pass-through to diffview.nvim when it's installed,
falling back to `diff.nvim`'s own split view otherwise. Folding diffview's
years of edge-case work into this plugin was considered and rejected —
see [architecture.md](architecture.md).

**neogit** — adapted only. The staging UI is neogit's own; `:Git ui neogit`
opens it if installed and reports "not installed" otherwise. Nothing here
reimplements staging.

**vim-fugitive / vim-rhubarb / git-conflict.nvim / lazygit.nvim** —
replaced outright, not adapted. `:Git blame *` (fugitive), `:Gbrowse`
(rhubarb), the `:GitConflict*` family plus `co`/`ct`/`cb`/`c0`/`]x`/`[x`
(git-conflict.nvim) and the lazygit float plus its `nvr` bridge
(lazygit.nvim) are all real gitsuite.nvim implementations now, not
wrappers — fugitive in particular defines its own `:Git`, a hard command
collision rather than mere redundancy, which is the concrete reason it had
to go rather than stay installed alongside this plugin.

**reposcope.nvim** — different unit of work, with one deliberate exception.
Every `:Git` scope but `dashboard` operates on *one* repository at a time,
the one the current buffer sits in; reposcope stays scoped to
GitHub/GitLab/Codeberg discovery, search and cloning. `:Git dashboard`
itself — a multi-repo git-status panel with row/marked-set/whole-page
push, pull and fetch — used to live in reposcope as `:Reposcope dashboard`/
`update`, built before gitsuite.nvim existed as the dedicated git-tooling
home; it moved here because a multi-repo *status/action* panel is git
tooling, not repository *discovery*. See
[scope.md](scope.md#dashboard-the-one-multi-repo-scope) for the boundary
this draws.

**insights.nvim** — no dependency in either direction. `insights.conflicts`
used to run its own two-process conflict scan; it now calls
`lib.nvim.git.status_porcelain` directly, the same primitive
`gitsuite.features.conflict` is built on, without either plugin knowing
about the other. Delegating one to the other was considered and rejected
specifically to avoid a two-plugin call cycle.

## See also

- [Scope](scope.md) — what gitsuite.nvim does and does not do, independent of any one sibling.
- [Architecture](architecture.md) — why the adapter/native split exists.
