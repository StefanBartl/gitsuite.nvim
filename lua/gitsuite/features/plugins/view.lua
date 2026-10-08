---@module 'gitsuite.features.plugins.view'
--- Showing a list of commits: a `ui.kit` picker with a preview (default), a
--- scratch buffer, or the clipboard. Pure formatting is split from the windows
--- so the text can be tested without opening one (`rows`, `preview_lines`).
---
--- Everything that came out of the repository -- and everything derived from a
--- path or a name in it -- goes through `text` first.

local text = require("gitsuite.features.plugins.text")
local links = require("gitsuite.features.plugins.links")
local notify = require("gitsuite.util.notify")

local M = {}

---@param entry Lib.Git.LogEntry
---@return boolean
function M.is_head(entry)
  for _, ref in ipairs(entry.refs) do
    if ref == "HEAD" or ref:sub(1, 8) == "HEAD -> " then return true end
  end
  return false
end

---@param entry Lib.Git.LogEntry
---@return string[]
function M.tags(entry)
  local out = {}
  for _, ref in ipairs(entry.refs) do
    if ref:sub(1, 5) == "tag: " then out[#out + 1] = text.clean(ref:sub(6)) end
  end
  return out
end

---@param entry Lib.Git.LogEntry
---@return string
local function date(entry)
  return entry.commit_time and os.date("%Y-%m-%d", entry.commit_time) or "          "
end

---Preview limits: a commit message or a file list is not bounded by anything
---the repository's author does not control.
M.MAX_BODY_LINES = 200
M.MAX_FILES = 500

---The marker for the commit HEAD points at: "installed" only means something
---for a plugin; for an arbitrary clone it is just where HEAD is.
---@param kind? "plugin"|"path"
---@return string
local function head_marker(kind)
  return kind == "plugin" and "<- installed (HEAD)" or "<- HEAD"
end

---The one-line form of a commit, for the buffer and the clipboard.
---@param entry Lib.Git.LogEntry
---@param kind? "plugin"|"path"
---@return string
function M.line(entry, kind)
  local parts = { entry.sha:sub(1, 8), date(entry), text.clean(entry.subject) }
  if M.is_head(entry) then parts[#parts + 1] = head_marker(kind) end
  for _, tag in ipairs(M.tags(entry)) do
    parts[#parts + 1] = "[" .. tag .. "]"
  end
  return table.concat(parts, "  ")
end

---The lines of a buffer/clipboard listing, header included.
---@param target GitSuite.Plugins.Target
---@param entries Lib.Git.LogEntry[]
---@return string[]
function M.rows(target, entries)
  local lines = {
    ("%s -- %d commit%s of %s"):format(
      text.one_line(target.name),
      #entries,
      #entries == 1 and "" or "s",
      text.one_line(target.dir)
    ),
    "",
  }
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = M.line(entry, target.kind)
  end
  return lines
end

---The preview of one commit: who/when, the message, the changed files.
---@param entry Lib.Git.LogEntry
---@return string[]
function M.preview_lines(entry)
  local lines = {
    entry.sha,
    ("%s  %s"):format(
      text.clean(entry.author),
      entry.commit_time and os.date("%Y-%m-%d %H:%M", entry.commit_time) or ""
    ),
  }
  if #entry.refs > 0 then
    local refs = {}
    for _, ref in ipairs(entry.refs) do
      refs[#refs + 1] = text.clean(ref)
    end
    lines[#lines + 1] = "refs: " .. table.concat(refs, ", ")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = text.clean(entry.subject)
  if entry.body ~= "" then
    lines[#lines + 1] = ""
    local body = text.lines(entry.body)
    if #body > M.MAX_BODY_LINES then
      local more = #body - M.MAX_BODY_LINES
      body = vim.list_slice(body, 1, M.MAX_BODY_LINES)
      body[#body + 1] = ("... %d more line%s"):format(more, more == 1 and "" or "s")
    end
    vim.list_extend(lines, body)
  end

  local files = entry.files or {}
  lines[#lines + 1] = ""
  if #files == 0 then
    lines[#lines + 1] = "(no changed files: a merge or an empty commit)"
  else
    lines[#lines + 1] = ("Files (%d)"):format(#files)
    for i, file in ipairs(files) do
      if i > M.MAX_FILES then
        lines[#lines + 1] = ("  ... %d more"):format(#files - M.MAX_FILES)
        break
      end
      local path = text.clean(file.path)
      if file.orig_path then path = text.clean(file.orig_path) .. " -> " .. path end
      lines[#lines + 1] = ("  %s  %s"):format(text.clean(file.status:sub(1, 1)), path)
    end
  end
  return lines
end

---Open a commit's page in the browser; without a usable forge, copy the hash.
---@param target GitSuite.Plugins.Target
---@param entry Lib.Git.LogEntry
function M.open_commit(target, entry)
  local url, err = links.commit_url(target.dir, entry.sha)
  if not url then
    vim.fn.setreg("+", entry.sha)
    vim.fn.setreg('"', entry.sha)
    notify.warn(
      ("plugins log: %s -- copied %s instead"):format(text.one_line(err), entry.sha:sub(1, 8))
    )
    return
  end
  local ok, open_err = links.open(url)
  if not ok then
    notify.error("plugins log: " .. text.one_line(open_err or ("could not open " .. url)))
  end
end

---@param lines string[]
---@param name string
---@param filetype? string  Default "gitsuite-plugins-log".
---@param kind? string      Default "plugins-log": the middle part of the buffer name.
local function open_buffer(lines, name, filetype, kind)
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype or "gitsuite-plugins-log"
  pcall(vim.api.nvim_buf_set_name, buf, ("gitsuite://%s/%s"):format(kind or "plugins-log", name))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, desc = "Close" })
end

---Where `:Git plugins report` writes with `--out=path` when `--to` is not given.
---@return string
function M.default_report_path()
  return vim.fn.stdpath("cache") .. "/gitsuite/plugins-report.md"
end

---Show report lines the way `out` asks for: a Markdown scratch buffer, the
---clipboard, or a file (written atomically; `to` or the cache folder).
---@param lines string[]
---@param name string       Buffer name / label.
---@param out? "buffer"|"clipboard"|"path"
---@param to? string
---@return string|nil written  The path written, for `out = "path"`.
---@return string|nil err
function M.show_markdown(lines, name, out, to)
  out = out or "buffer"
  local body = table.concat(lines, "\n") .. "\n"
  if out == "buffer" then
    open_buffer(lines, name, "markdown", "plugins-report")
    return nil, nil
  elseif out == "clipboard" then
    vim.fn.setreg("+", body)
    vim.fn.setreg('"', body)
    notify.info(("copied the report (%d lines)"):format(#lines))
    return nil, nil
  elseif out == "path" then
    local path = to and vim.fs.normalize(vim.fn.expand(to)) or M.default_report_path()
    local ok, err = require("lib.nvim.fs.write.atomic")(path, body, { mkdirp = true })
    if not ok then
      notify.error("plugins report: " .. text.one_line(err))
      return nil, err
    end
    notify.info("wrote the report to " .. path)
    return path, nil
  end
  notify.error(
    ("plugins report: unknown output '%s' (buffer, clipboard or path)"):format(text.one_line(out))
  )
  return nil, "unknown output"
end

---@param target GitSuite.Plugins.Target
---@param entries Lib.Git.LogEntry[]
---@return table|nil handle The `ui.kit` picker handle.
local function open_picker(target, entries)
  local ok, kit = pcall(require, "ui.kit")
  if not ok then
    notify.error('plugins log: ui.nvim is not installed -- try "--out=buffer"')
    return nil
  end

  ---@return Lib.Git.LogEntry|nil
  local function current(handle)
    return handle.current()
  end

  return kit.picker({
    title = ("%s (%d)"):format(text.one_line(target.name), #entries),
    items = entries,
    key = function(entry)
      return entry.sha
    end,
    text = function(entry)
      return table.concat(
        { entry.sha, entry.author, entry.subject, table.concat(entry.refs, " ") },
        " "
      )
    end,
    format = function(entry)
      local chunks = {
        { entry.sha:sub(1, 8), "Number" },
        { "  " .. date(entry), "Comment" },
        { "  " .. text.clean(entry.subject), "Normal" },
      }
      if M.is_head(entry) then
        local label = target.kind == "plugin" and "  <- installed" or "  <- HEAD"
        chunks[#chunks + 1] = { label, "DiagnosticOk" }
      end
      for _, tag in ipairs(M.tags(entry)) do
        chunks[#chunks + 1] = { "  [" .. tag .. "]", "Special" }
      end
      return chunks
    end,
    preview = function(entry, surface)
      surface:set_lines(M.preview_lines(entry))
    end,
    results_width = 0.6,
    keys = {
      -- Browser and hash without closing the list: Alt chords, because the keys
      -- run inside the prompt, where a plain letter would be typed. (No lazygit
      -- key: lazygit can change the clone, this feature never does --
      -- `:Git ui lazygit <dir>` is the explicit way.)
      ["<M-o>"] = function(handle)
        local entry = current(handle)
        if entry then M.open_commit(target, entry) end
      end,
      ["<M-y>"] = function(handle)
        local entry = current(handle)
        if entry then
          vim.fn.setreg("+", entry.sha)
          vim.fn.setreg('"', entry.sha)
          notify.info("copied " .. entry.sha:sub(1, 8))
        end
      end,
    },
    on_submit = function(_, _, entry)
      if entry then M.open_commit(target, entry) end
    end,
  })
end

---Show `entries` the way `out` asks for.
---@param target GitSuite.Plugins.Target
---@param entries Lib.Git.LogEntry[]
---@param out? "picker"|"buffer"|"clipboard"
---@return table|nil handle The picker handle, for `out = "picker"`.
function M.show(target, entries, out)
  out = out or "picker"
  if out ~= "picker" and out ~= "buffer" and out ~= "clipboard" then
    notify.error(
      ("plugins log: unknown output '%s' (picker, buffer or clipboard)"):format(text.one_line(out))
    )
    return nil
  end
  if out == "buffer" then
    open_buffer(M.rows(target, entries), text.one_line(target.name))
  elseif out == "clipboard" then
    local lines = M.rows(target, entries)
    vim.fn.setreg("+", table.concat(lines, "\n") .. "\n")
    vim.fn.setreg('"', table.concat(lines, "\n") .. "\n")
    notify.info(
      ("copied %d commit%s of %s"):format(
        #entries,
        #entries == 1 and "" or "s",
        text.one_line(target.name)
      )
    )
  else
    return open_picker(target, entries)
  end
  return nil
end

return M
