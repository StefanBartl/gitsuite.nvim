-- TESTS/gitsuite/lazygit_float_spec.lua -- the own lazygit float (no terminal.nvim) goes through
-- lib.nvim.terminal.spawn: argv and options, the terminal-mode keymaps from on_open, and the error
-- message when the process does not start. spawn itself is stubbed: no lazygit is needed.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
describe("gitsuite.features.ui.lazygit own float", function()
  local lazygit, libterm, notify_mod
  local real = {}
  local calls, errors

  before_each(function()
    calls, errors = {}, {}
    libterm = require("lib.nvim.terminal")
    notify_mod = require("gitsuite.util.notify")
    real.spawn, real.executable, real.error = libterm.spawn, vim.fn.executable, notify_mod.error
    real.terminal = package.loaded["terminal"]
    package.loaded["terminal"] = nil
    package.preload["terminal"] = function()
      error("terminal.nvim is not installed in this spec")
    end
    vim.fn.executable = function(name)
      if name == "lazygit" then return 1 end
      return real.executable(name)
    end
    notify_mod.error = function(msg)
      errors[#errors + 1] = msg
    end
    package.loaded["gitsuite.features.ui.lazygit"] = nil
    lazygit = require("gitsuite.features.ui.lazygit")
  end)

  after_each(function()
    libterm.spawn, vim.fn.executable, notify_mod.error = real.spawn, real.executable, real.error
    package.preload["terminal"] = nil
    package.loaded["terminal"] = real.terminal
  end)

  it("starts lazygit in a float that closes on exit and maps the terminal keys", function()
    libterm.spawn = function(opts)
      calls[#calls + 1] = opts
      local bufnr = vim.api.nvim_create_buf(false, true)
      calls.bufnr = bufnr
      opts.on_open(bufnr, 0, 1)
      return { bufnr = bufnr, winid = 0, job = 1 }
    end
    lazygit.open()

    assert.equals(1, #calls)
    local opts = calls[1]
    assert.equals("lazygit", vim.fn.fnamemodify(opts.argv[1], ":t:r"))
    assert.equals("float", opts.layout)
    assert.equals("always", opts.close_on_exit)
    assert.equals(" lazygit ", opts.title)
    assert.is_truthy(opts.cwd and opts.cwd ~= "")
    assert.is_true(
      #vim.api.nvim_buf_get_keymap(calls.bufnr, "t") > 0,
      "on_open put the terminal-mode keymaps on the buffer"
    )
    assert.same({}, errors)
    vim.api.nvim_buf_delete(calls.bufnr, { force = true })
  end)

  it("names the failure when the process does not start", function()
    libterm.spawn = function(opts)
      calls[#calls + 1] = opts
      return nil, "failed to start lazygit"
    end
    lazygit.open()
    assert.equals(1, #calls)
    assert.same({ "ui lazygit: failed to start lazygit" }, errors)
  end)
end)
