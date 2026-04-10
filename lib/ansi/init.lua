if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- ANSI escape code library.
-- Colors (4-bit, 8-bit, 24-bit RGB), text styles, cursor movement,
-- terminal control, and strip/len utilities.
--
-- Honors NO_COLOR and TERM=dumb: when disabled, style/color functions
-- return the string unchanged (no escapes). strip() always works.

local M = {}

-- Detect whether color output should be enabled at load time.
local no_color = os.getenv("NO_COLOR")
local term     = os.getenv("TERM")
M.enabled = not (no_color ~= nil and no_color ~= "") and term ~= "dumb"

-- ESC [ prefix used by all sequences.
local ESC = "\27["

-- Reset escape sequence (constant).
M.reset = ESC .. "0m"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Wrap s in an opening sequence and reset, or return seq alone when s is nil.
--: (string, string | nil) -> string
local function wrap(seq, s)
  if s == nil then return seq end
  return seq .. s .. M.reset
end

-- Build a style function that applies a single SGR code.
-- When M.enabled is false and s is provided, returns s unchanged.
-- When M.enabled is false and s is nil, returns "".
--: (integer) -> (string | nil) -> string
local function sgr(code)
  local seq = ESC .. code .. "m"
  return function(s)
    if not M.enabled then return s or "" end
    return wrap(seq, s)
  end
end

-- ---------------------------------------------------------------------------
-- Text styles
-- ---------------------------------------------------------------------------

M.bold          = sgr(1)
M.dim           = sgr(2)
M.italic        = sgr(3)
M.underline     = sgr(4)
M.blink         = sgr(5)
M.reverse       = sgr(7)
M.strikethrough = sgr(9)

-- ---------------------------------------------------------------------------
-- 4-bit foreground colors (30-37 normal, 90-97 bright)
-- ---------------------------------------------------------------------------

M.black   = sgr(30)
M.red     = sgr(31)
M.green   = sgr(32)
M.yellow  = sgr(33)
M.blue    = sgr(34)
M.magenta = sgr(35)
M.cyan    = sgr(36)
M.white   = sgr(37)

M.bright_black   = sgr(90)
M.bright_red     = sgr(91)
M.bright_green   = sgr(92)
M.bright_yellow  = sgr(93)
M.bright_blue    = sgr(94)
M.bright_magenta = sgr(95)
M.bright_cyan    = sgr(96)
M.bright_white   = sgr(97)

-- ---------------------------------------------------------------------------
-- 4-bit background colors (40-47 normal, 100-107 bright)
-- ---------------------------------------------------------------------------

M.bg_black   = sgr(40)
M.bg_red     = sgr(41)
M.bg_green   = sgr(42)
M.bg_yellow  = sgr(43)
M.bg_blue    = sgr(44)
M.bg_magenta = sgr(45)
M.bg_cyan    = sgr(46)
M.bg_white   = sgr(47)

M.bg_bright_black   = sgr(100)
M.bg_bright_red     = sgr(101)
M.bg_bright_green   = sgr(102)
M.bg_bright_yellow  = sgr(103)
M.bg_bright_blue    = sgr(104)
M.bg_bright_magenta = sgr(105)
M.bg_bright_cyan    = sgr(106)
M.bg_bright_white   = sgr(107)

-- ---------------------------------------------------------------------------
-- 8-bit colors (0-255)
-- ---------------------------------------------------------------------------

-- Foreground 256-color.
--: (integer, string | nil) -> string
M.fg256 = function(n, s)
  if not M.enabled then return s or "" end
  return wrap(ESC .. "38;5;" .. n .. "m", s)
end

-- Background 256-color.
--: (integer, string | nil) -> string
M.bg256 = function(n, s)
  if not M.enabled then return s or "" end
  return wrap(ESC .. "48;5;" .. n .. "m", s)
end

-- ---------------------------------------------------------------------------
-- 24-bit true color
-- ---------------------------------------------------------------------------

-- Foreground RGB (0-255 each).
--: (integer, integer, integer, string | nil) -> string
M.fg = function(r, g, b, s)
  if not M.enabled then return s or "" end
  return wrap(ESC .. "38;2;" .. r .. ";" .. g .. ";" .. b .. "m", s)
end

-- Background RGB (0-255 each).
--: (integer, integer, integer, string | nil) -> string
M.bg = function(r, g, b, s)
  if not M.enabled then return s or "" end
  return wrap(ESC .. "48;2;" .. r .. ";" .. g .. ";" .. b .. "m", s)
end

-- ---------------------------------------------------------------------------
-- Cursor movement (always returns escape string, no wrap variant)
-- ---------------------------------------------------------------------------

-- Move cursor up n lines.
--: (integer) -> string
M.up = function(n) return ESC .. n .. "A" end

-- Move cursor down n lines.
--: (integer) -> string
M.down = function(n) return ESC .. n .. "B" end

-- Move cursor right n columns.
--: (integer) -> string
M.right = function(n) return ESC .. n .. "C" end

-- Move cursor left n columns.
--: (integer) -> string
M.left = function(n) return ESC .. n .. "D" end

-- Move cursor to row, col (1-indexed).
--: (integer, integer) -> string
M.move_to = function(row, col) return ESC .. row .. ";" .. col .. "H" end
-- goto is a reserved keyword in Lua 5.2+; expose as string key for callers
-- that index via M["goto"].
M["goto"] = M.move_to

-- Move cursor to top-left corner.
--: () -> string
M.home = function() return ESC .. "H" end

-- Save cursor position.
--: () -> string
M.save_pos = function() return ESC .. "s" end

-- Restore cursor position.
--: () -> string
M.restore_pos = function() return ESC .. "u" end

-- ---------------------------------------------------------------------------
-- Terminal control
-- ---------------------------------------------------------------------------

-- Clear the screen.
--: () -> string
M.clear = function() return ESC .. "2J" end

-- Clear the current line.
--: () -> string
M.clear_line = function() return ESC .. "2K" end

-- Clear from cursor to end of line.
--: () -> string
M.clear_to_eol = function() return ESC .. "0K" end

-- Hide the cursor.
--: () -> string
M.hide_cursor = function() return ESC .. "?25l" end

-- Show the cursor.
--: () -> string
M.show_cursor = function() return ESC .. "?25h" end

-- Enter the alternate screen buffer.
--: () -> string
M.enter_alt_screen = function() return ESC .. "?1049h" end

-- Exit the alternate screen buffer.
--: () -> string
M.exit_alt_screen = function() return ESC .. "?1049l" end

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

-- Pattern matching ANSI escape sequences (CSI sequences and OSC sequences).
-- Covers: ESC [ ... final-byte  (CSI)
--         ESC ] ... ST/BEL      (OSC)
--         ESC followed by single char (other two-char sequences)
local ESC_PAT = "\27%[[%d;]*[%a]"   -- CSI: ESC [ ... letter
local ESC_OSC = "\27%][^\7\27]*[\7\27]"  -- OSC (simplified)
local ESC_TWO = "\27[^%[]"          -- ESC + non-bracket single char

-- Remove all ANSI escape sequences from string s.
--: (string) -> string
M.strip = function(s)
  s = s:gsub(ESC_PAT, "")
  s = s:gsub(ESC_OSC, "")
  s = s:gsub(ESC_TWO, "")
  return s
end

-- Return the printable length of string s (excluding escape sequences).
--: (string) -> integer
M.len = function(s)
  return #M.strip(s)
end

return M
