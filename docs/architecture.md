# Why it does it that way

## Own implementation where it pays off, a thin adapter where it doesn't

Each of the nine feature families in [scope.md](scope.md) picked one of
two shapes on its own merits, not by a blanket rule:

- **Own implementation** for conflict resolution, blame, browse, branch,
  status and dashboard — none of gitsigns/fugitive/rhubarb/pickers offered
  exactly what was needed (a diff3/zdiff3-aware conflict parser; a pure
  remote-URL grammar; a `git`-only fallback that needs no picker plugin at
  all), and the actual logic is small enough that owning it beats wrapping
  it. `dashboard` is a special case of this: it *is* an own
  implementation, just one moved in from reposcope.nvim rather than
  written for gitsuite.nvim from scratch — see
  [around-it.md](around-it.md).
- **Thin adapter** for the hunk engine (gitsigns), diffing (`diff.nvim`)
  and the `ui` launchers (lazygit/neogit/diffview) — each of those is
  years of edge-case work in the plugin it wraps, and reimplementing any
  of them was explicitly rejected (`docs/scope.md`'s "Does not").

## The adapter registry

`lua/gitsuite/adapter/` is a small registry (`register`/`resolve`/
`resolve_first`), not a single global "which UI backend is active" switch
— because there isn't one answer. `hunk` wants `{"gitsigns", "native"}`
in that priority order; `ui` wants a specific named adapter per action
(`lazygit`, `neogit`, `diffview`) with no fallback beyond "not installed".
Each feature module supplies its own candidate list to `resolve_first`
instead of the registry guessing.

**Availability is checked via `package.loaded`, never by `require`ing the
foreign plugin.** `adapter.gitsigns.is_available()` reads
`package.loaded["gitsigns"] ~= nil`; calling `require("gitsigns")` there
would itself trigger a lazy-loaded plugin to load just to ask whether it's
loaded. `native.lua` is the one adapter that needs nothing but `git`
itself (through `lib.nvim.git`) — every feature family that has a native
implementation stays usable with zero adapter plugins installed.

## Dependencies point down or stay soft, never back up

A rule enforced throughout, not just stated: an adapted plugin
(gitsigns, `diff.nvim`, diffview, neogit) never gets a dependency *back*
onto gitsuite.nvim. Concretely:

- `diff.nvim` is a hard dependency of gitsuite.nvim, so `diff.nvim`
  exposing a "delegate to gitsuite's hunk preview" hook was rejected
  outright — that would have closed a cycle (gitsuite → diff.nvim →
  gitsuite).
- `insights.nvim`'s conflict scan used to `pcall`-delegate to
  `gitsuite.conflict.list()`; if gitsuite had grown a reverse delegation
  back, the two would have called each other in a loop. Instead
  `insights.conflicts` was moved to call `lib.nvim.git.status_porcelain`
  directly — the same primitive gitsuite's own conflict scan uses,
  with neither plugin aware of the other.
- `ui.nvim`'s statusline `git_clickable` module optionally calls
  `gitsuite.features.branch.switch()` (its own picker), and gitsuite
  contributes a context-menu item list consumable by `ui.contextmenu`.
  Both directions go through a soft, `pcall`-guarded check
  (`ui.util.soft_require` on ui.nvim's side) — no hard dependency either
  way for *that* pair. `:Git dashboard`'s popup/confirm dialogs are the
  one exception: they're built on `ui.kit` directly, a hard dependency
  gitsuite.nvim did not have before the dashboard moved in from
  reposcope.nvim (see [requirements.md](requirements.md)) — but it still
  only points one way, `gitsuite → ui.nvim`, so no cycle opens.

## Post-action hooks are `User` autocmd events, not direct calls

`gitsuite.events` is the one place gitsuite.nvim fires its own `User`
autocmd events (`GitsuiteBranchSwitched`, `GitsuiteConflictsResolved`, a
hunk stage/reset event) — it never `require`s or otherwise knows about a
consumer. A sister plugin that wants to react to a branch switch or a
buffer becoming conflict-free subscribes with its own `autocmd User
Gitsuite* ...`. This is the same "dependencies point down, never up" rule
applied to *reacting to* gitsuite.nvim instead of *being adapted by* it:
an event is something a listener opts into, not a call gitsuite.nvim has
to know exists.

## `setup()` never lets a bad option silently do nothing worse than the default

`gitsuite.config`'s schema (`KNOWN` in `config/init.lua`) validates every
top-level and one-level-nested key before merging: an unknown key or a
wrong-typed value is dropped with a message (collected, not thrown), and
the built-in default underneath still applies. `:checkhealth gitsuite`
surfaces whatever the last `setup()` call rejected — see
[health.md](health.md).

## See also

- [Scope](scope.md) — the same split, from the "what it does" side.
- [Health check](health.md) — where a broken adapter or a rejected option actually shows up.
