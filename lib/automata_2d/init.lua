if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Advanced 2D cellular automata: Conway's Game of Life variants, totalistic rules,
--- and spatial hash for sparse grids.
--- Pure Lua, no dependencies.
local M = {}
M._tier = "pure"

local math2 = require("lib.math")

--:: RuleFn = (integer, integer) -> integer
--:: DenseGrid = { _w: integer, _h: integer, _wrap: boolean, _rule: RuleFn, _buf: { [integer]: integer }, _gen: integer }
--:: SparseGrid = { _cells: { [string]: boolean }, _rule: RuleFn }
--:: Cell2D = { [integer]: integer }

-- Hash key for sparse grid: encode (x,y) as a string to support arbitrary
-- (including negative) integer coordinates without overflow.
--: (number, number) -> string
local function key(x, y) return x .. "," .. y end
-- Decode a key back to x, y.
--: (string) -> (integer, integer)
local function unkey(k)
  local x, y = k:match("^(-?%d+),(-?%d+)$")
  return math2.tointeger(x) or 0, math2.tointeger(y) or 0
end

-- BIG is kept for the RLE encoder's internal set (non-negative coords only in RLE output).
local BIG = 2^20  -- 1048576

-- ── B/S Rule Parsing ──────────────────────────────────────────────────────────

--- Parse a B/S notation string like "B3/S23" into birth and survive lookup tables.
-- Returns birth_lut, survive_lut (tables where t[n]=true for valid neighbor counts).
local function parse_bs(rule_str)
  local b_str, s_str = rule_str:match("^[Bb]([0-8]*)/[Ss]([0-8]*)$")
  if not b_str then
    return nil, nil, "parse_rule: invalid B/S notation: " .. tostring(rule_str)
  end
  local birth = {}
  for c in b_str:gmatch("%d") do birth[tonumber(c)] = true end
  local survive = {}
  for c in s_str:gmatch("%d") do survive[tonumber(c)] = true end
  return birth, survive
end

--- Parse a B/S rule string and return a rule function.
-- The rule function has signature: function(neighbors, current) -> next_state (0 or 1)
--: (string) -> (RuleFn | nil, string | nil)
function M.parse_rule(rule_str)
  local birth, survive, err = parse_bs(rule_str)
  if not birth then return nil, err end
  return function(n, c)
    if c == 1 then
      return survive[n] and 1 or 0
    else
      return birth[n] and 1 or 0
    end
  end
end

-- ── Built-in Rules ────────────────────────────────────────────────────────────

M.rules = {} --: { [string]: RuleFn }

do
  local function rule(s) local f = (M.parse_rule(s)); return f --[[:! RuleFn]] end
  -- B3/S23 — Conway's Life
  M.rules.life = rule("B3/S23")
  -- B36/S23 — HighLife (supports replicators)
  M.rules.highlife = rule("B36/S23")
  -- B2/S — Seeds (birth on 2 neighbors, no survival)
  M.rules.seeds = rule("B2/S")
  -- B3678/S34678 — Day & Night
  M.rules.day_and_night = rule("B3678/S34678")
  -- B4678/S35678 — Anneal
  M.rules.anneal = rule("B4678/S35678")
  -- B1357/S1357 — Replicator
  M.rules.replicator = rule("B1357/S1357")
end

-- ── Dense Grid ────────────────────────────────────────────────────────────────

local DenseGrid = {}
DenseGrid.__index = DenseGrid

--- Get cell value at 0-indexed (x, y). Returns 0 for out-of-bounds.
function DenseGrid:get(x, y)
  local self_ = self --[[:! DenseGrid]]
  if x < 0 or x >= self_._w or y < 0 or y >= self_._h then return 0 end
  return self_._buf[y * self_._w + x + 1]
end

--- Set cell value at 0-indexed (x, y). Returns nil, errmsg on out-of-bounds.
function DenseGrid:set(x, y, value)
  local self_ = self --[[:! DenseGrid]]
  if x < 0 or x >= self_._w or y < 0 or y >= self_._h then
    return nil, "dense:set: position out of bounds"
  end
  self_._buf[y * self_._w + x + 1] = value or 0
  return true
end

--- Clear all cells to 0.
function DenseGrid:clear()
  local self_ = self --[[:! DenseGrid]]
  local buf = self_._buf
  local sz = self_._w * self_._h
  for i = 1, sz do buf[i] = 0 end
end

--- Return the number of live cells.
function DenseGrid:population()
  local self_ = self --[[:! DenseGrid]]
  local count = 0
  local buf = self_._buf
  local sz = self_._w * self_._h
  for i = 1, sz do
    if buf[i] == 1 then count = count + 1 end
  end
  return count
