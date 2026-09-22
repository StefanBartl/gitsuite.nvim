# gitsuite.nvim documentation

What is here, and which question each page answers.
[The README](../README.md) is the short version of all of it.

## Getting it running

| Page | Answers |
| --- | --- |
| [requirements.md](requirements.md) | What has to be there first — hard dependencies, optional tools, and what each one backs |
| [installation.md](installation.md) | A spec per plugin manager |
| [quickstart.md](quickstart.md) | The first thing to run after installing |
| [configuration.md](configuration.md) | Every `setup()` option and its default |
| [health.md](health.md) | What `:checkhealth gitsuite` reports, line by line |

## Using it

| Page | Answers |
| --- | --- |
| [what-you-get.md](what-you-get.md) | The handful of things worth knowing on day one |
| [BINDINGS.md](BINDINGS.md) | Every `:Git` subcommand and keymap, generated from the route tree |
| [commands.md](commands.md) | How the `:Git <scope> <action>` tree itself works, and how to rename it |
| [integrations.md](integrations.md) | The context-menu contributor and the pickers.nvim branch-switch bridge |
| [statusline.md](statusline.md) | The merge-conflict statusline component and how to wire it up |
| [lazygit-config.yml](lazygit-config.yml) | The `customCommands` behind `:Git ui lazygit`'s `O`/`<C-o>` bridge |

## Why it is the way it is

| Page | Answers |
| --- | --- |
| [scope.md](scope.md) | What gitsuite.nvim does and does not do |
| [around-it.md](around-it.md) | How it relates to gitsigns, diffview, neogit, fugitive/rhubarb, git-conflict.nvim, lazygit.nvim, reposcope.nvim and insights.nvim specifically |
| [architecture.md](architecture.md) | Why the adapter/native split falls where it does, and the dependency-direction rule behind it |
| [cross-platform.md](cross-platform.md) | What is and isn't verified across Linux, Windows and macOS |

## Working on it

| Page | Answers |
| --- | --- |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Ground rules, project layout, and how to add a scope or an adapter |
