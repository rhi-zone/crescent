if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- VT100/xterm escape sequence parser with screen buffer model.
-- Pure Lua — no FFI. Parses PTY output into a grid of attributed cells.
-- Designed for server-side terminal state in a terminal multiplexer:
-- feed PTY bytes via term:feed(), query cells, snapshot for reconnect.

local M = {}

local floor = math.floor
local max = math.max
local min = math.min
local byte = string.byte
local char = string.char
local sub = string.sub
local concat = table.concat

---------------------------------------------------------------------------
-- Shared struct types (color, cell, pen, grid, terminal)
---------------------------------------------------------------------------

--:: Color16 = { space: "16", n: integer }
--:: Color256 = { space: "256", n: integer }
--:: ColorRgb = { space: "rgb", r: integer, g: integer, b: integer }
--:: Color = Color16 | Color256 | ColorRgb
--:: Cell = { char: string, fg: Color | nil, bg: Color | nil, bold: boolean, dim: boolean, underline: boolean, reverse: boolean, wide: boolean, _cont: boolean }
--:: Attrs = { bold: boolean, dim: boolean, underline: boolean, reverse: boolean, fg: Color | nil, bg: Color | nil }
--:: Pen = { fg: Color | nil, bg: Color | nil, bold: boolean, dim: boolean, underline: boolean, reverse: boolean }
--:: Line = { [integer]: Cell }
--:: Grid = { [integer]: Line }
--:: SavedCursor = { row: integer, col: integer, pen: Pen, visible: boolean }
--:: SavedCursorDec = { row: integer, col: integer, pen: Pen }
--:: SavedCursorAnsi = { row: integer, col: integer }
--:: Term = { _grid: Grid, _alt_grid: Grid, _main_grid: Grid | nil, _cols: integer, _rows: integer, _cursor_row: integer, _cursor_col: integer, _cursor_visible: boolean, _wrap_pending: boolean, _pen: Pen, _scroll_top: integer, _scroll_bottom: integer, _tab_stops: { [integer]: integer }, _saved_cursor: SavedCursor | nil, _saved_cursor_dec: SavedCursorDec | nil, _saved_cursor_ansi: SavedCursorAnsi | nil, _state: integer, _csi_params: string, _csi_private: boolean, _osc_buf: string, _partial: string | nil, _alt_active: boolean, feed: (self: Term, string) -> nil, _reset: (self: Term) -> nil, cell: (self: Term, integer, integer) -> (Cell | nil, string | nil), cursor: (self: Term) -> (integer, integer), cursor_visible: (self: Term) -> boolean, size: (self: Term) -> (integer, integer), resize: (self: Term, integer, integer) -> nil, snapshot: (self: Term) -> string }

---------------------------------------------------------------------------
-- UTF-8 helpers
---------------------------------------------------------------------------

-- Decode a single UTF-8 codepoint starting at position i in string s.
-- Returns (codepoint, next_position) or (nil, next_position) on invalid/incomplete.
--: (string, integer) -> (integer | nil, integer)
local function utf8_decode(s, i)
  --: integer | nil
  local b = byte(s, i)
  if not b then return nil, i end
  if b < 0x80 then return b, i + 1 end
  if b < 0xC0 then return nil, i + 1 end
  local len, cp = 0, 0 --: integer
  if b < 0xE0 then len = 2; cp = b - 0xC0
  elseif b < 0xF0 then len = 3; cp = b - 0xE0
  else len = 4; cp = b - 0xF0 end
  if i + len - 1 > #s then return nil, i end
  for j = 1, len - 1 do
    --: integer | nil
    local c = byte(s, i + j)
    if not c then return nil, i + 1 end
    if c < 0x80 or c >= 0xC0 then return nil, i + 1 end
    cp = cp * 64 + (c - 0x80)
  end
  return cp, i + len
end

---------------------------------------------------------------------------
-- Character width (wcwidth)
---------------------------------------------------------------------------

-- Binary search: is cp inside any [lo,hi] in a sorted ranges table?
--: ({ [integer]: { integer, integer } }, integer) -> boolean
local function in_ranges(ranges, cp)
  local lo, hi = 1, #ranges
  while lo <= hi do
    local mid = floor((lo + hi) / 2)
    local r = ranges[mid]
    if cp < r[1] then hi = mid - 1
    elseif cp > r[2] then lo = mid + 1
    else return true end
  end
  return false
end

