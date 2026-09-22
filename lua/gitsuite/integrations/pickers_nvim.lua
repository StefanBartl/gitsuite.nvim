---@module 'gitsuite.integrations.pickers_nvim'
--- Optional pickers.nvim bridge (LUA-05: the one module that knows
--- pickers.nvim exists -- `gitsuite.features.branch.switch()` degrades to
--- `vim.ui.select` when it is missing or no engine resolves).
---
--- `pickers.builtins.run("git_branches", opts, engine_name)` dispatches
--- straight into the resolved engine's own native picker
--- (`Snacks.picker.git_branches`, `telescope.builtin.git_branches`,
--- `fzf-lua.git_branches`), including that engine's own "confirm ->
--- `git checkout`" default action. This module overrides that default so
--- the checkout runs through gitsuite's own `on_confirm` instead (gitsuite's
--- own error handling, and once GS-06 lands, `GitsuiteBranchSwitched`) --
--- each engine exposes the override through a differently-shaped opts field,
--- verified against the three installed engines' sources, not guessed from
--- docs:
---   snacks:    opts.confirm          a function replaces the "git_checkout" default.
---   telescope: opts.attach_mappings  runs AFTER the picker's own default
---              (`pickers.new` composes both), so replacing
---              `actions.select_default` inside it wins.
---   fzf-lua:   opts.actions["enter"] deep-merged over the default actions table.

local M = {}

---Whether pickers.nvim is installed (an engine may still fail to resolve at
---call time -- `branch_picker()` reports that separately via its return).
---@return boolean
function M.available()
  local ok_engines = pcall(require, "pickers.engines")
  local ok_builtins = pcall(require, "pickers.builtins")
  return ok_engines and ok_builtins
end

---@internal
---@param item table|nil  A snacks picker item (has `.branch`/`.commit`).
---@return string|nil
local function snacks_branch_of(item)
  return item and (item.branch or item.commit) or nil
end

---@internal
---Build the engine-specific opts that override `git_branches`' default
---checkout action to call `on_confirm(branch)` instead.
---@param engine_name string  "snacks"|"telescope"|"fzf"
---@param on_confirm fun(branch: string)
---@return table|nil opts  nil for an engine this module does not know how to override
local function confirm_opts(engine_name, on_confirm)
  if engine_name == "snacks" then
    return {
      confirm = function(picker, item)
        picker:close()
        local branch = snacks_branch_of(item)
        if branch then on_confirm(branch) end
      end,
    }
  elseif engine_name == "telescope" then
    return {
      attach_mappings = function(prompt_bufnr, _map)
        local actions = require("telescope.actions")
        local state = require("telescope.actions.state")
        actions.select_default:replace(function()
          local selection = state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection and selection.value then on_confirm(selection.value) end
        end)
        return true
      end,
    }
  elseif engine_name == "fzf" then
    return {
      actions = {
        ["enter"] = function(selected)
          local line = selected and selected[1]
          -- Same match the engine's own preview uses to pull a branch name
          -- out of `git branch -vv` output ("* branch", "  branch",
          -- "  remotes/origin/branch", "(HEAD detached at ...)").
          local branch = line and line:match("^[%*+]*%s*%(?([^%s)]+)")
          if branch then on_confirm(branch) end
        end,
      },
    }
  end
  return nil
end

---Open the `git_branches` picker via pickers.nvim, with preview, routing the
---confirmed selection through `on_confirm` instead of the engine's own
---checkout.
---@param on_confirm fun(branch: string)
---@return boolean ok  false when pickers.nvim is missing, no engine resolved,
---or the resolved engine has no known override -- caller should fall back.
function M.branch_picker(on_confirm)
  local ok_engines, engines = pcall(require, "pickers.engines")
  if not ok_engines then return false end
  local mod, engine_name = engines.load()
  if not mod or not engine_name then return false end

  local ok_builtins, builtins = pcall(require, "pickers.builtins")
  if not ok_builtins then return false end

  local opts = confirm_opts(engine_name, on_confirm)
  if not opts then return false end

  builtins.run("git_branches", opts, engine_name)
  return true
end

return M
