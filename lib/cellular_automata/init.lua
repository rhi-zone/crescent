if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Cellular automata library.
-- Supports 1D elementary Wolfram rules and 2D totalistic grid automata
-- (Conway's Life, Brian's Brain, Seeds, etc.).
-- Pure Lua, no dependencies.
local M = {}
M._tier = "pure"

local bit = bit or require("bit")
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift

-- ── 1D Elementary Cellular Automata (Wolfram rules) ────────────────────────

-- Precompute lookup table for a given rule number (0–255).
-- rule_table[pattern] = output, where pattern is a 3-bit integer (left, center, right).
local function build_rule_table(n)
  local t = {}
  for i = 0, 7 do
    t[i] = band(rshift(n, i), 1)
  end
  return t
end

-- Automaton object for 1D rules.
local Rule1D = {}
Rule1D.__index = Rule1D

--- Initialize a row with a single live cell in the center.
-- Returns an array of 0/1 values of length `width`.
function Rule1D:init_single(width)
  local row = {}
  for i = 1, width do row[i] = 0 end
  row[math.floor(width / 2) + 1] = 1
  return row
end

--- Initialize a row with random values using a simple LCG seeded by `seed`.
-- Returns an array of 0/1 values of length `width`.
function Rule1D:init_random(width, seed)
  local s = seed or 12345
  local row = {}
  for i = 1, width do
    s = band(s * 1664525 + 1013904223, 0xffffffff)
    row[i] = band(s, 1)
  end
  return row
end

--- Advance one generation.
-- Returns a new row of the same length.
function Rule1D:step(row)
  local n = #row
  local t = self._table
  local next = {}
  for i = 1, n do
    local l = row[i == 1 and n or i - 1]
    local c = row[i]
    local r = row[i == n and 1 or i + 1]
    next[i] = t[bor(lshift(l, 2), bor(lshift(c, 1), r))]
  end
  return next
end