-- Zero-width codepoint ranges (combining marks, format characters).
local zero_ranges = {
  {0x0300, 0x036F},   -- Combining Diacritical Marks
  {0x0483, 0x0489},   -- Combining Cyrillic
  {0x0591, 0x05C7},   -- Hebrew combining (simplified)
  {0x0610, 0x061A},   -- Arabic combining
  {0x064B, 0x065F},   -- Arabic combining
  {0x0670, 0x0670},   -- Arabic superscript alef
  {0x06D6, 0x06ED},   -- Arabic combining (simplified)
  {0x0730, 0x074A},   -- Syriac combining
  {0x07A6, 0x07B0},   -- Thaana combining
  {0x0E31, 0x0E31},   -- Thai combining
  {0x0E34, 0x0E3A},   -- Thai combining
  {0x0E47, 0x0E4E},   -- Thai combining
  {0x0EB1, 0x0EB1},   -- Lao combining
  {0x0EB4, 0x0EBC},   -- Lao combining
  {0x0EC8, 0x0ECD},   -- Lao combining
  {0x180B, 0x180E},   -- Mongolian free variation selectors + vowel separator
  {0x200B, 0x200F},   -- Zero-width space, ZWNJ, ZWJ, direction marks
  {0x202A, 0x202E},   -- Direction formatting
  {0x2060, 0x206F},   -- Word joiner, invisible operators, direction isolates
  {0xFE00, 0xFE0F},   -- Variation Selectors
  {0xFEFF, 0xFEFF},   -- BOM / ZWNBSP
  {0xFFF9, 0xFFFB},   -- Interlinear annotation anchors
  {0xE0100, 0xE01EF}, -- Variation Selectors Supplement
}

-- Double-width codepoint ranges (East Asian Wide / Fullwidth).
local wide_ranges = {
  {0x1100, 0x115F},   -- Hangul Jamo initial consonants
  {0x2329, 0x232A},   -- Angle brackets
  {0x2E80, 0x303E},   -- CJK Radicals, Kangxi, Ideographic Description, CJK Symbols
  {0x3040, 0x33FF},   -- Hiragana, Katakana, Bopomofo, Hangul Compat Jamo, CJK Enclosed
  {0x3400, 0x4DBF},   -- CJK Unified Ideographs Extension A
  {0x4E00, 0x9FFF},   -- CJK Unified Ideographs
  {0xA000, 0xA4CF},   -- Yi Syllables + Radicals
  {0xA960, 0xA97F},   -- Hangul Jamo Extended-A
  {0xAC00, 0xD7AF},   -- Hangul Syllables
  {0xF900, 0xFAFF},   -- CJK Compatibility Ideographs
  {0xFE10, 0xFE19},   -- Vertical Forms
  {0xFE30, 0xFE6F},   -- CJK Compatibility Forms + Small Form Variants
  {0xFF01, 0xFF60},   -- Fullwidth Latin + Halfwidth CJK punctuation
  {0xFFE0, 0xFFE6},   -- Fullwidth Signs
  {0x1F300, 0x1F64F}, -- Misc Symbols/Pictographs + Emoticons
  {0x1F680, 0x1F6FF}, -- Transport and Map Symbols
  {0x1F900, 0x1F9FF}, -- Supplemental Symbols and Pictographs
  {0x1FA00, 0x1FA6F}, -- Chess Symbols
  {0x1FA70, 0x1FAFF}, -- Symbols and Pictographs Extended-A
  {0x20000, 0x2FA1F}, -- CJK Extension B through Compat Ideographs Supplement
}

-- Return the display width of a Unicode codepoint.
-- -1 for control characters, 0 for combining/zero-width, 2 for wide, 1 otherwise.
--: (integer) -> integer
local function wcwidth(cp)
  if cp < 0x20 or cp == 0x7F then return -1 end
  if cp >= 0x80 and cp < 0xA0 then return -1 end
  if in_ranges(zero_ranges, cp) then return 0 end
  if in_ranges(wide_ranges, cp) then return 2 end
  return 1
end

-- Exposed for testing / external use.
M.wcwidth = wcwidth

---------------------------------------------------------------------------
-- Cell primitives
---------------------------------------------------------------------------

-- A cell holds one character (or "" for blank) plus display attributes.
-- Color fields are nil (default) or tagged structs:
--   {space="16", n=N}       — 4-bit color (n: 0-15)
--   {space="256", n=N}      — 8-bit color (n: 0-255)
--   {space="rgb", r=R, g=G, b=B}  — 24-bit color
-- wide=true on the first cell of a double-width character.
-- _cont=true on the continuation (second) cell of a double-width character.

--: () -> Cell
local function new_cell()
  return {
    char = "", fg = nil, bg = nil,
    bold = false, dim = false, underline = false, reverse = false,
    wide = false, _cont = false,
  }
end

--: (Cell) -> nil
local function clear_cell(cell)
  cell.char = ""; cell.fg = nil; cell.bg = nil
  cell.bold = false; cell.dim = false; cell.underline = false; cell.reverse = false
  cell.wide = false; cell._cont = false
end

-- Erase a cell: clear content, apply current pen's bg (per xterm spec,
-- ED/EL fill erased cells with the current background color).
--: (Cell, Pen) -> nil
local function erase_cell(cell, pen)
  clear_cell(cell)
  cell.bg = pen.bg
end

--: (integer) -> Line
local function new_line(cols)
  local line = {} --: Line
  for i = 1, cols do line[i] = new_cell() end
  return line
end

--: (integer, integer) -> Grid
local function new_grid(rows, cols)
  local grid = {} --: Grid
  for r = 1, rows do grid[r] = new_line(cols) end
  return grid
end

---------------------------------------------------------------------------
-- Pen (current text attributes applied to newly written cells)
---------------------------------------------------------------------------

--: () -> Pen
local function new_pen()
  return {
    fg = nil, bg = nil,
    bold = false, dim = false, underline = false, reverse = false,
  }
end

