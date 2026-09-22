---@module 'gitsuite.bindings.keymaps'
--- Keymap registration for gitsuite.nvim, via `lib.nvim.bindings.keymap`'s
--- registry (PRINCIPLES.md "Keymaps als Daten"): default lhs per action,
--- individually overridable/disableable through `cfg.keymaps`, plus a global
--- master switch (`cfg.keymaps == false`). Which key ultimately fires which
--- `:Git ...` subcommand comes straight from `cfg.commands.git`, so a
--- renamed command name never desyncs from the keymap.

local M = {}

---@internal
---@type table<string, { command_args: string, feature: string, label: string }>
local ACTIONS = {
  blame_full = {
    command_args = "blame full",
    feature = "blame",
    label = "[gitsuite.nvim] Blame (full)",
  },
  ui_lazygit = {
    command_args = "ui lazygit",
    feature = "ui",
    label = "[gitsuite.nvim] Open lazygit",
  },
  hunk_inline = {
    command_args = "hunk inline",
    feature = "hunk",
    label = "[gitsuite.nvim] Toggle inline diff",
  },
  diffview_open = {
    command_args = "ui diffview open",
    feature = "ui",
    label = "[gitsuite.nvim] Open diffview",
  },
  diffview_close = {
    command_args = "ui diffview close",
    feature = "ui",
    label = "[gitsuite.nvim] Close diffview",
  },
  diff_history = {
    command_args = "diff history",
    feature = "diff",
    label = "[gitsuite.nvim] Diff history",
  },
}

---Declare and bind the default keymaps.
---@param cfg GitSuite.Config
---@return Lib.Keymap.Registered[]|nil
function M.register(cfg)
  local keymaps = cfg.keymaps
  if type(keymaps) ~= "table" then return end

  local notify = require("gitsuite.util.notify")
  local keymap = require("lib.nvim.bindings.keymap")
  local verb = cfg.commands.git

  local accepted = vim.tbl_keys(ACTIONS)
  table.sort(accepted)

  ---@type table<string, Lib.Keymap.Action>
  local actions = {}
  for name, spec in pairs(ACTIONS) do
    actions[name] = {
      rhs = ("<Cmd>%s %s<CR>"):format(verb, spec.command_args),
      desc = spec.label,
      opts = { silent = true },
    }
  end

  ---@type table<string, string|false>
  local user = {}
  for name, lhs in pairs(keymaps) do
    if lhs and lhs ~= "" then
      local spec = ACTIONS[name]
      if not spec then
        notify.warn(
          ("Unknown keymaps.%s -- ignoring. Accepted: %s"):format(
            tostring(name),
            table.concat(accepted, ", ")
          )
        )
      elseif not cfg.features[spec.feature] then
        notify.warn(
          ("keymaps.%s needs features.%s, which is off -- not registering"):format(
            name,
            spec.feature
          )
        )
        user[name] = false
      else
        user[name] = lhs
      end
    end
  end

  return keymap.register("gitsuite", { order = accepted, actions = actions }, user)
end

return M
