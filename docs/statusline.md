# Statusline

`require("gitsuite.statusline").status()` returns an ambient merge-conflict
indicator for the current buffer -- `"MERGE 2"` when it has two unresolved
conflict regions, `""` when it has none.

It is a plain Lua string with no hard dependency on any statusline plugin,
cached per buffer, and safe to call unconditionally on every redraw. Nothing
here shells out or blocks: `gitsuite.features.conflict.scan()` is a pure
read of the buffer's own lines.

## Wiring it up

### lualine

```lua
require("lualine").setup({
  sections = { lualine_x = { require("gitsuite.statusline").lualine_component } },
})
```

`lualine_component` is `status` under another name -- the alias exists so
the lualine spec reads the way lualine specs read.

### heirline, or anything else that takes a function

```lua
{ provider = function() return require("gitsuite.statusline").status() end }
```

### The native statusline

```vim
set statusline+=%{v:lua.require('gitsuite.statusline').status()}
```

### ui.nvim

`ui.statusline.modules.gitsuite_conflict` is a ~20-line adapter shipped by
ui.nvim itself (the pattern `docs/modules.md` there calls "the sibling ships
the component, this plugin places it") -- add `gitsuite_conflict` to your
`order`, no `modules` entry needed unless you want to override how it
renders. See that plugin's own `docs/modules.md`.

## Caching, and why it is keyed by `changedtick`

A statusline redraws many times a second, so `status()` never re-scans a
buffer it has already scanned since the last real edit: the cache is keyed
by `nvim_buf_get_changedtick(bufnr)`, not a fixed TTL and not an explicit
invalidation hook.

That is a deliberate departure from firing on `GitsuiteConflictsResolved`
(`gitsuite.events`, see |gitsuite-events|) plus `BufWritePost`, the first
sketch of this module: `conflict.choose()` always edits the buffer, whether
or not it resolves the *last* remaining region in it, and
`GitsuiteConflictsResolved` only fires for that one case (by design -- a
sister plugin reacting to "the buffer is conflict-free again" should not
fire once per region). An event-only cache would keep reporting a stale
count between "resolved one of three" and either "resolved the last one" or
the next save. `changedtick` has no such gap: it bumps on every real edit,
and `status()` just checks it lazily on the next call it receives, which is
still "no process in the render path". `conflict.refresh()`'s own
extmark/highlight work never bumps `changedtick` (no text is edited), so a
plain `:Git conflict refresh` after an external buffer reload is still
covered correctly -- the reload itself is the edit that bumps it.

The module does register one autocmd, `BufDelete`/`BufWipeout`, purely to
drop a deleted buffer's cache entry (`M.invalidate(bufnr)` is the same call,
public for callers that already know a buffer is gone) -- without it the
per-buffer cache would grow for the rest of the session, and never help
correctness on its own: `changedtick` already keeps a *live* buffer's entry
right, this only keeps a *dead* one from sitting there.

## What it reports, and what it does not

- The count is `#gitsuite.features.conflict.scan(bufnr)` -- every conflict
  region in the buffer, ambiguous ones (an unresolvable `=======`, see
  |gitsuite-conflict|) included.
- `""` (not an error string) when: the buffer has no conflicts, `bufnr` is
  invalid, or `setup({ features = { conflict = false } })` turned the whole
  feature off. A statusline is not the place for an error popup.