end

--- Return the number of steps taken.
function DenseGrid:generation()
  local self_ = self --[[:! DenseGrid]]
  return self_._gen
end

--- Return an array of {x, y} (0-indexed) for all live cells.
function DenseGrid:alive_cells()
  local self_ = self --[[:! DenseGrid]]
  local result = {} --: { [integer]: Cell2D }
  local buf = self_._buf
  local w, h = self_._w, self_._h
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      if buf[y * w + x + 1] == 1 then
        result[#result + 1] = {x, y}
      end
    end
  end
  return result
end

--- Set cells from an array of {x, y} (like alive_cells output). Clears first.
function DenseGrid:pattern(cells)
  local self_ = self --[[:! DenseGrid]]
  DenseGrid.clear(self_)
  for _, cell in ipairs(cells) do
    local cell_ = cell --[[:! Cell2D]]
    DenseGrid.set(self_, cell_[1], cell_[2], 1)
  end
end

--- Count Moore neighbors at 0-indexed (x, y) in a flat buffer.
local function dense_neighbors(buf, x, y, w, h, wrap)
  local count = 0
  for dy = -1, 1 do
    for dx = -1, 1 do
      if not (dx == 0 and dy == 0) then
        local nx = x + dx
        local ny = y + dy
        if wrap then
          if nx < 0 then nx = w - 1 elseif nx >= w then nx = 0 end
          if ny < 0 then ny = h - 1 elseif ny >= h then ny = 0 end
          if buf[ny * w + nx + 1] == 1 then count = count + 1 end
        else
          if nx >= 0 and nx < w and ny >= 0 and ny < h then
            if buf[ny * w + nx + 1] == 1 then count = count + 1 end
          end
        end
      end
    end
  end
  return count
end

--- Advance one generation.
function DenseGrid:step()
  local self_ = self --[[:! DenseGrid]]
  local w, h = self_._w, self_._h
  local wrap = self_._wrap
  local rule = self_._rule
  local buf = self_._buf
  -- Allocate next buffer.
  local next = {} --: { [integer]: integer }
  for i = 1, w * h do next[i] = 0 end
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local cur = buf[y * w + x + 1]
      local n = dense_neighbors(buf, x, y, w, h, wrap)
      next[y * w + x + 1] = rule(n, cur)
    end
  end
  self_._buf = next
  self_._gen = self_._gen + 1
end

--- Advance n generations.
function DenseGrid:step_n(n)
  for _ = 1, n do self:step() end
end

--- Create a dense grid.
-- opts: { rule="life"|"highlife"|..., wrap=true }
--: (integer, integer, { rule?: string | RuleFn, wrap?: boolean } | nil) -> (DenseGrid | nil, string | nil)
function M.dense(width, height, opts)
  opts = opts or {}
  local rule_name = opts.rule or "life"
  local rule_fn
  if type(rule_name) == "function" then
    rule_fn = rule_name
  elseif M.rules[rule_name] then
    rule_fn = M.rules[rule_name]
  else
    -- Try to parse it as B/S notation.
    local fn, err = M.parse_rule(rule_name --[[:! string]])
    if not fn then
      local detail = err and (" (" .. (err or "") .. ")") or ""
      return nil, "dense: unknown rule: " .. tostring(rule_name) .. detail
    end
    rule_fn = fn
  end
  local buf = {} --: { [integer]: integer }
  for i = 1, width * height do buf[i] = 0 end
  local gen0 = 0 --: integer
  local g = setmetatable({
    _w = width,
    _h = height,
    _wrap = opts.wrap ~= false,
    _rule = rule_fn --[[:! RuleFn]],
    _buf = buf,
    _gen = gen0,
  }, DenseGrid) --[[:! DenseGrid]]
  return g
end

-- ── Sparse Grid ───────────────────────────────────────────────────────────────

local SparseGrid = {}
SparseGrid.__index = SparseGrid

--- Mark cell (x, y) alive.
function SparseGrid:set(x, y)
  local self_ = self --[[:! SparseGrid]]
  self_._cells[key(x, y)] = true
end

--- Mark cell (x, y) dead.
function SparseGrid:unset(x, y)
  local self_ = self --[[:! SparseGrid]]
  self_._cells[key(x, y)] = nil
end

--- Returns 1 if alive, 0 if dead.
function SparseGrid:get(x, y)
  local self_ = self --[[:! SparseGrid]]
  return self_._cells[key(x, y)] and 1 or 0
end

--- Return the number of live cells.
function SparseGrid:population()
  local self_ = self --[[:! SparseGrid]]
  local count = 0
  for _ in pairs(self_._cells) do count = count + 1 end
  return count
end

--- Return an array of {x, y} for all live cells.
function SparseGrid:alive_cells()
  local self_ = self --[[:! SparseGrid]]
  local result = {} --: { [integer]: Cell2D }
  for k in pairs(self_._cells) do
    local x, y = unkey(k)
    result[#result + 1] = {x, y}
  end
  return result
end

--- Return {min_x, min_y, max_x, max_y} bounding box of live cells.
-- Returns nil if no live cells.
function SparseGrid:bounds()
  local self_ = self --[[:! SparseGrid]]
  local first = true
  local min_x = 0 --: number
  local min_y = 0 --: number
  local max_x = 0 --: number
  local max_y = 0 --: number
  for k in pairs(self_._cells) do
    local x, y = unkey(k)
    if first then
      min_x, min_y, max_x, max_y = x, y, x, y
      first = false
    else
      if x < min_x then min_x = x end
      if x > max_x then max_x = x end
      if y < min_y then min_y = y end
      if y > max_y then max_y = y end
    end
  end
  if first then return nil end
  return {min_x, min_y, max_x, max_y}
end

--- Set cells from an array of {x, y}. Clears first.
function SparseGrid:pattern(cells)
  local self_ = self --[[:! SparseGrid]]
  self_._cells = {}
  for _, cell in ipairs(cells) do
    local cell_ = cell --[[:! Cell2D]]
    SparseGrid.set(self_, cell_[1], cell_[2])
  end
end

--- Count alive Moore neighbors at (x, y) in sparse cells table.
--: ({ [string]: boolean }, number, number) -> integer
local function sparse_neighbors(cells, x, y)
  local n = 0
  for dy = -1, 1 do
    for dx = -1, 1 do
      if not (dx == 0 and dy == 0) then
        if cells[key(x + dx, y + dy)] then n = n + 1 end
      end
    end
  end
  return n
end

--- Advance one generation.
function SparseGrid:step()
  local self_ = self --[[:! SparseGrid]]
  local old = self_._cells
  local rule = self_._rule
  -- Collect candidates: all alive cells + all their neighbors.
  local candidates = {} --: { [string]: boolean }
  for k in pairs(old) do
    local x, y = unkey(k)
    for dy = -1, 1 do
      for dx = -1, 1 do
        candidates[key(x + dx, y + dy)] = true
      end
    end
  end
  -- Apply rule to each candidate.
  local new_cells = {} --: { [string]: boolean }
  for k in pairs(candidates) do
    local x, y = unkey(k)
    local cur = old[k] and 1 or 0
    local n = sparse_neighbors(old, x, y)
    local next_state = rule(n, cur)
    if next_state == 1 or next_state == true then
      new_cells[k] = true
    end
  end
  self_._cells = new_cells
end

--- Advance n generations.
function SparseGrid:step_n(n)
  for _ = 1, n do self:step() end
end

--- Create a sparse (infinite) grid.
-- rule_fn: function(neighbors, current) -> next_state
function M.sparse(rule_fn)
  if type(rule_fn) ~= "function" then
    return nil, "sparse: rule_fn must be a function"
  end
  local rule_fn_ = rule_fn --[[:! RuleFn]]
  local g = setmetatable({
    _cells = {},
    _rule = rule_fn_,
  }, SparseGrid) --[[:! SparseGrid]]
  return g
end

-- ── RLE Codec ─────────────────────────────────────────────────────────────────

--- Decode a Life RLE string into an array of {x, y} alive cells (0-indexed).
-- Supports standard RLE: digits for run length, 'b'=dead, 'o'=alive,
-- '$'=end of row, '!'=end of pattern. Ignores comments (#... lines) and
-- header lines (x = ...).
--: (string) -> { [integer]: Cell2D }
function M.rle_decode(rle_str)
  local cells = {} --: { [integer]: Cell2D }
  local x, y = 0, 0
  local run = 0

  -- Strip comment/header lines.
  local data = rle_str:gsub("^[^\n]*x%s*=[^\n]*\n", "")
  data = data:gsub("#[^\n]*\n?", "")

  for i = 1, #data do
    local c = data:sub(i, i)
    if c:match("%d") then
      run = run * 10 + (math2.tointeger(c) or 0)
    elseif c == "b" then
      -- Dead cells: advance x.
      local count = run == 0 and 1 or run
      x = x + count
      run = 0
    elseif c == "o" then
      -- Alive cells.
      local count = run == 0 and 1 or run
      for j = 0, count - 1 do
        cells[#cells + 1] = {x + j, y}
      end
      x = x + count
      run = 0
    elseif c == "$" then
      -- End of row.
      local count = run == 0 and 1 or run
      y = y + count
      x = 0
      run = 0
    elseif c == "!" then
      break
    end
    -- Ignore whitespace and unknown chars.
  end
  return cells
end

--- Encode an array of {x, y} alive cells (0-indexed) to RLE string.
-- Sorts by y then x and produces compact RLE output.
--: ({ [integer]: Cell2D }) -> string
function M.rle_encode(cells)
  if #cells == 0 then return "!" end

  -- Sort cells by y then x.
  local sorted = {}
  for i, c in ipairs(cells) do sorted[i] = c end
  table.sort(sorted, function(a, b)
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)

  -- Find bounding box.
  local min_x = sorted[1][1]
  for _, c in ipairs(sorted) do
    if c[1] < min_x then min_x = c[1] end
  end

  -- Build a set for fast lookup.
  local cell_set = {}
  for _, c in ipairs(sorted) do
    cell_set[c[2] * BIG + c[1]] = true
  end

  -- Find bounds.
  local min_y = sorted[1][2]
  local max_y = sorted[#sorted][2]
  local max_x_val = sorted[1][1]
  for _, c in ipairs(sorted) do
    if c[1] > max_x_val then max_x_val = c[1] end
  end

  -- Produce row-by-row RLE.
  local parts = {} --: { [integer]: string }
  local prev_y = min_y

  -- Group cells by row.
  local rows = {} --: { [integer]: { [integer]: integer } }
  for _, c in ipairs(sorted) do
    local ry = c[2] --[[:! integer]]
    if not rows[ry] then rows[ry] = {} end
    rows[ry][#rows[ry] + 1] = c[1] --[[:! integer]]
  end

  local first_row = true
  for ry = min_y, max_y do
    -- Emit row separator(s).
    if not first_row then
      local gap = ry - prev_y
      if gap == 1 then
        parts[#parts + 1] = "$"
      else
        parts[#parts + 1] = tostring(gap) .. "$"
      end
    end
    first_row = false
    prev_y = ry

    local row_xs = rows[ry]
    if row_xs then
      -- row_xs is sorted (came from sorted cells).
      -- Find min/max x in row.
      local row_min_x = row_xs[1]
      local row_max_x = row_xs[#row_xs]
      local xs_set = {} --: { [integer]: boolean }
      for _, rx in ipairs(row_xs) do xs_set[rx] = true end

      -- Encode row as run-length of b/o.
      -- Only encode up to the last alive cell (trailing dead cells omitted).
      local x = row_min_x
      while x <= row_max_x do
        local alive = xs_set[x]
        local count = 1
        while x + count <= row_max_x and (xs_set[x + count] and alive or (not xs_set[x + count] and not alive)) do
          count = count + 1
        end
        -- Only emit dead cells if there are cells after them.
        if not alive then
          -- Check if any alive cells follow.
          local has_more = false
          for check = x + count, row_max_x do
            if xs_set[check] then has_more = true; break end
          end
          if has_more then
            parts[#parts + 1] = (count == 1 and "" or tostring(count)) .. "b"
          end
        else
          parts[#parts + 1] = (count == 1 and "" or tostring(count)) .. "o"
        end
        x = x + count
      end
    end
    -- If no cells in row, just the "$" separator already added.
  end
  parts[#parts + 1] = "!"
  return table.concat(parts)
end

-- ── Common Patterns ───────────────────────────────────────────────────────────

M.patterns = {}

-- All patterns use 0-indexed {x, y} arrays.

-- Glider (5 cells, period 4 in life).
M.patterns.glider = {
  {1, 0},
  {2, 1},
  {0, 2}, {1, 2}, {2, 2},
}

-- Blinker (3 cells, period 2 oscillator).
M.patterns.blinker = {
  {0, 0}, {1, 0}, {2, 0},
}

-- Block (4 cells, still life).
M.patterns.block = {
  {0, 0}, {1, 0},
  {0, 1}, {1, 1},
}

-- Gosper Glider Gun (produces a new glider every 30 generations).
-- Standard Gosper glider gun pattern (36 cells).
M.patterns.glider_gun = {
  {24,0},
  {22,1},{24,1},
  {12,2},{13,2},{20,2},{21,2},{34,2},{35,2},
  {11,3},{15,3},{20,3},{21,3},{34,3},{35,3},
  {0,4},{1,4},{10,4},{16,4},{20,4},{21,4},
  {0,5},{1,5},{10,5},{14,5},{16,5},{17,5},{22,5},{24,5},
  {10,6},{16,6},{24,6},
  {11,7},{15,7},
  {12,8},{13,8},
}

return M
