-- .testing.lua -- configuration of testing.nvim for this project.
-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the
-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "gitsuite",
  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project's own TESTS/harness.lua,
  -- "script" = a self-running script in its own process.
  dialect = "auto",
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>.
  deps = { "diff.nvim", "lib.nvim", "ui.nvim" },
  -- "none" = all specs in one nvim, "file" = one nvim per spec file.
  isolated = "file",
  -- "c" = child started from a -c command (v:vim_did_enter is 0), "l" = `nvim -l` like the old runner.
  host = "c",
  -- Limits per case in milliseconds (the slowest spec file takes about 21 s).
  timeouts = { case_ms = 30000 },
  -- Safety nets (docs/GUARDS.md). "error" = the suite passes them cleanly, so a regression fails the run.
  guards = {
    -- Real finding, kept at "warn": browse_spec, lazygit_bridge_spec and status_spec write scratch files
    -- (`__gitsuite_*_scratch.md`) into the live repo root instead of a tempname() directory; running files
    -- in parallel can even see each other's file.
    fs = "warn",
    -- "warn": diff_spec and hunk_spec leave kit floating windows and their autocmd groups/timers open (real);
    -- the css* highlight groups and the 'syntax' option are runtime noise of loading a filetype (not a leak).
    -- The plugin's own setup() state (commands, keymaps, autocmds) is harmless under isolated = "file".
    state = "warn",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    -- Every spawn of the suite is `git`, allowed below; anything else is a new, unexpected process.
    process_net = "error",
  },
  guard_allow = {
    -- The specs build temporary repositories and test the plugin's git wrappers (`git init`, `commit`,
    -- `rev-parse`, `blame`, `diff`): about 500 spawns in 53 files.
    spawn = { "git" },
  },
}
