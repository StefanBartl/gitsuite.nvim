---@module 'gitsuite.features.plugins.text'
--- Making text that came out of somebody else's repository safe to put on
--- screen. A commit message is chosen by whoever wrote the commit: it can
--- carry terminal escape sequences, a carriage return that overwrites the
--- line it sits on, or a megabyte of text. Everything the plugin features show
--- goes through here first.

local M = {}

---Longest line shown, in characters. Longer text is cut and marked with "…".
M.MAX_LINE = 400

---Replace control characters and cap the length. A tab becomes a space; any
---other control byte (ESC, CR, NUL, DEL, ...) becomes `?` so nothing in the
---text can move the cursor, recolour the terminal or hide a character. The C1
---controls (U+0080..U+009F, two bytes in UTF-8) go too: a terminal in UTF-8
---mode reads U+009B as a CSI.
---@param s string
---@return string
function M.clean(s)
  -- An explicit byte class, not `%c`: `iscntrl` follows the C locale, and in some
  -- locales (macOS UTF-8, Latin-1) it also covers 0x80..0x9F, which would break
  -- the continuation bytes of "…", "€" or any CJK character.
  s = s:gsub("\t", " "):gsub("[%z\1-\31\127]", "?"):gsub("\194[\128-\159]", "?")
  if vim.fn.strchars(s) > M.MAX_LINE then s = vim.fn.strcharpart(s, 0, M.MAX_LINE) .. "…" end
  return s
end

---The first line of `s`, cleaned: what goes into a notification, a window title
---or a header. A multi-line git error must not turn a one-line message into a
---hit-enter prompt.
---@param s any
---@return string
function M.one_line(s)
  s = tostring(s == nil and "" or s)
  return M.clean((s:match("^[^\r\n]*")))
end

---Split a multi-line text into cleaned lines.
---@param text string
---@return string[]
function M.lines(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = M.clean(line)
  end
  return out
end

return M
