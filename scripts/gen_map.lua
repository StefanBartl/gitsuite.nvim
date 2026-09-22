---@module 'scripts.gen_map'
--- CLI entry point for this repository's own module map (NEW-19/NEW-20).
---
---   nvim --headless -l scripts/gen_map.lua                    # regenerate
---   nvim --headless -l scripts/gen_map.lua --check            # verify, write nothing
---   nvim --headless -l scripts/gen_map.lua --check --lenient  # fail on staleness only
---   nvim --headless -l scripts/gen_map.lua --full             # + LuaLS enrichment
---
--- Copied from documentation.nvim's own scripts/gen_map.lua per docs/reuse.md
--- ("copy verbatim, change only the options table") -- everything above the
--- options table below is generic dependency resolution, not gitsuite-specific.
---
--- `docs/map/` is deliberately NOT committed (see .gitignore): a committed
--- copy is stale the moment anything it describes changes, and no CI gate
--- here compares it -- see documentation.nvim's own NEW-20 addendum about why
--- a `--check` gate only belongs where the map IS committed. This script is
--- for local/editor use (`:DocMap` once documentation.nvim is installed, or
--- this headless entry point without it).

local root = vim.uv.cwd():gsub("\\", "/"):gsub("/+$", "")
vim.opt.runtimepath:prepend(root)

--- Put a dependency on the runtimepath, if it is not already reachable.
---@param modname string A module the dependency provides, used as the probe.
---@param dirname string Repository directory name.
local function ensure(modname, dirname)
  if pcall(require, modname) then return end
  local candidates = {}
  local env_dir = vim.env[dirname:upper():gsub("[.-]", "_") .. "_DIR"]
  if env_dir and env_dir ~= "" then candidates[#candidates + 1] = env_dir end
  candidates[#candidates + 1] = root .. "/.deps/" .. dirname
  candidates[#candidates + 1] = vim.fs.dirname(root) .. "/" .. dirname
  for _, dir in ipairs(candidates) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.opt.runtimepath:prepend(dir)
      if pcall(require, modname) then return end
    end
  end
  io.stderr:write(("gen_map: %s not found (probed require('%s')).\n"):format(dirname, modname))
  io.stderr:write(
    ("  Set %s_DIR, clone it to .deps/%s, or check it out beside this repo.\n"):format(
      dirname:upper():gsub("[.-]", "_"),
      dirname
    )
  )
  os.exit(1)
end

ensure("lib.nvim.fs.read", "lib.nvim")
ensure("documentation.core.cli", "documentation.nvim")

--- Where `config.build`'s degradation warnings go in this host (stderr, not
--- stdout: stdout carries the run's own report).
local notify = {
  warn = function(msg)
    io.stderr:write("gen_map: " .. tostring(msg) .. "\n")
  end,
}

local opts = require("documentation.config").build(root, {
  source = "lua/gitsuite",
  title = "gitsuite.nvim",
  out_dir = "docs/map",
  repo_url = "https://github.com/StefanBartl/gitsuite.nvim",
  branch = "main",
}, notify)

local code = require("documentation.core.cli").run(opts, _G.arg or {})

vim.cmd("cq " .. code)