--: (Pen) -> Pen
local function copy_pen(p)
  return {
    fg = p.fg, bg = p.bg,
    bold = p.bold, dim = p.dim,
    underline = p.underline, reverse = p.reverse,
  }
end

---------------------------------------------------------------------------
-- Default tab stops: every 8 columns (columns 9, 17, 25, ...)
---------------------------------------------------------------------------

--: (integer) -> { [integer]: integer }
local function default_tab_stops(cols)
  local stops = {} --: { [integer]: integer }
  for c = 9, cols, 8 do stops[#stops + 1] = c end
  return stops
end

---------------------------------------------------------------------------
-- Terminal object
---------------------------------------------------------------------------

local Term = {}
Term.__index = Term

---------------------------------------------------------------------------
-- Grid helpers
---------------------------------------------------------------------------

-- When overwriting a cell that is part of a wide character, clear the other
-- half so the grid stays consistent.
--: (Grid, integer, integer, integer) -> nil
local function clear_wide_at(grid, row, col, cols)
  local cell = grid[row][col]
  if cell._cont then
    if col > 1 then
      local first = grid[row][col - 1]
      first.char = ""; first.wide = false
    end
    cell._cont = false
  elseif cell.wide then
    if col < cols then
      local cont = grid[row][col + 1]
      cont.char = ""; cont._cont = false
    end
    cell.wide = false
  end
end

-- Scroll the region [top, bottom] up by one line. New blank line at bottom.
--: (Term, integer, integer) -> nil
local function scroll_up(self, top, bottom)
  local grid = self._grid
  local old = grid[top]
  for r = top, bottom - 1 do grid[r] = grid[r + 1] end
  for c = 1, self._cols do clear_cell(old[c]) end
  grid[bottom] = old
end

-- Scroll the region [top, bottom] down by one line. New blank line at top.
--: (Term, integer, integer) -> nil
local function scroll_down(self, top, bottom)
  local grid = self._grid
  local old = grid[bottom]
  for r = bottom, top + 1, -1 do grid[r] = grid[r - 1] end
  for c = 1, self._cols do clear_cell(old[c]) end
  grid[top] = old
end

---------------------------------------------------------------------------
-- Cursor / text operations
---------------------------------------------------------------------------

--: (Term) -> nil
local function line_feed(self)
  if self._cursor_row == self._scroll_bottom then
    scroll_up(self, self._scroll_top, self._scroll_bottom)
  elseif self._cursor_row < self._rows then
    self._cursor_row = self._cursor_row + 1
  end
  self._wrap_pending = false
end

--: (Term) -> nil
local function reverse_index(self)
  if self._cursor_row == self._scroll_top then
    scroll_down(self, self._scroll_top, self._scroll_bottom)
  elseif self._cursor_row > 1 then
    self._cursor_row = self._cursor_row - 1
  end
  self._wrap_pending = false
end

--: (Term) -> nil
local function do_tab(self)
  local col = self._cursor_col
  local stops = self._tab_stops
  for i = 1, #stops do
    if stops[i] > col then
      self._cursor_col = min(stops[i], self._cols)
      self._wrap_pending = false
      return
    end
  end
  self._cursor_col = self._cols
  self._wrap_pending = false
end

--: (Term, string, integer) -> nil
local function put_char(self, ch, width)
  if self._wrap_pending then
    self._cursor_col = 1
    line_feed(self)
  end

  local row = self._cursor_row
  local col = self._cursor_col
  local grid = self._grid

  -- Wide char at last column cannot fit — blank the last column and wrap.
  if width == 2 and col == self._cols then
    clear_wide_at(grid, row, col, self._cols)
    clear_cell(grid[row][col])
    self._cursor_col = 1
    line_feed(self)
    row = self._cursor_row
    col = 1
  end

  if col > self._cols then return end

  -- Clear any wide-character overlap at the cells we are about to write.
  clear_wide_at(grid, row, col, self._cols)
  if width == 2 and col + 1 <= self._cols then
    clear_wide_at(grid, row, col + 1, self._cols)
  end

  -- Write the cell.
  local cell = grid[row][col]
  cell.char = ch
  cell.fg = self._pen.fg
  cell.bg = self._pen.bg
  cell.bold = self._pen.bold
  cell.dim = self._pen.dim
  cell.underline = self._pen.underline
  cell.reverse = self._pen.reverse
  cell.wide = (width == 2)
  cell._cont = false

  -- Continuation cell for wide characters.
  if width == 2 and col + 1 <= self._cols then
    local cont = grid[row][col + 1]
    cont.char = ""
    cont.fg = cell.fg; cont.bg = cell.bg
    cont.bold = cell.bold; cont.dim = cell.dim
    cont.underline = cell.underline; cont.reverse = cell.reverse
    cont.wide = false; cont._cont = true
  end

  -- Advance cursor.
  local new_col = col + width
  if new_col > self._cols then
    self._cursor_col = self._cols
    self._wrap_pending = true
  else
    self._cursor_col = new_col
    self._wrap_pending = false
  end
end

---------------------------------------------------------------------------
-- SGR (Select Graphic Rendition) dispatch
---------------------------------------------------------------------------

--: (Term, { [integer]: integer }) -> nil
local function sgr_dispatch(self, params)
  if #params == 0 then params = {0} --[[: { [integer]: integer }]] end
  local i = 1
  while i <= #params do
    local p = params[i]
    if p == 0 then
      self._pen = new_pen()
    elseif p == 1 then self._pen.bold = true
    elseif p == 2 then self._pen.dim = true
    elseif p == 4 then self._pen.underline = true
    elseif p == 7 then self._pen.reverse = true
    elseif p == 22 then self._pen.bold = false; self._pen.dim = false
    elseif p == 24 then self._pen.underline = false
    elseif p == 27 then self._pen.reverse = false
    elseif p >= 30 and p <= 37 then
      self._pen.fg = { space = "16", n = p - 30 }
    elseif p == 38 then
      local sub_p = params[i + 1]
      if sub_p == 5 then
        self._pen.fg = { space = "256", n = params[i + 2] or 0 }
        i = i + 2
      elseif sub_p == 2 then
        self._pen.fg = {
          space = "rgb",
          r = params[i + 2] or 0, g = params[i + 3] or 0, b = params[i + 4] or 0,
        }
        i = i + 4
      end
    elseif p == 39 then self._pen.fg = nil
    elseif p >= 40 and p <= 47 then
      self._pen.bg = { space = "16", n = p - 40 }
    elseif p == 48 then
      local sub_p = params[i + 1]
      if sub_p == 5 then
        self._pen.bg = { space = "256", n = params[i + 2] or 0 }
        i = i + 2
      elseif sub_p == 2 then
        self._pen.bg = {
          space = "rgb",
          r = params[i + 2] or 0, g = params[i + 3] or 0, b = params[i + 4] or 0,
        }
        i = i + 4
      end
    elseif p == 49 then self._pen.bg = nil
    elseif p >= 90 and p <= 97 then
      self._pen.fg = { space = "16", n = p - 90 + 8 }
    elseif p >= 100 and p <= 107 then
      self._pen.bg = { space = "16", n = p - 100 + 8 }
    end
    i = i + 1
  end
end

---------------------------------------------------------------------------
-- CSI parameter parsing
---------------------------------------------------------------------------

-- Parse semicolon-separated CSI parameters into integer list.
-- Missing / empty parameters become 0.
--: (string) -> { [integer]: integer }
local function parse_params(s)
  local params = {}
  if s == "" then return params end
  for tok in (s .. ";"):gmatch("([^;]*);") do
    params[#params + 1] = tonumber(tok) or 0
  end
  return params
end

-- Get param at index with a default for 0 / missing.
--: ({ [integer]: integer }, integer, integer) -> integer
local function param(params, idx, default)
  local v = params[idx]
  if not v or v == 0 then return default end
  return v
end

---------------------------------------------------------------------------
-- CSI sequence dispatch
---------------------------------------------------------------------------

--: (Term, string, string, boolean) -> nil
local function csi_dispatch(self, params_str, final, private)
  local params = parse_params(params_str)

  -- Private mode (ESC [ ? ... h/l)
  if private then
    if final == "h" then
      for j = 1, #params do
        local p = params[j]
        if p == 25 then
          self._cursor_visible = true
        elseif p == 47 or p == 1047 then
          if not self._alt_active then
            self._main_grid = self._grid
            self._grid = self._alt_grid
            self._alt_active = true
          end
        elseif p == 1049 then
          if not self._alt_active then
            self._saved_cursor = {
              row = self._cursor_row, col = self._cursor_col,
              pen = copy_pen(self._pen), visible = self._cursor_visible,
            }
            self._main_grid = self._grid
            self._grid = self._alt_grid
            self._alt_active = true
            for r = 1, self._rows do
              for c = 1, self._cols do clear_cell(self._grid[r][c]) end
            end
            self._cursor_row = 1; self._cursor_col = 1
            self._wrap_pending = false
          end
        end
      end
    elseif final == "l" then
      for j = 1, #params do
        local p = params[j]
        if p == 25 then
          self._cursor_visible = false
        elseif p == 47 or p == 1047 then
          if self._alt_active then
            self._alt_grid = self._grid
            local main_grid = self._main_grid
            if main_grid then self._grid = main_grid end
            self._alt_active = false
          end
        elseif p == 1049 then
          if self._alt_active then
            self._alt_grid = self._grid
            local main_grid = self._main_grid
            if main_grid then self._grid = main_grid end
            self._alt_active = false
            local saved_cursor = self._saved_cursor
            if saved_cursor then
              self._cursor_row = saved_cursor.row
              self._cursor_col = saved_cursor.col
              self._pen = saved_cursor.pen
              self._cursor_visible = saved_cursor.visible
              self._saved_cursor = nil
            end
            self._wrap_pending = false
          end
        end
      end
    end
    return
  end

  -- Standard CSI sequences.
  if final == "A" then -- CUU: cursor up
    self._cursor_row = max(1, self._cursor_row - param(params, 1, 1))
    self._wrap_pending = false
  elseif final == "B" then -- CUD: cursor down
    self._cursor_row = min(self._rows, self._cursor_row + param(params, 1, 1))
    self._wrap_pending = false
  elseif final == "C" then -- CUF: cursor forward
    self._cursor_col = min(self._cols, self._cursor_col + param(params, 1, 1))
    self._wrap_pending = false
  elseif final == "D" then -- CUB: cursor backward
    self._cursor_col = max(1, self._cursor_col - param(params, 1, 1))
    self._wrap_pending = false
  elseif final == "E" then -- CNL: cursor next line
    self._cursor_row = min(self._rows, self._cursor_row + param(params, 1, 1))
    self._cursor_col = 1; self._wrap_pending = false
  elseif final == "F" then -- CPL: cursor previous line
    self._cursor_row = max(1, self._cursor_row - param(params, 1, 1))
    self._cursor_col = 1; self._wrap_pending = false
  elseif final == "G" then -- CHA: cursor character absolute
    self._cursor_col = max(1, min(self._cols, param(params, 1, 1)))
    self._wrap_pending = false
  elseif final == "H" or final == "f" then -- CUP / HVP
    self._cursor_row = max(1, min(self._rows, param(params, 1, 1)))
    self._cursor_col = max(1, min(self._cols, param(params, 2, 1)))
    self._wrap_pending = false
  elseif final == "J" then -- ED: erase display
    local mode = param(params, 1, 0)
    if mode == 0 then
      for c = self._cursor_col, self._cols do
        erase_cell(self._grid[self._cursor_row][c], self._pen)
      end
      for r = self._cursor_row + 1, self._rows do
        for c = 1, self._cols do erase_cell(self._grid[r][c], self._pen) end
      end
    elseif mode == 1 then
      for r = 1, self._cursor_row - 1 do
        for c = 1, self._cols do erase_cell(self._grid[r][c], self._pen) end
      end
      for c = 1, self._cursor_col do
        erase_cell(self._grid[self._cursor_row][c], self._pen)
      end
    elseif mode == 2 or mode == 3 then
      for r = 1, self._rows do
        for c = 1, self._cols do erase_cell(self._grid[r][c], self._pen) end
      end
    end
  elseif final == "K" then -- EL: erase line
    local mode = param(params, 1, 0)
    local row = self._cursor_row
    if mode == 0 then
      for c = self._cursor_col, self._cols do
        erase_cell(self._grid[row][c], self._pen)
      end
    elseif mode == 1 then
      for c = 1, self._cursor_col do
        erase_cell(self._grid[row][c], self._pen)
      end
    elseif mode == 2 then
      for c = 1, self._cols do erase_cell(self._grid[row][c], self._pen) end
    end
  elseif final == "L" then -- IL: insert lines
    local n = param(params, 1, 1)
    for _ = 1, n do scroll_down(self, self._cursor_row, self._scroll_bottom) end
  elseif final == "M" then -- DL: delete lines
    local n = param(params, 1, 1)
    for _ = 1, n do scroll_up(self, self._cursor_row, self._scroll_bottom) end
  elseif final == "P" then -- DCH: delete characters
    local n = param(params, 1, 1)
    local row = self._cursor_row; local col = self._cursor_col
    local line = self._grid[row]
    for c = col, self._cols - n do line[c] = line[c + n] end
    for c = max(col, self._cols - n + 1), self._cols do line[c] = new_cell() end
  elseif final == "@" then -- ICH: insert characters
    local n = param(params, 1, 1)
    local row = self._cursor_row; local col = self._cursor_col
    local line = self._grid[row]
    for c = self._cols, col + n, -1 do line[c] = line[c - n] end
    for c = col, min(col + n - 1, self._cols) do line[c] = new_cell() end
  elseif final == "X" then -- ECH: erase characters
    local n = param(params, 1, 1)
    local row = self._cursor_row
    for c = self._cursor_col, min(self._cursor_col + n - 1, self._cols) do
      erase_cell(self._grid[row][c], self._pen)
    end
  elseif final == "S" then -- SU: scroll up
    local n = param(params, 1, 1)
    for _ = 1, n do scroll_up(self, self._scroll_top, self._scroll_bottom) end
  elseif final == "T" then -- SD: scroll down
    local n = param(params, 1, 1)
    for _ = 1, n do scroll_down(self, self._scroll_top, self._scroll_bottom) end
  elseif final == "d" then -- VPA: line position absolute
    self._cursor_row = max(1, min(self._rows, param(params, 1, 1)))
    self._wrap_pending = false
  elseif final == "m" then -- SGR
    sgr_dispatch(self, params)
  elseif final == "r" then -- DECSTBM: set scrolling region
    local top = param(params, 1, 1)
    local bot = param(params, 2, self._rows)
    if top < bot and top >= 1 and bot <= self._rows then
      self._scroll_top = top; self._scroll_bottom = bot
    end
    self._cursor_row = 1; self._cursor_col = 1; self._wrap_pending = false
  elseif final == "s" then -- ANSI save cursor
    self._saved_cursor_ansi = { row = self._cursor_row, col = self._cursor_col }
  elseif final == "u" then -- ANSI restore cursor
    if self._saved_cursor_ansi then
      self._cursor_row = self._saved_cursor_ansi.row
      self._cursor_col = self._saved_cursor_ansi.col
      self._wrap_pending = false
    end
  end
end

---------------------------------------------------------------------------
-- Parser state machine
---------------------------------------------------------------------------

-- States.
local ST_GROUND   = 0
local ST_ESC      = 1
local ST_CSI      = 2
local ST_OSC      = 3
local ST_DCS      = 4
local ST_ESC_HASH = 5  -- ESC # (DECDHL etc — ignored, but must consume)

--: (Term, string) -> nil
function Term:feed(data)
  local partial = self._partial
  if partial then
    data = partial .. data
    self._partial = nil
  end

  local i = 1
  local len = #data
  while i <= len do
    -- byte() is statically `integer | nil`; within the loop bound `i <= len`
    -- it always returns a value, so `-1` (never matched by any branch below)
    -- sidesteps a nil that cannot occur in practice.
    local b = byte(data, i) or -1
    local advance = 1 --: integer

    if self._state == ST_GROUND then
      if b == 0x1B then
        self._state = ST_ESC
      elseif b == 0x0D then -- CR
        self._cursor_col = 1; self._wrap_pending = false
      elseif b == 0x0A or b == 0x0B or b == 0x0C then -- LF / VT / FF
        line_feed(self)
      elseif b == 0x08 then -- BS
        if self._cursor_col > 1 then
          self._cursor_col = self._cursor_col - 1
          self._wrap_pending = false
        end
      elseif b == 0x09 then -- HT
        do_tab(self)
      elseif b == 0x07 then -- BEL
        -- ignore
      elseif b >= 0x20 and b <= 0x7E then
        put_char(self, char(b), 1)
      elseif b >= 0xC0 then
        -- UTF-8 lead byte.
        local cp, next_i = utf8_decode(data, i)
        if cp then
          local w = wcwidth(cp)
          if w >= 1 then
            put_char(self, sub(data, i, next_i - 1), w)
          end
          -- zero-width or control: skip
          advance = next_i - i
        else
          -- Incomplete UTF-8 at end of input — buffer for next feed().
          if i + 3 > len then
            self._partial = sub(data, i)
            return
          end
          -- Invalid sequence — skip the lead byte.
        end
      end
      -- Stray continuation bytes (0x80-0xBF) and C1 controls (0x80-0x9F)
      -- other than CSI (0x9B) are silently ignored.

    elseif self._state == ST_ESC then
      if b == 0x5B then -- [
        self._state = ST_CSI
        self._csi_params = ""
        self._csi_private = false
      elseif b == 0x5D then -- ]
        self._state = ST_OSC
        self._osc_buf = ""
      elseif b == 0x50 then -- P
        self._state = ST_DCS
      elseif b == 0x23 then -- #
        self._state = ST_ESC_HASH
      elseif b == 0x37 or b == byte("s") then -- ESC 7 / ESC s — save cursor (DECSC)
        self._saved_cursor_dec = {
          row = self._cursor_row, col = self._cursor_col,
          pen = copy_pen(self._pen),
        }
        self._state = ST_GROUND
      elseif b == 0x38 then -- ESC 8 — restore cursor (DECRC)
        if self._saved_cursor_dec then
          self._cursor_row = self._saved_cursor_dec.row
          self._cursor_col = self._saved_cursor_dec.col
          self._pen = copy_pen(self._saved_cursor_dec.pen)
          self._wrap_pending = false
        end
        self._state = ST_GROUND
      elseif b == 0x44 then -- ESC D — IND (index / cursor down + scroll)
        line_feed(self)
        self._state = ST_GROUND
      elseif b == 0x4D then -- ESC M — RI (reverse index / cursor up + scroll)
        reverse_index(self)
        self._state = ST_GROUND
      elseif b == 0x63 then -- ESC c — RIS (full reset)
        self:_reset()
        self._state = ST_GROUND
      else
        -- Unknown ESC sequence — return to ground.
        self._state = ST_GROUND
      end

    elseif self._state == ST_CSI then
      if b == 0x3F and self._csi_params == "" then -- ? at start
        self._csi_private = true
      elseif b >= 0x30 and b <= 0x39 then -- digit
        self._csi_params = self._csi_params .. char(b)
      elseif b == 0x3B then -- ;
        self._csi_params = self._csi_params .. ";"
      elseif b >= 0x40 and b <= 0x7E then -- final byte
        csi_dispatch(self, self._csi_params, char(b), self._csi_private)
        self._state = ST_GROUND
      elseif b == 0x1B then
        -- ESC inside CSI — abort CSI and re-enter ESC state.
        self._state = ST_ESC
      else
        -- Intermediate bytes (0x20-0x2F) or other — ignore and stay in CSI.
      end

    elseif self._state == ST_OSC then
      -- Consume until ST (ESC \) or BEL (0x07).
      if b == 0x07 then
        self._state = ST_GROUND
      elseif b == 0x1B then
        -- Check for ST (ESC \).
        if i + 1 <= len and byte(data, i + 1) == 0x5C then
          advance = 2
          self._state = ST_GROUND
        else
          self._state = ST_ESC
        end
      end
      -- Otherwise consume and ignore.

    elseif self._state == ST_DCS then
      -- Consume until ST (ESC \).
      if b == 0x1B then
        if i + 1 <= len and byte(data, i + 1) == 0x5C then
          advance = 2
          self._state = ST_GROUND
        end
      end

    elseif self._state == ST_ESC_HASH then
      -- ESC # <digit> — consume the digit and return to ground.
      self._state = ST_GROUND
    end

    i = i + advance
  end
end

---------------------------------------------------------------------------
-- Terminal reset
---------------------------------------------------------------------------

--: (Term) -> nil
function Term:_reset()
  self._grid = new_grid(self._rows, self._cols)
  self._alt_grid = new_grid(self._rows, self._cols)
  self._main_grid = nil
  self._alt_active = false
  self._cursor_row = 1
  self._cursor_col = 1
  self._cursor_visible = true
  self._wrap_pending = false
  self._pen = new_pen()
  self._scroll_top = 1
  self._scroll_bottom = self._rows
  self._tab_stops = default_tab_stops(self._cols)
  self._saved_cursor = nil
  self._saved_cursor_dec = nil
  self._saved_cursor_ansi = nil
  self._state = ST_GROUND
  self._csi_params = ""
  self._csi_private = false
  self._osc_buf = ""
  self._partial = nil
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Create a new terminal with the given dimensions.
--: (integer, integer) -> Term
function M.new(cols, rows)
  if type(cols) ~= "number" or type(rows) ~= "number" then
    error("vt.new: cols and rows must be numbers")
  end
  if cols < 1 or rows < 1 then
    error("vt.new: cols and rows must be >= 1")
  end
  local self = setmetatable({}, Term) --[[: Term]]
  -- floor(): defends against a caller passing a non-integer float (array
  -- sizes must be whole numbers), and as a side effect re-asserts `integer`
  -- after the `type(cols) ~= "number"` check above widens it to `number`
  -- (TYPECHECKER WORKAROUND — that widening-on-narrow is a substrate gap;
  -- see TODO.md).
  self._cols = floor(cols)
  self._rows = floor(rows)
  self:_reset()
  return self --[[: Term]]
end

-- Return the cell at (row, col). 1-indexed.
--: (Term, integer, integer) -> (Cell | nil, string | nil)
function Term:cell(row, col)
  if row < 1 or row > self._rows or col < 1 or col > self._cols then
    return nil, "cell: position out of bounds"
  end
  return self._grid[row][col]
end

-- Return current cursor position (row, col). 1-indexed.
--: (Term) -> (integer, integer)
function Term:cursor()
  return self._cursor_row, self._cursor_col
end

-- Return whether the cursor is visible.
--: (Term) -> boolean
function Term:cursor_visible()
  return self._cursor_visible
end

-- Return terminal dimensions (rows, cols).
--: (Term) -> (integer, integer)
function Term:size()
  return self._rows, self._cols
end

-- Resize the terminal. Content is truncated/padded; cursor is clamped.
-- Scroll region is preserved if it fits, otherwise reset to full screen.
--: (Term, integer, integer) -> nil
function Term:resize(new_rows, new_cols)
  if new_rows < 1 or new_cols < 1 then
    error("vt:resize: dimensions must be >= 1")
  end

  -- Drop the last element of an integer-indexed collection.
  -- NOTE: written by hand (not `table.remove`) as a TYPECHECKER WORKAROUND —
  -- calling the stdlib generic `table.remove` at two different type
  -- arguments (Line, then Grid) in the same file makes the second call
  -- reuse the first call's resolved type variable instead of a fresh
  -- instantiation (repro: local Cell/Line/Grid types, two `table.remove`
  -- calls at different types anywhere in one file — whichever comes first
  -- wins for the rest of the file). Filed as a substrate gap in TODO.md.
  --: ({ [integer]: unknown, ... }) -> nil
  local function pop(t)
    local n = #t
    if n > 0 then t[n] = nil end
  end

  --: (Grid, integer, integer, integer, integer) -> nil
  local function resize_grid(grid, old_rows, old_cols, nr, nc)
    -- Adjust columns in existing rows.
    for r = 1, min(old_rows, nr) do
      local line = grid[r]
      if nc > old_cols then
        for c = old_cols + 1, nc do line[c] = new_cell() end
      elseif nc < old_cols then
        for _ = nc + 1, old_cols do pop(line) end
      end
    end
    -- Add new rows.
    if nr > old_rows then
      for r = old_rows + 1, nr do grid[r] = new_line(nc) end
    end
    -- Remove excess rows.
    if nr < old_rows then
      for _ = nr + 1, old_rows do pop(grid) end
    end
  end

  local old_rows = self._rows
  local old_cols = self._cols

  resize_grid(self._grid, old_rows, old_cols, new_rows, new_cols)
  resize_grid(self._alt_grid, old_rows, old_cols, new_rows, new_cols)

  self._rows = new_rows
  self._cols = new_cols

  -- Clamp cursor.
  self._cursor_row = max(1, min(self._cursor_row, new_rows))
  self._cursor_col = max(1, min(self._cursor_col, new_cols))
  self._wrap_pending = false

  -- Scroll region: preserve if it fits, else reset.
  if self._scroll_top <= new_rows and self._scroll_bottom <= new_rows
      and self._scroll_top < self._scroll_bottom then
    -- keep
  else
    self._scroll_top = 1
    self._scroll_bottom = new_rows
  end

  self._tab_stops = default_tab_stops(new_cols)
end

---------------------------------------------------------------------------
-- Snapshot: render current screen state as ANSI escape sequences
---------------------------------------------------------------------------

-- Compare two color values for equality.
--: (Color | nil, Color | nil) -> boolean
local function colors_equal(a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  if a.space ~= b.space then return false end
  if a.space == "rgb" then return a.r == b.r and a.g == b.g and a.b == b.b end
  return a.n == b.n
end

-- Compare all attributes of two cells (excluding char, wide, _cont).
--: (Attrs, Attrs) -> boolean
local function attrs_equal(a, b)
  return a.bold == b.bold and a.dim == b.dim
    and a.underline == b.underline and a.reverse == b.reverse
    and colors_equal(a.fg, b.fg) and colors_equal(a.bg, b.bg)
end

-- Emit a color as SGR parameter string fragment.
--: (Color | nil, boolean) -> string | nil
local function color_sgr(color, is_bg)
  if not color then return nil end
  local base = is_bg and 40 or 30
  if color.space == "16" then
    local n = color.n
    if n < 8 then return tostring(base + n)
    else return tostring(base + 60 + n - 8) end
  elseif color.space == "256" then
    return tostring(base + 8) .. ";5;" .. tostring(color.n)
  else
    return tostring(base + 8) .. ";2;" .. color.r .. ";" .. color.g .. ";" .. color.b
  end
end

-- Build a full SGR sequence string for a cell (reset + set all attributes).
--: (Attrs) -> string
local function full_sgr(cell)
  local parts = { "0" } --: { [integer]: string }
  if cell.bold then parts[#parts + 1] = "1" end
  if cell.dim then parts[#parts + 1] = "2" end
  if cell.underline then parts[#parts + 1] = "4" end
  if cell.reverse then parts[#parts + 1] = "7" end
  local fg = color_sgr(cell.fg, false)
  if fg then parts[#parts + 1] = fg end
  local bg = color_sgr(cell.bg, true)
  if bg then parts[#parts + 1] = bg end
  return "\27[" .. concat(parts, ";") .. "m"
end

-- Produce a string of ANSI escape sequences that reconstructs the current
-- visible screen state. Fed to xterm.js on reconnect.
--: (Term) -> string
function Term:snapshot()
  local out = {}
  local k = 0

  --: (string) -> nil
  local function emit(s) k = k + 1; out[k] = s end

  -- Reset state.
  emit("\27[0m")

  -- If alternate screen is active, render main screen first so xterm.js
  -- has it saved, then switch to alt screen and render that.
  local grids_to_render
  if self._alt_active then
    grids_to_render = {
      { grid = self._main_grid, is_alt = false },
      { grid = self._grid,      is_alt = true  },
    }
  else
    grids_to_render = {
      { grid = self._grid, is_alt = false },
    }
  end

  for gi = 1, #grids_to_render do
    local entry = grids_to_render[gi]
    local grid = entry.grid

    if entry.is_alt then
      -- Position main-screen cursor before switching (DECSET 1049 saves it).
      if self._saved_cursor then
        emit("\27[" .. self._saved_cursor.row .. ";" .. self._saved_cursor.col .. "H")
      end
      emit("\27[?1049h")
    end

    -- Move to home and clear.
    emit("\27[H\27[2J")

    -- Track current attributes to minimize SGR output.
    local cur = { bold = false, dim = false, underline = false, reverse = false,
                  fg = nil, bg = nil } --: Attrs

    for r = 1, self._rows do
      -- Position cursor at start of row.
      emit("\27[" .. r .. ";1H")

      -- Find the last non-blank column to avoid trailing spaces.
      local last_col = 0
      for c = self._cols, 1, -1 do
        local cell = grid[r][c]
        if cell.char ~= "" or cell.fg or cell.bg
          or cell.bold or cell.dim or cell.underline or cell.reverse then
          last_col = c
          break
        end
      end

      local c = 1
      while c <= last_col do
        local cell = grid[r][c]

        -- Skip continuation cells (the wide char's first cell already wrote both).
        if cell._cont then
          c = c + 1
        else
          -- Emit SGR if attributes changed.
          if not attrs_equal(cur, cell) then
            emit(full_sgr(cell))
            cur.bold = cell.bold; cur.dim = cell.dim
            cur.underline = cell.underline; cur.reverse = cell.reverse
            cur.fg = cell.fg; cur.bg = cell.bg
          end

          -- Emit character.
          if cell.char == "" then
            emit(" ")
          else
            emit(cell.char)
          end

          c = c + 1
        end
      end
    end
  end

  -- Reset attributes.
  emit("\27[0m")

  -- Set scroll region if non-default.
  if self._scroll_top ~= 1 or self._scroll_bottom ~= self._rows then
    emit("\27[" .. self._scroll_top .. ";" .. self._scroll_bottom .. "r")
  end

  -- Restore cursor position.
  emit("\27[" .. self._cursor_row .. ";" .. self._cursor_col .. "H")

  -- Restore pen (so subsequent input has correct attributes).
  local pen_cell = {
    bold = self._pen.bold, dim = self._pen.dim,
    underline = self._pen.underline, reverse = self._pen.reverse,
    fg = self._pen.fg, bg = self._pen.bg,
  } --: Attrs
  emit(full_sgr(pen_cell))

  -- Cursor visibility.
  if not self._cursor_visible then
    emit("\27[?25l")
  end

  return concat(out)
end

return M
