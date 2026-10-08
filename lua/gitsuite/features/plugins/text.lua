---@module 'gitsuite.features.plugins.text'
--- Making text that came out of somebody else's repository safe to put on
--- screen: control characters, invisible or re-ordering ones, bytes that are not
--- UTF-8 and runaway length are dealt with in `lib.lua.strings.safe`. This
--- module is the plugin features' name for it (with the shown-line cap fixed),
--- so everything they show goes through here first.

local safe = require("lib.lua.strings.safe")

local M = {}

---Longest line shown, in characters. Longer text is cut and marked with "…".
M.MAX_LINE = safe.MAX_LINE

---@see lib.lua.strings.safe.utf8
M.utf8 = safe.utf8

---@see lib.lua.strings.safe.clean
---@param s string
---@return string
function M.clean(s)
  return safe.clean(s, M.MAX_LINE)
end

---@see lib.lua.strings.safe.one_line
---@param s any
---@return string
function M.one_line(s)
  return safe.one_line(s, M.MAX_LINE)
end

---@see lib.lua.strings.safe.lines
---@param text string
---@param max? integer
---@return string[] lines
---@return integer total  How many lines there are (counted up to 200000).
---@return boolean exact  `false` when the count stopped at the cap.
function M.lines(text, max)
  return safe.lines(text, max, M.MAX_LINE)
end

return M
