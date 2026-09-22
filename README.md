> **Alpha stage — active development.** Every `:Git` subcommand is a real
> implementation (see [docs/BINDINGS.md](docs/BINDINGS.md) for the full
> list), but the surface is not frozen: breaking changes are still
> possible. Pin a commit if you depend on it.

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

Start at [docs/README.md](docs/README.md) — what's where, and which
question each page answers.

**The Basics**

- [Requirements](docs/requirements.md) — hard dependencies, optional tools, and what each one backs.
- [Installation](docs/installation.md) — a spec per plugin manager.
- [Quickstart](docs/quickstart.md) — the first thing to run after installing.

**Configuration**

- [What you get with the defaults](docs/what-you-get.md) — the handful of things that matter on day one.
- [All options](docs/configuration.md) — every `setup()` option and its default.
- [Commands](docs/commands.md) / [Bindings cheatsheet](docs/BINDINGS.md)

**The Rest**

- [Around it](docs/around-it.md) — how this plugin's scope differs from the plugins it sits next to or replaces.
- [What it does and what not](docs/scope.md)
- [Why it does it that way](docs/architecture.md)
- [Health check](docs/health.md) — what `:checkhealth gitsuite` reports, line by line.
- [Cross-platform notes](docs/cross-platform.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Feedback](https://github.com/StefanBartl/gitsuite.nvim/issues)

`:help gitsuite` is the same reference inside the editor.

---

## License

gitsuite.nvim is released under the [MIT License](https://opensource.org/licenses/MIT) — see [LICENSE](LICENSE).