--- Run `steps` generations from `row`.
-- Returns an array of rows (including the initial row at index 1).
function Rule1D:run(row, steps)
  local history = { row }
  local cur = row
  for _ = 1, steps do
    cur = self:step(cur)
    history[#history + 1] = cur
  end
  return history
end

--- Create a 1D elementary cellular automaton for Wolfram rule `n` (0–255).
function M.rule1d(n)
  if type(n) ~= "number" or n < 0 or n > 255 then
    return nil, "rule1d: rule number must be 0–255"
  end
  local a = setmetatable({}, Rule1D)
  a._rule = n
  a._table = build_rule_table(n)
  return a
end

-- ── 2D Grid Automaton ───────────────────────────────────────────────────────

local Grid2D = {}
Grid2D.__index = Grid2D

--- Get cell value at (x, y). Returns 0 for out-of-bounds (non-wrapping).
function Grid2D:get(x, y)
  if x < 1 or x > self.width or y < 1 or y > self.height then
    return 0
  end
  return self._cells[y][x]
end

--- Set cell value at (x, y). Returns nil, errmsg on out-of-bounds.
function Grid2D:set(x, y, v)
  if x < 1 or x > self.width or y < 1 or y > self.height then
    return nil, "grid2d: position out of bounds"
  end
  self._cells[y][x] = v or 0
  return true
end

--- Clear all cells to 0.
function Grid2D:clear()
  for y = 1, self.height do
    local row = self._cells[y]
    for x = 1, self.width do
      row[x] = 0
    end
  end
end

-- Count alive (state >= 1) Moore neighbors for cell (x, y).
-- Handles wrap and non-wrap boundaries.
local function count_neighbors(cells, x, y, w, h, wrap)
  local count = 0
  for dy = -1, 1 do
    for dx = -1, 1 do
      if not (dx == 0 and dy == 0) then
        local nx = x + dx
        local ny = y + dy
        if wrap then
          if nx < 1 then nx = w elseif nx > w then nx = 1 end
          if ny < 1 then ny = h elseif ny > h then ny = 1 end
          if cells[ny][nx] == 1 then count = count + 1 end
        else
          if nx >= 1 and nx <= w and ny >= 1 and ny <= h then
            if cells[ny][nx] == 1 then count = count + 1 end
          end
        end
      end
    end
  end
  return count
end

--- Advance one generation in-place.
function Grid2D:step()
  local w, h = self.width, self.height
  local wrap = self.wrap
  local birth = self._birth
  local survive = self._survive
  local states = self.states
  local cells = self._cells
  -- Allocate next generation.
  local next = {}
  for y = 1, h do
    local row = {}
    next[y] = row
    local cur_row = cells[y]
    for x = 1, w do
      local cur = cur_row[x]
      if states == 2 then
        -- Standard 2-state totalistic rule.
        local n = count_neighbors(cells, x, y, w, h, wrap)
        if cur == 1 then
          row[x] = survive[n] and 1 or 0
        else
          row[x] = birth[n] and 1 or 0
        end
      else
        -- Multi-state (e.g. Brian's Brain: states=3).
        -- State 0 = dead, 1 = alive, 2..states-1 = dying.
        -- Birth: dead cell with exactly birth-count alive (state==1) neighbors.
        -- Alive cells advance to dying (state 2).
        -- Dying cells advance toward dead (state 0 when they reach states-1).
        if cur == 0 then
          -- Count only state==1 neighbors for birth.
          local alive_n = 0
          for dy = -1, 1 do
            for dx = -1, 1 do
              if not (dx == 0 and dy == 0) then
                local nx2 = x + dx
                local ny2 = y + dy
                if wrap then
                  if nx2 < 1 then nx2 = w elseif nx2 > w then nx2 = 1 end
                  if ny2 < 1 then ny2 = h elseif ny2 > h then ny2 = 1 end
                  if cells[ny2][nx2] == 1 then alive_n = alive_n + 1 end
                else
                  if nx2 >= 1 and nx2 <= w and ny2 >= 1 and ny2 <= h then
                    if cells[ny2][nx2] == 1 then alive_n = alive_n + 1 end
                  end
                end
              end
            end
          end
          row[x] = birth[alive_n] and 1 or 0
        elseif cur == 1 then
          -- Alive → dying (next state).
          row[x] = 2
        else
          -- Dying: advance toward dead.
          row[x] = cur + 1 < states and cur + 1 or 0
        end
      end
    end
  end
  self._cells = next
end

--- Advance `n` generations in-place.
function Grid2D:step_n(n)
  for _ = 1, n do self:step() end
end

--- Count alive cells (state == 1) in the grid.
function Grid2D:count_alive()
  local count = 0
  local cells = self._cells
  for y = 1, self.height do
    local row = cells[y]
    for x = 1, self.width do
      if row[x] == 1 then count = count + 1 end
    end
  end
  return count
end

--- Count cells in a specific state.
function Grid2D:count_state(s)
  local count = 0
  local cells = self._cells
  for y = 1, self.height do
    local row = cells[y]
    for x = 1, self.width do
      if row[x] == s then count = count + 1 end
    end
  end
  return count
end

--- Return array of {x, y} for all alive (state==1) cells.
function Grid2D:alive_cells()
  local result = {}
  local cells = self._cells
  for y = 1, self.height do
    local row = cells[y]
    for x = 1, self.width do
      if row[x] == 1 then
        result[#result + 1] = { x, y }
      end
    end
  end
  return result
end

--- Render the grid as a string using `on` for alive cells and `off` for dead.
function Grid2D:to_string(on, off)
  on = on or "1"
  off = off or "0"
  local lines = {}
  local cells = self._cells
  for y = 1, self.height do
    local row = cells[y]
    local parts = {}
    for x = 1, self.width do
      parts[x] = row[x] == 1 and on or off
    end
    lines[y] = table.concat(parts)
  end
  return table.concat(lines, "\n")
end

--- Place a pattern at (ox, oy). Pattern is a 2D array of rows of 0/1 values.
-- Out-of-bounds cells are ignored.
function Grid2D:place_pattern(ox, oy, pattern)
  for ry = 1, #pattern do
    local row = pattern[ry]
    for rx = 1, #row do
      local x = ox + rx - 1
      local y = oy + ry - 1
      if x >= 1 and x <= self.width and y >= 1 and y <= self.height then
        self._cells[y][x] = row[rx]
      end
    end
  end
end

--- Load a grid from ASCII art. `on_char` is the character for alive cells (default "#").
-- Newlines separate rows. The grid is resized to fit.
function Grid2D:from_string(s, on_char)
  on_char = on_char or "#"
  local rows = {}
  local max_w = 0
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    if #line > 0 then
      local row = {}
      for i = 1, #line do
        row[i] = line:sub(i, i) == on_char and 1 or 0
      end
      if #row > max_w then max_w = #row end
      rows[#rows + 1] = row
    end
  end
  -- Pad rows to max_w.
  for _, row in ipairs(rows) do
    for i = #row + 1, max_w do row[i] = 0 end
  end
  self._cells = rows
  self.width = max_w
  self.height = #rows
end

--- Create a 2D grid automaton.
-- opts: { width, height, birth, survive, wrap, states }
-- birth/survive are arrays of neighbor counts, e.g. birth={3}, survive={2,3}.
function M.grid2d(opts)
  if not opts then return nil, "grid2d: opts required" end
  local width = opts.width or 80
  local height = opts.height or 40
  local states = opts.states or 2
  local wrap = opts.wrap ~= false  -- default true

  -- Convert birth/survive arrays to lookup tables for O(1) access.
  local birth_lut = {}
  for _, n in ipairs(opts.birth or {}) do birth_lut[n] = true end
  local survive_lut = {}
  for _, n in ipairs(opts.survive or {}) do survive_lut[n] = true end

  -- Allocate cells.
  local cells = {}
  for y = 1, height do
    local row = {}
    for x = 1, width do row[x] = 0 end
    cells[y] = row
  end

  local g = setmetatable({}, Grid2D)
  g.width = width
  g.height = height
  g.states = states
  g.wrap = wrap
  g._birth = birth_lut
  g._survive = survive_lut
  g._cells = cells
  return g
end

-- ── Classic Patterns ────────────────────────────────────────────────────────

M.patterns = {}

-- Glider (period 4, translates diagonally).
M.patterns.glider = {
  { 0, 1, 0 },
  { 0, 0, 1 },
  { 1, 1, 1 },
}

-- Blinker (period 2 oscillator).
M.patterns.blinker = {
  { 1, 1, 1 },
}

-- Toad (period 2 oscillator).
M.patterns.toad = {
  { 0, 1, 1, 1 },
  { 1, 1, 1, 0 },
}

-- Beacon (period 2 oscillator).
M.patterns.beacon = {
  { 1, 1, 0, 0 },
  { 1, 1, 0, 0 },
  { 0, 0, 1, 1 },
  { 0, 0, 1, 1 },
}

-- Pulsar (period 3 oscillator).
M.patterns.pulsar = {
  { 0,0,1,1,1,0,0,0,1,1,1,0,0 },
  { 0,0,0,0,0,0,0,0,0,0,0,0,0 },
  { 1,0,0,0,0,1,0,1,0,0,0,0,1 },
  { 1,0,0,0,0,1,0,1,0,0,0,0,1 },
  { 1,0,0,0,0,1,0,1,0,0,0,0,1 },
  { 0,0,1,1,1,0,0,0,1,1,1,0,0 },
  { 0,0,0,0,0,0,0,0,0,0,0,0,0 },
  { 0,0,1,1,1,0,0,0,1,1,1,0,0 },
  { 1,0,0,0,0,1,0,1,0,0,0,0,1 },
  { 1,0,0,0,0,1,0,1,0,0,0,0,1 },
  { 1,0,0,0,0,1,0,1,0,0,0,0,1 },
  { 0,0,0,0,0,0,0,0,0,0,0,0,0 },
  { 0,0,1,1,1,0,0,0,1,1,1,0,0 },
}

-- R-pentomino (methuselah, lives 1103 generations).
M.patterns.r_pentomino = {
  { 0, 1, 1 },
  { 1, 1, 0 },
  { 0, 1, 0 },
}

-- Diehard (disappears after 130 generations).
M.patterns.diehard = {
  { 0,0,0,0,0,0,1,0 },
  { 1,1,0,0,0,0,0,0 },
  { 0,1,0,0,0,1,1,1 },
}

-- Acorn (produces gliders and other structures, stabilizes after 5206 generations).
M.patterns.acorn = {
  { 0,1,0,0,0,0,0 },
  { 0,0,0,1,0,0,0 },
  { 1,1,0,0,1,1,1 },
}

-- Gosper Glider Gun (period 30, first known pattern to produce unbounded growth).
M.patterns.glider_gun = {
  { 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0 },
  { 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,1,0,0,0,0,0,0,0,0,0,0,0 },
  { 0,0,0,0,0,0,0,0,0,0,0,0,1,1,0,0,0,0,0,0,1,1,0,0,0,0,0,0,0,0,0,0,0,0,1,1 },
  { 0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,1,0,0,0,0,1,1,0,0,0,0,0,0,0,0,0,0,0,0,1,1 },
  { 1,1,0,0,0,0,0,0,0,0,1,0,0,0,0,0,1,0,0,0,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0 },
  { 1,1,0,0,0,0,0,0,0,0,1,0,0,0,1,0,1,1,0,0,0,0,1,0,1,0,0,0,0,0,0,0,0,0,0,0 },
  { 0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,1,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0 },
  { 0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 },
  { 0,0,0,0,0,0,0,0,0,0,0,0,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 },
}

-- 2×2 Block (still life).
M.patterns.block = {
  { 1, 1 },
  { 1, 1 },
}

return M
