# Installation

See [requirements.md](requirements.md) for the full dependency table. In
short: `lib.nvim`, `diff.nvim` and `ui.nvim` are hard dependencies,
everything else in this page is optional.

## lazy.nvim

```lua
{
  "StefanBartl/gitsuite.nvim",
  cmd = "Git",
  -- Conflict markers live in a buffer's text, so there is nothing to
  -- detect before one is read -- this trigger sets up conflict scanning/
  -- highlighting/keymaps without waiting for :Git to be typed first.
  event = { "BufReadPost", "BufNewFile" },
  dependencies = { "StefanBartl/lib.nvim", "StefanBartl/diff.nvim", "StefanBartl/ui.nvim" },
  keys = {
    { "<leader>gb", "<cmd>Git blame full<cr>", desc = "[gitsuite.nvim] Blame (full)" },
    { "<leader>lg", "<cmd>Git ui lazygit<cr>", desc = "[gitsuite.nvim] Open lazygit" },
  },
  config = function(_, opts)
    require("gitsuite").setup(opts)
  end,
},
```

`open.nvim` (for `:Git browse *`) and `pickers.nvim` (for `:Git branch
switch`'s picker) are deliberately **not** listed as `dependencies` here:
both are checked with `pcall`/`package.loaded` at call time, not
`require`d eagerly, so pinning them as hard deps would force them to load
on every buffer read for a feature most sessions never touch. Install
either separately if you want it; no configuration is needed to make
gitsuite.nvim notice it.

## packer.nvim

```lua
use({
  "StefanBartl/gitsuite.nvim",
  requires = { "StefanBartl/lib.nvim", "StefanBartl/diff.nvim", "StefanBartl/ui.nvim" },
  config = function()
    require("gitsuite").setup({})
  end,
})
```

## vim-plug

```vim
Plug 'StefanBartl/lib.nvim'
Plug 'StefanBartl/diff.nvim'
Plug 'StefanBartl/ui.nvim'
Plug 'StefanBartl/gitsuite.nvim'
```

```lua
require("gitsuite").setup({})
```

## mini.deps

```lua
local add, now = MiniDeps.add, MiniDeps.now
add({
  source = "StefanBartl/gitsuite.nvim",
  depends = { "StefanBartl/lib.nvim", "StefanBartl/diff.nvim", "StefanBartl/ui.nvim" },
})
now(function()
  require("gitsuite").setup({})
end)
```

## See also

- [Quickstart](quickstart.md) — the first thing to run after installing.
- [Configuration](configuration.md) — every `setup()` option and its default.
