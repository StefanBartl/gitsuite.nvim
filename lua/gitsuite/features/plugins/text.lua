---@module 'gitsuite.features.plugins.text'
--- Making text that came out of somebody else's repository safe to put on
--- screen. A commit message is chosen by whoever wrote the commit: it can
--- carry terminal escape sequences, a carriage return that overwrites the
--- line it sits on, invisible characters that make it read differently from what
--- it is, bytes that are not UTF-8, or a hundred megabytes of text. Everything
--- the plugin features show goes through here first -- and the work is bounded
--- by what is shown, not by what was sent.

local M = {}

---Longest line shown, in characters. Longer text is cut and marked with "…".
M.MAX_LINE = 400

---Bytes `clean` looks at: four per character is the most UTF-8 spends, so this is
---always more than `MAX_LINE` characters -- and a multi-megabyte line costs the
---same as a short one.
local CLEAN_CAP = 4 * M.MAX_LINE + 16

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

---Make one line of foreign text printable: cut to what is shown, valid UTF-8,
---no control characters, no invisible or re-ordering ones, at most `MAX_LINE`
---characters. A tab becomes a space; any other control byte (ESC, CR, NUL, DEL,
---...) becomes `?` so nothing in the text can move the cursor, recolour the
---terminal or hide a character. The C1 controls (U+0080..U+009F, two bytes in
---UTF-8) go too: a terminal in UTF-8 mode reads U+009B as a CSI. So do the
---characters that change how text is ORDERED or hide it -- zero-width and bidi
---marks (U+200B-200F, U+202A-202E, U+2060-206F), the line/paragraph separators
---U+2028/2029, the Arabic letter mark U+061C, the byte-order mark U+FEFF, the
---interlinear annotation marks U+FFF9-FFFB and the Unicode tag block
---(U+E0000-E0FFF, which can spell a sentence nobody sees). Variation selectors
---(emoji presentation) stay.
---@param s string
---@return string
function M.clean(s)
  if #s > CLEAN_CAP then s = s:sub(1, CLEAN_CAP) end
  s = M.utf8(s)
  -- An explicit byte class, not `%c`: `iscntrl` follows the C locale, and in some
  -- locales (macOS UTF-8, Latin-1) it also covers 0x80..0x9F, which would break
  -- the continuation bytes of "…", "€" or any CJK character.
  s = s:gsub("\t", " "):gsub("[%z\1-\31\127]", "?"):gsub("\194[\128-\159]", "?")
  if s:find("[\194-\244]") then
    s = s
      :gsub("\226\128[\139-\143]", "?") -- U+200B-200F
      :gsub("\226\128[\168-\174]", "?") -- U+2028-202E
      :gsub("\226\129[\160-\175]", "?") -- U+2060-206F
      :gsub("\216\156", "?") -- U+061C
      :gsub("\239\187\191", "?") -- U+FEFF
      :gsub("\239\191[\185-\187]", "?") -- U+FFF9-FFFB
      :gsub("\243[\160-\163][\128-\191][\128-\191]", "?") -- U+E0000-E0FFF
      :gsub("\227\133\164", "?") -- U+3164 Hangul filler
      :gsub("\239\190\160", "?") -- U+FFA0 halfwidth Hangul filler
      :gsub("\225\133[\159\160]", "?") -- U+115F, U+1160
      :gsub("\225\160\142", "?") -- U+180E Mongolian vowel separator
      :gsub("\226\160\128", "?") -- U+2800 braille blank
      :gsub("\194\173", "?") -- U+00AD soft hyphen
      :gsub("\205\143", "?") -- U+034F combining grapheme joiner
      :gsub("\240\157\133[\179-\186]", "?") -- U+1D173-1D17A musical formatting
  end
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

---Lines counted at most this far (a body of millions of lines is not walked to
---the end just to say how many there are).
local COUNT_CAP = 200000

---Split a multi-line text into cleaned lines.
---
---With `max`, only the first `max` lines are cleaned and returned; the rest are
---only counted. The cost then follows what is shown, not the size of the text.
---@param text string
---@param max? integer
---@return string[] lines
---@return integer total  How many lines there are (counted up to 200000).
---@return boolean exact  `false` when the count stopped at the cap.
function M.lines(text, max)
  local out, total = {}, 0
  local pos, n = 1, #text
  while pos <= n + 1 do
    local nl = text:find("\n", pos, true)
    total = total + 1
    if not max or #out < max then
      local stop = (nl or n + 1) - 1
      -- never copy more of a huge line than `clean` looks at
      out[#out + 1] = M.clean(text:sub(pos, math.min(stop, pos + CLEAN_CAP)))
    end
    if not nl then return out, total, true end
    if total >= COUNT_CAP and max and #out >= max then return out, total, false end
    pos = nl + 1
  end
  return out, total, true
end

return M
