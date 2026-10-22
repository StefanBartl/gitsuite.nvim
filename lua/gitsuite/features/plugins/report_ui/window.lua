---@module 'gitsuite.features.plugins.report_ui.window'
--- The report tab: a list window and a preview window in a tab of their own.
---
---   * Two buffers, made once per Neovim and kept (`bufhidden=hide`): the tab
---     can be closed (`q`, `:tabclose`, `:tabonly`) and `:Git plugins` builds it
---     again around the same buffers, keymaps and model, the cursor on the same
---     plugin or commit (found by key, never by line number).
---   * `winfixbuf` on both windows: `:bnext` or a picker cannot swap another
---     buffer into them. The tab never swaps its own buffers either; only
---     `close` in the last tab hands the window back (and unfixes it first).
---   * Preview to the right from `WIDE` columns on, below otherwise; it follows
---     the cursor. Closing the list closes the preview; closing only the preview
---     turns it off until `p`.
---
--- Rendering is `render.lua`'s; this module only puts its lines, highlights
--- and the cursor into the windows.

local keys = require("gitsuite.features.plugins.report_ui.keys")
local model = require("gitsuite.features.plugins.report_ui.model")
local render = require("gitsuite.features.plugins.report_ui.render")

local M = {}

---From this many editor columns on the preview is to the right of the list.
M.WIDE = 140

---Share of the tab the preview takes.
local PREVIEW_SHARE = 0.55

M.LIST_NAME = "gitsuite://plugins/report"
M.PREVIEW_NAME = "gitsuite://plugins/preview"

local NS = vim.api.nvim_create_namespace("gitsuite_plugins_report")
local AUGROUP = "gitsuite_plugins_report"

---@class GitSuite.ReportUi.State
---@field model? GitSuite.ReportUi.Model
---@field list_buf? integer
---@field preview_buf? integer
---@field tab? integer
---@field list_win? integer
---@field preview_win? integer
---@field preview_on boolean
---@field origin_tab? integer  The tab the report was opened from (`q` goes back there).
---@field cursor? GitSuite.ReportUi.Item  The key under the cursor, for the rebuild.
---@field rendered? GitSuite.ReportUi.Rendered
---@field loader? GitSuite.ReportUi.PreviewLoader
---@field gen? integer  Counts the tab's (re)builds: a scheduled callback from before one is stale.
---@field unsaved? table<string, boolean>  Seen marks the file did not take (kept for this session).
---@field seen_path? string  The marks file (nil: the default; specs set one).

---@type GitSuite.ReportUi.State
local S = { preview_on = true }

---For specs: the state, read only.
---@return GitSuite.ReportUi.State
function M.state()
  return S
end

