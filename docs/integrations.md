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

## `User GitsuitePluginsReported` — the report event

`:Git plugins report` fires it after a report is built (and written); gitsuite itself has no consumer. A statusline chip, a notifier or the plugin manager's own UI subscribes with an autocmd, the same way as to the other `Gitsuite*` events:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "GitsuitePluginsReported",
  callback = function(event)
    local r = event.data -- { id, mode, at, plugins, commits, errors, saved }
    if r.plugins > 0 then
      vim.notify(("%d plugins changed, %d commits"):format(r.plugins, r.commits))
    end
  end,
})
```

<a id="lazy-sync-hook"></a>

## `lazy.lua` — the `:Lazy sync` hook

Opt-in through `plugins.after_sync` (default `"off"`): the one module that
listens to lazy.nvim's own `User LazySyncPre` and `User LazySync` events, in
the named augroup `gitsuite_lazy_sync`.

| `plugins.after_sync` | After `:Lazy sync` |
| --- | --- |
| `"off"` (default) | Nothing. No listener is registered and the module is not even loaded; `:checkhealth gitsuite` says `lazy integration: off`. |
| `"toast"` | The `updated` report is built and stored, `User GitsuitePluginsReported` fires, and a corner toast that never takes focus sums it up: `plugins: 5 of 50 updated, 87 commits -> :Git plugins report --last`. A sync that updated nothing only gets the toast `plugins: the sync updated nothing (50 checked)`: nothing is stored and the event does not fire. |
| `"open"` | The same, and the report opens as with `:Git plugins report` (only when the sync updated something). |

- The report is built on `LazySync`: lazy.nvim fires it once, after the lock
  file is written (`LazyUpdate` comes before that). Events within 200 ms are
  folded into one build. A sync that ends while another report is still being
  built (a `:Git plugins report` on many clones, or the previous sync's) waits
  for it and is built afterwards, so one sync means one report.
- Whether the report is this sync's: `LazySyncPre` records when the sync
  started, and the newest update of the report's run (a reflog time, i.e.
  when the clone was checked out) must lie at or after that moment. A long
  build step after the checkouts does not matter, and an earlier sync's run
  is never announced again. When gitsuite was loaded only by the `LazySync`
  itself (see below), the run is compared with the newest stored `updated`
  report instead: the same run means the sync changed nothing.
- A statusline chip or another notifier stays the consumer's business: it
  subscribes to `User GitsuitePluginsReported` (above), which fires for these
  reports too.
- Never in a headless instance (`nvim --headless`, no UI attached):
  `"+Lazy! sync" +qa` would quit before an asynchronous report finishes. A
  script builds the report itself and waits for it:

  ```sh
  nvim --headless "+Lazy! sync" \
    "+lua local done; require('gitsuite.features.plugins').report({ mode = 'updated', open = false, on_done = function() done = true end }); vim.wait(120000, function() return done end)" \
    +qa
  ```

  Interactively, `:Git plugins report --no-open` does the same without the wait.

With lazy.nvim lazy-loading gitsuite (`cmd = "Git"`, `event = "BufReadPost"`),
add `"User LazySync"` to its `event` list so a sync loads it. lazy.nvim loads
the plugin from inside that event and then re-fires `User` into the plugin's
new augroups *without a pattern*, so the `LazySync` listener `setup()` creates
would miss that first sync; `setup()` therefore notices that it runs inside
`User LazySync` and starts the hook for that sync itself:

```lua
{
  "StefanBartl/gitsuite.nvim",
  cmd = "Git",
  event = { "BufReadPost", "BufNewFile", "User LazySync" },
  opts = { plugins = { after_sync = "toast" } },
}
```

## See also

- [Architecture](architecture.md) — the "adapter vs. integration" naming and the dependency-direction rule both are built on.
- [Configuration](configuration.md) — `browse.hosts` and the other options these integrations respect.
