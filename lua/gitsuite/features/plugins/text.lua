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
  -- Characters that change how text is ORDERED or hide it (UTF-8 byte forms):
  -- zero-width and bidi marks U+200B-200F, U+202A-202E, U+2066-2069, the line and
  -- paragraph separators U+2028/2029 and the byte-order mark U+FEFF. A subject
  -- could otherwise read differently from what it is.
  s = s:gsub("\226\128[\139-\143]", "?")
    :gsub("\226\128[\168-\174]", "?")
    :gsub("\226\129[\166-\169]", "?")
    :gsub("\239\187\191", "?")
  if vim.fn.strchars(s) > M.MAX_LINE then s = vim.fn.strcharpart(s, 0, M.MAX_LINE) .. "…" end
  return s
end

---`s` with every byte that is not part of valid UTF-8 replaced by `?`. A commit
---message is raw bytes in whatever encoding its author used; JSON, buffers and
---the clipboard want text. ASCII (the common case) is returned as is.
---@param s string
---@return string
function M.utf8(s)
  if not s:find("[\128-\255]") then return s end
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = 0
    if c < 0x80 then
      len = 1
    elseif c >= 0xC2 and c <= 0xDF then
      len = 2
    elseif c >= 0xE0 and c <= 0xEF then
      len = 3
    elseif c >= 0xF0 and c <= 0xF4 then
      len = 4
    end
    local ok = len > 0 and i + len - 1 <= n
    if ok then
      for k = 1, len - 1 do
        local b = s:byte(i + k)
        if b < 0x80 or b > 0xBF then
          ok = false
          break
        end
      end
    end
    if ok and len >= 3 then
      -- overlong forms, surrogates and code points above U+10FFFF
      local b2 = s:byte(i + 1)
      if
        (c == 0xE0 and b2 < 0xA0)
        or (c == 0xED and b2 > 0x9F)
        or (c == 0xF0 and b2 < 0x90)
        or (c == 0xF4 and b2 > 0x8F)
      then
        ok = false
      end
    end
    if ok then
      out[#out + 1] = s:sub(i, i + len - 1)
      i = i + len
    else
      out[#out + 1] = "?"
      i = i + 1
    end
  end
  return table.concat(out)
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