---@param win integer|nil
---@return boolean
local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param buf integer|nil
---@return boolean
local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param name string
---@param filetype string
---@return integer
local function make_buf(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  local bo = vim.bo[buf]
  bo.buftype = "nofile"
  bo.bufhidden = "hide"
  bo.swapfile = false
  bo.modifiable = false
  bo.filetype = filetype
  return buf
end

---@param win integer
local function style_win(win)
  local wo = vim.wo[win]
  wo.winfixbuf = true
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.spell = false
  wo.list = false
end

---Write `rendered` into `buf`: lines, then the highlights as extmarks.
---@param buf integer
---@param rendered GitSuite.ReportUi.Rendered
local function paint(buf, rendered)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, mk in ipairs(rendered.marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, mk.line, mk.col, {
      end_col = mk.end_col,
      hl_group = mk.hl,
    })
  end
end

---The item under the list window's cursor.
---@return GitSuite.ReportUi.Item|nil
local function item_at_cursor()
  if not valid_win(S.list_win) or not S.rendered then return nil end
  local line = vim.api.nvim_win_get_cursor(S.list_win)[1]
  return S.rendered.items[line]
end

---The first line worth putting the cursor on: the first plugin or commit.
---@param rendered GitSuite.ReportUi.Rendered
---@return integer
local function first_item_line(rendered)
  for i = 1, #rendered.lines do
    local k = rendered.items[i].kind
    if k == "plugin" or k == "commit" then return i end
  end
  return math.min(3, #rendered.lines)
end

---The preview's file loader (one per Neovim; `M.set_loader` for specs).
---@return GitSuite.ReportUi.PreviewLoader
local function loader()
  if not S.loader then S.loader = require("gitsuite.features.plugins.report_ui.preview").new() end
  return S.loader
end

---For specs: the seen-marks file to write.
---@param path string|nil
function M.set_seen_path(path)
  S.seen_path = path
end

---For specs: use `l` as the file loader.
---@param l GitSuite.ReportUi.PreviewLoader
function M.set_loader(l)
  S.loader = l
end

local update_preview

---Fill the preview from the item under the cursor. The file list is asked for
---when it is not cached; its answer redraws the preview only if the cursor is
---still on that commit.
update_preview = function()
  if not valid_win(S.preview_win) or not valid_buf(S.preview_buf) or not S.model then return end
  local it = item_at_cursor()
  local rendered
  if it and it.kind == "commit" then
    local entry = model.entry(S.model, it.name)
    local files = entry and entry.dir and loader():cached(entry.dir, it.sha) or nil
    if entry and entry.dir and not files then
      loader():request(entry.dir, it.sha, function()
        local now = item_at_cursor()
        if now and now.sha == it.sha and now.name == it.name then update_preview() end
      end)
      -- An answer that came at once (a value that is no hash) is what to draw.
      files = loader():cached(entry.dir, it.sha)
    end
    rendered = render.render_preview(S.model, it.name, it.sha, files or "loading")
  else
    rendered = {
      lines = { "Move to a commit to see its message here" },
      marks = { { line = 0, col = 0, end_col = 41, hl = "GitSuitePluginsDim" } },
      items = { { kind = "blank" } },
    }
  end
  paint(S.preview_buf, rendered)
end

---Render the model into the list and put the cursor on `key` (or keep it on
---what it was on).
---@param key? GitSuite.ReportUi.Item
function M.redraw(key)
  if not valid_buf(S.list_buf) or not S.model then return end
  key = key or item_at_cursor() or S.cursor
  local rendered = render.render(S.model)
  S.rendered = rendered
  paint(S.list_buf, rendered)
  if valid_win(S.list_win) then
    local line = key and render.find(rendered, { name = key.name, sha = key.sha }) or nil
    line = line or first_item_line(rendered)
    pcall(vim.api.nvim_win_set_cursor, S.list_win, { line, 0 })
    S.cursor = rendered.items[line]
    vim.cmd.redrawstatus()
  end
  update_preview()
end

---The winbar legend of the list window (called by the `winbar` expression).
---@return string
function M.legend()
  local view = S.model and S.model.view.kind or "overview"
  local width = valid_win(S.list_win) and vim.api.nvim_win_get_width(S.list_win) or vim.o.columns
  return "%#GitSuitePluginsDim#" .. keys.legend(view, width):gsub("%%", "%%%%")
end

local WINBAR = "%!v:lua.require'gitsuite.features.plugins.report_ui.window'.legend()"

---Open the preview window next to the list, right or below by the width.
local function open_preview()
  if valid_win(S.preview_win) or not valid_win(S.list_win) then return end
  local wide = vim.o.columns >= M.WIDE
  local cfg = { split = wide and "right" or "below", win = S.list_win }
  if wide then
    cfg.width = math.floor(vim.api.nvim_win_get_width(S.list_win) * PREVIEW_SHARE)
  else
    cfg.height = math.floor(vim.api.nvim_win_get_height(S.list_win) * PREVIEW_SHARE)
  end
  local ok, win = pcall(vim.api.nvim_open_win, S.preview_buf, false, cfg)
  if not ok then return end
  S.preview_win = win
  style_win(win)
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = false
  update_preview()
end

---@param win integer|nil
local function close_win(win)
  if valid_win(win) then pcall(vim.api.nvim_win_close, win, true) end
end

---Hand `win` back to the user: not fixed, an empty buffer, no legend. For a
---report window that cannot be closed because it is the last one.
---@param win integer
local function release(win)
  if not valid_win(win) then return end
  vim.wo[win].winfixbuf = false
  vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
  vim.wo[win].winbar = ""
  vim.wo[win].cursorline = false
end

---Whether the report tab still exists.
---@return boolean
local function tab_alive()
  return S.tab ~= nil and vim.api.nvim_tabpage_is_valid(S.tab)
end

---@type table<string, fun(lhs: string)>
local ACTIONS = {}

---@param fn fun(m: GitSuite.ReportUi.Model): GitSuite.ReportUi.Model
---@param key? GitSuite.ReportUi.Item
local function step(fn, key)
  S.model = fn(S.model)
  M.redraw(key)
end

ACTIONS.open = function()
  local it = item_at_cursor()
  if not it or not it.name then return end
  if it.kind == "plugin" and S.model.view.kind ~= "detail" then
    step(function(m)
      return model.show(m, { kind = "detail", name = it.name })
    end, { kind = "plugin", name = it.name })
  elseif it.kind == "commit" and S.model.view.kind == "digest" then
    step(function(m)
      return model.show(m, { kind = "detail", name = it.name })
    end, it)
  end
end

ACTIONS.back = function()
  local name = S.model.view.kind == "detail" and S.model.view.name or nil
  local it = item_at_cursor()
  step(function(m)
    return model.show(m, { kind = "overview" })
  end, { kind = "plugin", name = name or (it and it.name) })
end

ACTIONS.digest = function()
  step(function(m)
    return model.show(m, { kind = "digest" })
  end, item_at_cursor())
end

ACTIONS.sort = function()
  step(model.next_sort)
end

ACTIONS.all = function()
  step(model.toggle_all)
end

ACTIONS.plugin = function(lhs)
  step(function(m)
    return model.step_plugin(m, lhs == "[[" and -1 or 1)
  end, nil)
  -- A new plugin: start at its top, not at a commit of the last one.
  if S.rendered and valid_win(S.list_win) then
    pcall(vim.api.nvim_win_set_cursor, S.list_win, { first_item_line(S.rendered), 0 })
    update_preview()
  end
end

ACTIONS.breaking = function(lhs)
  if not S.rendered or not valid_win(S.list_win) then return end
  local n = #S.rendered.lines
  local here = vim.api.nvim_win_get_cursor(S.list_win)[1]
  local dir = lhs == "[b" and -1 or 1
  for k = 1, n do
    local i = (here - 1 + dir * k) % n + 1
    local it = S.rendered.items[i]
    if
      it.kind == "commit"
      and (it.tier == "sure" or it.tier == "probable")
      and not model.is_seen(S.model, it.name, it.sha)
    then
      vim.api.nvim_win_set_cursor(S.list_win, { i, 0 })
      S.cursor = it
      update_preview()
      return
    end
  end
  require("gitsuite.util.notify").info("plugins report: no unseen breaking commit in this view")
end

---Write `keys` as seen (or not) to the model and to the marks file. A file
---that cannot be written keeps the marks for this session and says so.
---@param pairs_ { name: string, sha: string }[]
---@param on boolean
local function set_seen(pairs_, on)
  if #pairs_ == 0 then return end
  S.model = model.mark(S.model, pairs_, on)
  -- Marks an earlier write could not take go along again.
  local changes = vim.tbl_extend("force", {}, S.unsaved or {})
  for _, k in ipairs(pairs_) do
    changes[model.seen_key(k.name, k.sha)] = on
  end
  local _, err =
    require("gitsuite.features.plugins.report_ui.seen").update(changes, { path = S.seen_path })
  if err then
    S.unsaved = changes
    require("gitsuite.util.notify").warn("plugins report: " .. err .. " (kept for this session)")
  else
    S.unsaved = nil
  end
  M.redraw()
end

ACTIONS.mark = function()
  local it = item_at_cursor()
  if not it or not it.name then return end
  local entry = model.entry(S.model, it.name)
  if not entry then return end
  local list
  if it.kind == "commit" then
    local new = false
    for _, k in ipairs(model.commit_keys(S.model, entry)) do
      if k.sha == it.sha then new = true end
    end
    if not new then
      require("gitsuite.util.notify").info(
        "plugins report: a removed commit is not new; there is nothing to mark"
      )
      return
    end
    list = { { name = it.name, sha = it.sha } }
  else
    list = model.commit_keys(S.model, entry)
  end
  local all_seen = true
  for _, k in ipairs(list) do
    if not model.is_seen(S.model, k.name, k.sha) then all_seen = false end
  end
  set_seen(list, not all_seen)
end

ACTIONS.mark_all = function()
  local list = {}
  if S.model.view.kind == "digest" then
    for i = 1, #S.rendered.lines do
      local it = S.rendered.items[i]
      if it.kind == "commit" then list[#list + 1] = { name = it.name, sha = it.sha } end
    end
  elseif S.model.view.kind == "detail" then
    local entry = model.entry(S.model, S.model.view.name)
    list = entry and model.commit_keys(S.model, entry) or {}
  else
    for _, entry in ipairs(model.entries(S.model)) do
      vim.list_extend(list, model.commit_keys(S.model, entry))
    end
  end
  set_seen(list, true)
end

local function notify_info(msg)
  require("gitsuite.util.notify").info("plugins report: " .. msg)
end

---Run `fn` in the tab the report was opened from (a new tab when that one is
---gone), so files and lists never land in the report's own windows.
---@param fn fun()
local function in_origin(fn)
  local origin = S.origin_tab
  if origin and vim.api.nvim_tabpage_is_valid(origin) and origin ~= S.tab then
    vim.api.nvim_set_current_tabpage(origin)
  else
    vim.cmd("tabnew")
  end
  fn()
end

---@param compare? boolean
local function browse(compare)
  local actions = require("gitsuite.features.plugins.report_ui.actions")
  local url, err, seen_now = actions.url(S.model, item_at_cursor(), compare)
  if not url then return notify_info(err or "nothing to open") end
  local ok, open_err = require("gitsuite.features.plugins.links").open(url)
  if not ok then return notify_info("could not open the browser: " .. tostring(open_err)) end
  -- What was opened was looked at (the user's decision of 2026-10-22).
  local unseen = {}
  for _, k in ipairs(seen_now) do
    if not model.is_seen(S.model, k.name, k.sha) then unseen[#unseen + 1] = k end
  end
  set_seen(unseen, true)
end

ACTIONS.browser = function()
  browse(false)
end

ACTIONS.compare = function()
  browse(true)
end

ACTIONS.copy_url = function()
  local actions = require("gitsuite.features.plugins.report_ui.actions")
  local url, err = actions.url(S.model, item_at_cursor(), false)
  if not url then return notify_info(err or "no URL here") end
  if require("gitsuite.features.plugins.view").copy(url) then notify_info("copied " .. url) end
end

ACTIONS.yank = function(lhs)
  local actions = require("gitsuite.features.plugins.report_ui.actions")
  local h = actions.hash(S.model, item_at_cursor(), lhs == "Y")
  if not h then return notify_info("no commit here") end
  if require("gitsuite.features.plugins.view").copy(h) then notify_info("copied " .. h) end
end

---The entry of the line under the cursor, or a message.
---@return GitSuite.Plugins.ReportEntry|nil
local function entry_here()
  local actions = require("gitsuite.features.plugins.report_ui.actions")
  local entry = actions.target(S.model, item_at_cursor())
  if not entry or type(entry.dir) ~= "string" then
    notify_info("put the cursor on a plugin or a commit")
    return nil
  end
  return entry
end

ACTIONS.lazygit = function()
  local entry = entry_here()
  if entry then require("gitsuite.features.ui.lazygit").open(entry.dir) end
end

ACTIONS.status = function()
  local entry = entry_here()
  if not entry then return end
  local actions = require("gitsuite.features.plugins.report_ui.actions")
  actions.status(entry.dir, function(body)
    local name = require("gitsuite.features.plugins.text").one_line(entry.name)
    local lines = { "", " " .. name, "" }
    vim.list_extend(lines, body)
    lines[#lines + 1] = ""
    lines[#lines + 1] = " q / <Esc>  close"
    require("ui.kit").viewer({
      lines = lines,
      title = "git status",
      filetype = "gitsuite-plugins-status",
    })
  end)
end

ACTIONS.changelog = function()
  local entry = entry_here()
  if not entry then return end
  local path = require("gitsuite.features.plugins.report_ui.actions").changelog(entry.dir)
  if not path then return notify_info("no CHANGELOG at the top of " .. entry.name) end
  in_origin(function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    -- Somebody else's file: read only, so a stray key cannot change the clone.
    vim.bo.readonly = true
    vim.bo.modifiable = false
  end)
end

ACTIONS.quickfix = function()
  local items = require("gitsuite.features.plugins.report_ui.actions").breaking_items(S.model)
  if #items == 0 then return notify_info("no breaking commit in this report") end
  vim.fn.setqflist({}, " ", { title = "gitsuite plugins: breaking commits", items = items })
  in_origin(function()
    vim.cmd("copen")
  end)
end

---Show the line of `key` (a plugin or a commit): the detail of its plugin,
---cursor on it.
---@param key { name: string, sha?: string }
function M.jump(key)
  if not S.model or not model.entry(S.model, key.name) then return end
  S.model = model.show(S.model, { kind = "detail", name = key.name })
  if valid_win(S.list_win) then vim.api.nvim_set_current_win(S.list_win) end
  M.redraw({ kind = key.sha and "commit" or "plugin", name = key.name, sha = key.sha })
end

---The picker's entries: every changed plugin and each of its new commits.
---@return { name: string, sha?: string, label: string }[]
function M.find_items()
  local text = require("gitsuite.features.plugins.text")
  local items = {}
  for _, entry in ipairs(model.entries(S.model)) do
    items[#items + 1] = { name = entry.name, label = text.one_line(entry.name) }
    for _, c in ipairs(model.summary(S.model, entry).commits) do
      items[#items + 1] = {
        name = entry.name,
        sha = c.sha,
        label = ("%s  %s  %s"):format(
          text.one_line(entry.name),
          c.sha:sub(1, 7),
          text.one_line(c.subject or "")
        ),
      }
    end
  end
  return items
end

ACTIONS.find = function()
  require("ui.kit").picker({
    title = "plugins report",
    items = M.find_items(),
    key = function(x)
      return x.name .. "@" .. (x.sha or "")
    end,
    text = function(x)
      return x.label
    end,
    format = function(x)
      return { { x.label, x.sha and "Normal" or "Title" } }
    end,
    on_submit = function(_, _, x)
      if x then M.jump({ name = x.name, sha = x.sha }) end
    end,
  })
end

---The menu's entries for the line under the cursor: the actions of the keys
---that work in this view, named with their first key.
---@return { label: string, action: fun() }[]
function M.menu_items()
  local out = {}
  for _, k in ipairs(keys.KEYS) do
    if k.action ~= "menu" and keys.applies(k, S.model.view.kind) then
      local lhs = k.keys[1]
      out[#out + 1] = {
        label = ("%s  %s"):format(lhs, k.desc),
        action = function()
          ACTIONS[k.action](lhs)
        end,
      }
    end
  end
  return out
end

ACTIONS.menu = function()
  require("ui.kit").menu({ title = "plugins report", items = M.menu_items() })
end

---The installed plugin whose clone is `dir`, from the configured sources.
---@param dir string
---@return GitSuite.Plugins.Ref|nil
local function ref_of(dir)
  local refs = require("gitsuite.features.plugins.sources").list({ include_local = true })
  local want = vim.fs.normalize(dir)
  for _, ref in ipairs(refs or {}) do
    if vim.fs.normalize(ref.dir) == want then return ref end
  end
end

---Put a freshly read entry in place of the one named `name` (or drop it when
---the clone now shows no change), in this tab's copy of the report.
---@param name string
---@param fresh GitSuite.Plugins.ReportEntry|nil
function M.replace_entry(name, fresh)
  local plugins = S.model.report.plugins
  for i, e in ipairs(plugins) do
    if e.name == name then
      if fresh then
        plugins[i] = fresh
      else
        table.remove(plugins, i)
      end
      break
    end
  end
  S.model.cache[name] = nil
  -- A detail of a plugin that is gone now shows the overview instead.
  if not fresh and S.model.view.kind == "detail" and S.model.view.name == name then
    S.model = model.show(S.model, { kind = "overview" })
  end
  M.redraw({ kind = "plugin", name = name })
end

ACTIONS.retry = function()
  local entry = entry_here()
  if not entry then return end
  local ref = ref_of(entry.dir)
  if not ref then return notify_info(entry.name .. " is not installed (any more)") end
  notify_info("reading " .. entry.name .. " again ...")
  local name, dir = entry.name, entry.dir
  local shown = S.model.report
  -- The whole report is read again, not stored: which commits belong to the
  -- last update is decided over all clones (one run of `:Lazy sync`), and the
  -- snapshot fallback must see the store as it was when this report was made.
  require("gitsuite.features.plugins.report").build({
    mode = shown.mode,
    all = true,
    persist = false,
    before = { id = shown.id, at = shown.at },
  }, function(fresh)
    -- Another report is shown by now: this answer is not about it.
    if not S.model or S.model.report ~= shown then return end
    local want = vim.fs.normalize(dir)
    local new_entry
    for _, e in ipairs(fresh and fresh.plugins or {}) do
      if type(e.dir) == "string" and vim.fs.normalize(e.dir) == want then new_entry = e end
    end
    if new_entry and new_entry.status == "same" then new_entry = nil end
    if new_entry then new_entry.name = name end
    M.replace_entry(name, new_entry)
    notify_info(
      new_entry and (name .. " read again (in this tab; R stores a new report)")
        or (name .. " shows no change now")
    )
  end)
end

ACTIONS.rebuild = function()
  require("gitsuite.features.plugins").report({ mode = S.model.report.mode })
end

ACTIONS.preview = function()
  if valid_win(S.preview_win) then
    S.preview_on = false
    close_win(S.preview_win)
    S.preview_win = nil
  else
    S.preview_on = true
    open_preview()
  end
end

ACTIONS.close = function()
  M.close()
end

ACTIONS.help = function()
  require("ui.kit").viewer({
    lines = keys.help_lines(),
    title = "GitSuite Plugins Report Keys",
    filetype = "gitsuite-help",
  })
end

---Bind the keys of `keys.KEYS` on the list buffer.
---@param buf integer
local function bind(buf)
  for _, k in ipairs(keys.KEYS) do
    for _, lhs in ipairs(k.keys) do
      vim.keymap.set("n", lhs, function()
        if not S.model then return end
        if not keys.applies(k, S.model.view.kind) then
          require("gitsuite.util.notify").info(
            ("plugins report: %s does nothing in the %s"):format(lhs, S.model.view.kind)
          )
          return
        end
        ACTIONS[k.action](lhs)
      end, { buffer = buf, nowait = true, desc = "[gitsuite] plugins report: " .. k.desc })
    end
  end

  -- The AI summary is a key only with a `plugins.summarize` hook, and its lhs
  -- is configurable (`plugins.summarize_key`), so it is not in `keys.KEYS`.
  local ai = require("gitsuite.features.plugins.ai_summary")
  if ai.hook() then
    vim.keymap.set("n", ai.key(), function()
      local it = item_at_cursor()
      if not S.model or not it or not it.name or not model.entry(S.model, it.name) then
        require("gitsuite.util.notify").info("plugins summarize: put the cursor on a plugin")
        return
      end
      ai.request(S.model.report, it.name, {
        ctx = S.model.ctx,
        on_done = function(summary)
          if summary then M.redraw() end
        end,
      })
    end, {
      buffer = buf,
      nowait = true,
      desc = "[gitsuite] plugins report: AI summary of this plugin's update (plugins.summarize)",
    })
  end
end

---Autocmds of the list buffer: preview follows the cursor, the preview goes
---with the list, the layout follows the editor's width.
local function autocmds()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = S.list_buf,
    callback = function()
      S.cursor = item_at_cursor() or S.cursor
      update_preview()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local win = tonumber(ev.match)
      local gen = S.gen
      if win == S.list_win then
        S.list_win = nil
        local p = S.preview_win
        S.preview_win = nil
        -- Scheduled: a window cannot be closed from inside another's WinClosed.
        -- The preview may be the last window left (the report was the only
        -- tab): it cannot close then, and is handed back instead of staying
        -- fixed to the preview buffer.
        vim.schedule(function()
          close_win(p)
          release(p)
        end)
      elseif win == S.preview_win then
        S.preview_win = nil
        -- Only closing the preview by itself turns it off. When the whole tab
        -- goes (`:tabclose`, `q`), the list window goes right after it: the
        -- rebuilt tab gets its preview back -- also when it was rebuilt before
        -- this ran (`gen` changed).
        vim.schedule(function()
          if gen == S.gen and valid_win(S.list_win) and tab_alive() then S.preview_on = false end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not valid_win(S.preview_win) then return end
      close_win(S.preview_win)
      S.preview_win = nil
      open_preview()
    end,
  })
end

---Make the two buffers once.
local function ensure_buffers()
  require("gitsuite.features.plugins.report_ui.highlights").setup()
  if not valid_buf(S.list_buf) then
    S.list_buf = make_buf(M.LIST_NAME, "gitsuite-plugins-report")
    bind(S.list_buf)
  end
  if not valid_buf(S.preview_buf) then
    S.preview_buf = make_buf(M.PREVIEW_NAME, "gitsuite-plugins-preview")
  end
  autocmds()
end

---Show `m` in the report tab: the tab is made (or found again) around the
---kept buffers, and the cursor goes back to what it was on.
---@param m GitSuite.ReportUi.Model
function M.open(m)
  local same_report = S.model and S.model.report.id == m.report.id
  if not same_report then
    S.model = m
    S.cursor = nil
  else
    -- The same report opened again keeps its view and sort; the seen marks and
    -- the clones' HEADs are what `m` read just now (another editor may have
    -- marked, a clone may have moved).
    local seen = vim.tbl_extend("force", {}, m.seen)
    for k, on in pairs(S.unsaved or {}) do
      seen[k] = on or nil
    end
    S.model = vim.tbl_extend(
      "force",
      {},
      S.model,
      { seen = seen, heads = m.heads, ascii = m.ascii }
    )
  end
  ensure_buffers()

  -- `q` goes back to where the report was opened from, the last time.
  local current = vim.api.nvim_get_current_tabpage()
  if current ~= S.tab then S.origin_tab = current end

  if tab_alive() and valid_win(S.list_win) then
    vim.api.nvim_set_current_tabpage(S.tab)
    vim.api.nvim_set_current_win(S.list_win)
  else
    if tab_alive() then
      -- The tab is there but its list window is gone (`:q` in it): reuse it.
      vim.api.nvim_set_current_tabpage(S.tab)
      vim.cmd("silent! only")
      local cur = vim.api.nvim_get_current_win()
      if vim.wo[cur].winfixbuf then vim.wo[cur].winfixbuf = false end
    else
      vim.cmd("tabnew")
      S.tab = vim.api.nvim_get_current_tabpage()
    end
    local scratch = vim.api.nvim_get_current_buf()
    S.list_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(S.list_win, S.list_buf)
    if scratch ~= S.list_buf and vim.api.nvim_buf_get_name(scratch) == "" then
      pcall(vim.api.nvim_buf_delete, scratch, {})
    end
    style_win(S.list_win)
    vim.wo[S.list_win].cursorline = true
    vim.wo[S.list_win].winbar = WINBAR
    vim.t[S.tab].gitsuite_plugins_report = true
    S.preview_win = nil
    S.gen = (S.gen or 0) + 1
    if S.preview_on then open_preview() end
  end
  M.redraw(S.cursor)
end

---Close the report tab (the buffers and the model stay). The last tab cannot
---be closed: then the list window shows an empty buffer instead.
function M.close()
  if not tab_alive() then return end
  local origin = S.origin_tab
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(S.tab))
  else
    close_win(S.preview_win)
    -- The window stops being the report's: not fixed, no legend, no cursorline.
    release(S.list_win)
    vim.t[S.tab].gitsuite_plugins_report = nil
  end
  S.tab, S.list_win, S.preview_win = nil, nil, nil
  if origin and vim.api.nvim_tabpage_is_valid(origin) then
    vim.api.nvim_set_current_tabpage(origin)
  end
end

---For specs: forget everything (buffers are wiped).
function M.reset()
  if tab_alive() and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(S.tab))
  end
  for _, b in ipairs({ S.list_buf, S.preview_buf }) do
    if valid_buf(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  if S.loader then S.loader:stop() end
  S = { preview_on = true }
end

return M
