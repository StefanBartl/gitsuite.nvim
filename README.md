> **Alpha stage — active development.** This repository is being built out
> feature by feature (see [docs/BINDINGS.md](docs/BINDINGS.md) for what
> already works). Breaking changes are expected. Pin a commit if you depend
> on it.

# gitsuite.nvim

```
 ██████╗ ██╗████████╗███████╗██╗   ██╗██╗████████╗███████╗
██╔════╝ ██║╚══██╔══╝██╔════╝██║   ██║██║╚══██╔══╝██╔════╝
██║  ███╗██║   ██║   ███████╗██║   ██║██║   ██║   █████╗
██║   ██║██║   ██║   ╚════██║██║   ██║██║   ██║   ██╔══╝
╚██████╔╝██║   ██║   ███████║╚██████╔╝██║   ██║   ███████╗
 ╚═════╝ ╚═╝   ╚═╝   ╚══════╝ ╚═════╝ ╚═╝   ╚═╝   ╚══════╝
                                               .nvim
```

> Sister plugin: [diff.nvim](https://github.com/StefanBartl/diff.nvim) (a
> hard dependency here for `:Git diff *`).

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-alpha-orange)
[![CI](https://github.com/StefanBartl/gitsuite.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/StefanBartl/gitsuite.nvim/actions/workflows/ci.yml)

One `:Git <scope> <action>` command tree for everything git in Neovim — own
implementation where that pays off (merge-conflict resolution, blame,
browse), thin adapters where it does not (gitsigns' hunk engine, neogit's
staging UI, diffview, the real `lazygit` TUI in a float).

---

## Documentation

- [Bindings cheatsheet](docs/BINDINGS.md) — every `:Git` subcommand and
  keymap, generated from the same route tree that drives dispatch and
  completion.

`:help gitsuite` is the same reference inside the editor.

More documentation (requirements, installation, quickstart, full
configuration reference, architecture) lands as the corresponding features
do — see the cheatsheet above for what is implemented today versus what is
still a stub.

---

## License

gitsuite.nvim is released under the [MIT License](https://opensource.org/licenses/MIT) — see [LICENSE](LICENSE).
