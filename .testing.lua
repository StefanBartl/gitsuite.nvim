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
    -- "error": the suite leaves no state behind. Every spec that opens windows or buffers closes and wipes
    -- them (TESTS/gitsuite/editor_scope.lua). `keep` names what is the plugin's own on purpose and lives as
    -- long as its module (under isolated = "file" it dies with the spec file's editor):
    --   * setup() is one-shot (later calls are no-ops): the :Git tree, :GitsuiteLazygit{Badd,Replace}, the
    --     default <leader> keymaps (\dc \dh \di \dv \gb \lg) and the gitsuite_conflict_scan autocmds; a spec
    --     that deleted them would leave the next one a plugin that believes it is set up. menu_spec
    --     registers the tree under a custom name (:MyGit) the same way.
    --   * module-load autocmds: gitsuite_statusline (BufWipeout cache), GitsuiteDashboardHighlights and
    --     gitsuite_plugins_report_hl (ColorScheme re-link), lib.nvim's lib_kit_toast_resize (VimResized):
    --     the module stays in package.loaded, deleting its group would break it for the rest of the file.
    state = {
      mode = "error",
      keep = {
        "Git",
        "MyGit",
        -- Exact names: keep entries match as prefixes, "gitsuite_" would also hide the groups one open
        -- creates (gitsuite_plugins_report, gitsuite_lazy_sync, gitsuite_blame_<n>).
        "gitsuite_conflict_scan",
        "gitsuite_statusline",
        "gitsuite_plugins_report_hl",
        "lib_kit_toast_resize",
        "\\dc",
        "\\dh",
        "\\di",
        "\\dv",
        "\\gb",
        "\\lg",
      },
    },
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    -- Every spawn of the suite is `git`, allowed below; anything else is a new, unexpected process.
    process_net = "error",
  },
  guard_allow = {
    -- The specs build temporary repositories and test the plugin's git wrappers (`git init`, `commit`,
    -- `rev-parse`, `blame`, `diff`): about 500 spawns in 53 files.
    -- sheets_spec.lua: every test sheet (TESTS/sheets/) runs in a child editor.
    spawn = { "git", "nvim" },
  },
  -- The runner counts which commands, keymaps and autocommands the specs exercise (docs/SURFACE.md of testing.nvim);
  -- `scripts/test.sh surface` compares that with surface.baseline.json (a regression gate, not a percentage).
  surface = { track = true },
  -- gated: a failed conformance check makes `scripts/test.sh conformance` exit 1 (docs/CONFORMANCE.md of testing.nvim)
  conformance = {
    gate = true,
    waivers = {
      {
        check = "K1",
        level = "warn",
        file = "lua/gitsuite/features/dashboard/view.lua",
        reason = "loaded lazily (only when the dashboard opens); the ColorScheme autocmd belongs to the highlights it defines at load, moving either would change when they exist",
        expires = "2027-04-14",
      },
      {
        check = "K1",
        level = "warn",
        file = "lua/gitsuite/statusline.lua",
        reason = "only loaded because the user put the component in their statusline; the BufDelete cache cleanup must start with it (no setup() exists)",
        expires = "2027-04-14",
      },
    },
  },
}
