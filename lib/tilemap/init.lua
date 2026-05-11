if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: TileMap = { _width: number, _height: number, _tiles: { [integer]: unknown }, _tile_size: number, in_bounds: (self: TileMap, x: number, y: number) -> boolean, get: (self: TileMap, x: number, y: number) -> unknown, set: (self: TileMap, x: number, y: number, value: unknown) -> (boolean | nil, string | nil), fill: (self: TileMap, x: number, y: number, w: number, h: number, value: unknown) -> nil }
--:: HeapEntry = { key: integer, p: number }
--:: Heap = { _data: { [integer]: HeapEntry }, _size: integer, push: (self: Heap, key: integer, priority: number) -> nil, pop: (self: Heap) -> integer | nil, empty: (self: Heap) -> boolean }
--:: RoomRect = { x: number, y: number, w: number, h: number, cx: number, cy: number }
--:: Dir = { [integer]: integer }
--:: Rng = { next: (self: Rng) -> integer, range: (self: Rng, lo: integer, hi: integer) -> integer, float: (self: Rng) -> number }

-- ========================
-- INTERNAL HELPERS
-- ========================

-- Min-heap for A* open set
local Heap = {}
Heap.__index = Heap

--: () -> Heap
local function heap_new()
  local h = setmetatable({ _data = {}, _size = 0 }, Heap) --[[: unknown]]
  return h --[[:! Heap]]
end

--: (self: Heap, key: integer, priority: number) -> nil
function Heap:push(key, priority)
  self._size = self._size + 1
  self._data[self._size] = { key = key, p = priority }
  -- sift up
  local i = self._size
  local d = self._data
  while i > 1 do
    local parent = math.floor(i / 2)
    if d[parent].p > d[i].p then
      d[parent], d[i] = d[i], d[parent]
      i = parent
    else
      break
    end
  end
end

--: (self: Heap) -> integer | nil
function Heap:pop()
  if self._size == 0 then return nil
  else
  local d = self._data
  local top = d[1].key
  d[1] = d[self._size]
  d[self._size] = nil --[[: unknown]]
  self._size = self._size - 1
  -- sift down
  local i = 1
  local n = self._size
  while true do
    local left = i * 2
    local right = i * 2 + 1
    local smallest = i
    if left <= n and d[left].p < d[smallest].p then smallest = left end
    if right <= n and d[right].p < d[smallest].p then smallest = right end
    if smallest == i then break end
    d[i], d[smallest] = d[smallest], d[i]
    i = smallest
  end
  return top
  end
end

--: (self: Heap) -> boolean
function Heap:empty()
  return self._size == 0
end

-- ========================
-- TILEMAP OBJECT
-- ========================

local TileMap = {}
TileMap.__index = TileMap

--- Create a new tilemap.
-- width, height: dimensions (number of columns and rows)
-- opts.default_tile: initial tile value (default 0)
-- opts.tile_size: pixels per tile for coordinate conversion (default 16)
--: (width: unknown, height: unknown, opts: { default_tile: unknown, tile_size: number | nil } | nil) -> (TileMap | nil, string | nil)
function M.new(width, height, opts)
  if type(width) ~= "number" then return nil, "width must be a positive number" end
  local w = width --[[:! number]]
  if w < 1 then return nil, "width must be a positive number" end
  if type(height) ~= "number" then return nil, "height must be a positive number" end
  local h = height --[[:! number]]
  if h < 1 then return nil, "height must be a positive number" end
  local opts_ = (opts or {}) --[[:! { default_tile: unknown, tile_size: number | nil }]]
  local default = opts_.default_tile or 0
  local tiles = {} --: { [integer]: unknown }
  local n = w * h
  for i = 1, n do
    tiles[i] = default
  end
  local tm = setmetatable({
    _width = w,
    _height = h,
    _tiles = tiles,
    _tile_size = opts_.tile_size or 16,
  }, TileMap) --[[: unknown]]
  return tm --[[:! TileMap]]
end

--: (self: TileMap) -> number
function TileMap:width()
  return self._width
end

--: (self: TileMap) -> number
function TileMap:height()
  return self._height
end

--: (self: TileMap, x: number, y: number) -> boolean
function TileMap:in_bounds(x, y)
  return (x >= 0 and x < self._width and y >= 0 and y < self._height) and true or false
end

--- Get tile at (x, y), 0-indexed. Returns nil if out of bounds.
--: (self: TileMap, x: number, y: number) -> unknown | nil
function TileMap:get(x, y)
  if not self:in_bounds(x, y) then return nil end
  return self._tiles[y * self._width + x + 1]
end

--- Set tile at (x, y), 0-indexed. Returns nil, errmsg if out of bounds.
--: (self: TileMap, x: number, y: number, value: unknown) -> (boolean | nil, string | nil)
function TileMap:set(x, y, value)
  if not self:in_bounds(x, y) then
    return nil, "coordinates out of bounds"
  end
  self._tiles[y * self._width + x + 1] = value
  return true
end

--- Fill a rectangle with value. Clamps to map bounds.
--: (self: TileMap, x: number, y: number, w: number, h: number, value: unknown) -> nil
function TileMap:fill(x, y, w, h, value)
  local x1 = x < 0 and 0 or x
  local y1 = y < 0 and 0 or y
  local x2 = (x + w - 1) >= self._width and (self._width - 1) or (x + w - 1)
  local y2 = (y + h - 1) >= self._height and (self._height - 1) or (y + h - 1)
  local width = self._width
  local tiles = self._tiles
  for ry = y1, y2 do
    local base = ry * width
    for rx = x1, x2 do
      tiles[base + rx + 1] = value
    end
  end
end

--- Fill the outer border with value.
--: (self: TileMap, value: unknown) -> nil
function TileMap:fill_border(value)
  local w = self._width
  local h = self._height
  -- top and bottom rows
  self:fill(0, 0, w, 1, value)
  self:fill(0, h - 1, w, 1, value)
  -- left and right columns (excluding corners already filled)
  if h > 2 then
    self:fill(0, 1, 1, h - 2, value)
    self:fill(w - 1, 1, 1, h - 2, value)
  end
end

--- Copy a rectangular region to another position. Regions may overlap.
--: (self: TileMap, src_x: number, src_y: number, w: number, h: number, dst_x: number, dst_y: number) -> nil
function TileMap:copy_region(src_x, src_y, w, h, dst_x, dst_y)
  -- collect source tiles first (handles overlap)
  local buf = {}
  for ry = 0, h - 1 do
    for rx = 0, w - 1 do
      buf[ry * w + rx + 1] = self:get(src_x + rx, src_y + ry)
    end
  end
  for ry = 0, h - 1 do
    for rx = 0, w - 1 do
      local v = buf[ry * w + rx + 1]
      if v ~= nil then
        self:set(dst_x + rx, dst_y + ry, v)
      end
    end
  end
end

--- Flood fill starting at (x, y), replacing existing value with new value.
--: (self: TileMap, x: number, y: number, value: unknown) -> nil
function TileMap:flood_fill(x, y, value)
  if not self:in_bounds(x, y) then return end
  local old = self:get(x, y)
  if old == value then return end
  local queue = {} --: { [integer]: { [integer]: number } }
  local head = 1
  queue[1] = { x, y }
  self:set(x, y, value)
  while head <= #queue do
    local cell = queue[head]
    head = head + 1
    local cx = cell[1] --[[:! number]]
    local cy = cell[2] --[[:! number]]
    local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } --: { [integer]: Dir }
    for _, d in ipairs(dirs) do
      local d_ = d --[[:! Dir]]
      local nx, ny = cx + d_[1], cy + d_[2]
      if self:in_bounds(nx, ny) and self:get(nx, ny) == old then
        self:set(nx, ny, value)
        queue[#queue + 1] = { nx, ny }
      end
    end
  end
end

--- Find all tile positions with the given value.
-- Returns array of {x, y} (0-indexed).
--: (self: TileMap, value: unknown) -> { [integer]: { [integer]: number } }
function TileMap:find(value)
  local result = {} --: { [integer]: { [integer]: number } }
  local w = self._width
  local h = self._height
  local tiles = self._tiles
  for i = 1, w * h do
    if tiles[i] == value then
      local idx = i - 1
      result[#result + 1] = { idx % w --[[:! number]], math.floor(idx / w) }
    end
  end
  return result
end

--- Count tiles with given value.
--: (self: TileMap, value: unknown) -> integer
function TileMap:count(value)
  local n = 0
  local tiles = self._tiles
  for i = 1, self._width * self._height do
    if tiles[i] == value then n = n + 1 end
  end
  return n
end

--- Return 4-directional neighbors as array of {x, y, value}.
--: (self: TileMap, x: number, y: number) -> { [integer]: { [integer]: unknown } }
function TileMap:neighbors4(x, y)
  local result = {} --: { [integer]: { [integer]: unknown } }
  local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } --: { [integer]: Dir }
  for _, d in ipairs(dirs) do
    local d_ = d --[[:! Dir]]
    local nx, ny = x + d_[1], y + d_[2]
    if self:in_bounds(nx, ny) then
      result[#result + 1] = { nx, ny, self:get(nx, ny) }
    end
  end
  return result
end

--- Return 8-directional neighbors as array of {x, y, value}.
--: (self: TileMap, x: number, y: number) -> { [integer]: { [integer]: unknown } }
function TileMap:neighbors8(x, y)
  local result = {} --: { [integer]: { [integer]: unknown } }
  for dy = -1, 1 do
    for dx = -1, 1 do
      if not (dx == 0 and dy == 0) then
        local nx, ny = x + dx, y + dy
        if self:in_bounds(nx, ny) then
          result[#result + 1] = { nx, ny, self:get(nx, ny) }
        end
      end
    end
  end
  return result
end

-- ========================
-- A* PATHFINDING
-- ========================

local function key(x, y, w)
  return y * w + x
end

--- A* pathfinding on the tilemap.
-- opts.passable: function(tile) -> boolean (default: tile ~= 0)
-- opts.diagonal: boolean (default false)
-- opts.heuristic: "manhattan" | "euclidean" | "chebyshev" (default "manhattan")
-- Returns array of {x, y} from start to goal (inclusive), or nil, errmsg.
--: (self: TileMap, sx: number, sy: number, gx: number, gy: number, opts: { passable: ((unknown) -> boolean) | nil, diagonal: boolean | nil, heuristic: string | nil } | nil) -> ({ [integer]: { [integer]: number } } | nil, string | nil)
function TileMap:astar(sx, sy, gx, gy, opts)
  local opts_ = (opts or {}) --[[:! { passable: ((unknown) -> boolean) | nil, diagonal: boolean | nil, heuristic: string | nil }]]
  local w = self._width
  local passable = opts_.passable or function(t) return t ~= 0 end
  local diagonal = opts_.diagonal or false
  local hname = opts_.heuristic or "manhattan"

  --: (x: number, y: number) -> number
  local function heuristic(x, y)
    local dx = x - gx
    local dy = y - gy
    if dx < 0 then dx = -dx end
    if dy < 0 then dy = -dy end
    if hname == "euclidean" then
      return math.sqrt(dx * dx + dy * dy)
    elseif hname == "chebyshev" then
      return dx > dy and dx or dy
    else -- manhattan
      return dx + dy
    end
  end

  if not self:in_bounds(sx, sy) then return nil, "start out of bounds" end
  if not self:in_bounds(gx, gy) then return nil, "goal out of bounds" end
  if not passable(self:get(sx, sy)) then return nil, "start is not passable" end
  if not passable(self:get(gx, gy)) then return nil, "goal is not passable" end

  local start_k = key(sx, sy, w)
  local goal_k = key(gx, gy, w)

  local open = heap_new()
  local g = { [start_k] = 0.0 } --: { [integer]: number }
  local came_from = {} --: { [integer]: integer | nil }
  local closed = {} --: { [integer]: boolean }

  open:push(start_k, heuristic(sx, sy))

  local dirs4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } --: { [integer]: Dir }
  local dirs8 = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
  } --: { [integer]: Dir }
  local dirs = (diagonal and dirs8 or dirs4) --[[:! { [integer]: Dir }]]

  while not open:empty() do
    local cur_k = open:pop()
    local cur_k_ = cur_k --[[:! integer]]
    if closed[cur_k_] then goto continue end
    closed[cur_k_] = true

    if cur_k_ == goal_k then
      -- reconstruct path
      local path = {} --: { [integer]: { [integer]: number } }
      local k = cur_k_ --: integer | nil
      while k do
        local k_ = k --[[:! integer]]
        local px = k_ % w
        local py = math.floor(k_ / w)
        table.insert(path --[[: unknown]], 1, { px, py })
        k = came_from[k_]
      end
      return path
    end

    local cur_x = cur_k_ % w
    local cur_y = math.floor(cur_k_ / w)

    for _, d in ipairs(dirs) do
      local d_ = d --[[:! Dir]]
      local nx, ny = cur_x + d_[1], cur_y + d_[2]
      if self:in_bounds(nx, ny) and passable(self:get(nx, ny)) then
        local nk = key(nx, ny, w)
        if not closed[nk] then
          local move_cost = (d[1] ~= 0 and d[2] ~= 0) and 1.41421356 or 1
          local new_g = g[cur_k] + move_cost
          if g[nk] == nil or new_g < g[nk] then
            g[nk] = new_g
            came_from[nk] = cur_k_
            open:push(nk, new_g + heuristic(nx, ny))
          end
        end
      end
    end

    ::continue::
  end

  return nil, "no path found"
end

-- ========================
-- PROCEDURAL GENERATION
-- ========================

-- Simple LCG RNG
--: (seed: integer) -> Rng
local function make_rng(seed)
  if not seed then error("tilemap: seed is required") end
  local state = seed --: integer
  local rng = {
    --: (self: Rng) -> integer
    next = function(self)
      state = math.floor((state * 1664525 + 1013904223) % 4294967296)
      return state
    end,
    --: (self: Rng, lo: integer, hi: integer) -> integer
    range = function(self, lo, hi)
      return lo + (self:next() % (hi - lo + 1))
    end,
    --: (self: Rng) -> number
    float = function(self)
      return self:next() / 4294967295
    end,
  } --[[: unknown]]
  return rng --[[:! Rng]]
end

--- Generate a map with random rooms connected by corridors.
-- opts.num_rooms: number of rooms to attempt (default 5)
-- opts.min_size: minimum room dimension (default 3)
-- opts.max_size: maximum room dimension (default 8)
-- opts.seed: RNG seed (required)
-- Returns tilemap: 0=wall, 1=floor
--: (width: number, height: number, opts: { seed: integer, num_rooms: integer | nil, min_size: integer | nil, max_size: integer | nil }) -> TileMap
function M.random_rooms(width, height, opts)
  if not opts or not opts.seed then error("tilemap.random_rooms: opts.seed is required") end
  local num_rooms = opts.num_rooms or 5
  local min_size = opts.min_size or 3
  local max_size = opts.max_size or 8
  local rng = make_rng(opts.seed)

  local map_res = M.new(width, height, { default_tile = 0 } --[[: unknown]])
  local map = map_res --[[:! TileMap]]
  local rooms = {} --: { [integer]: RoomRect }

  for _ = 1, num_rooms do
    local rw = rng:range(min_size, max_size)
    local rh = rng:range(min_size, max_size)
    local rx = rng:range(1, math.floor(width - rw - 1))
    local ry = rng:range(1, math.floor(height - rh - 1))

    -- Check overlap with existing rooms (with 1-tile buffer)
    local overlap = false
    for _, r in ipairs(rooms) do
      if rx <= r.x + r.w and rx + rw >= r.x and
         ry <= r.y + r.h and ry + rh >= r.y then
        overlap = true
        break
      end
    end

    if not overlap then
      map:fill(rx, ry, rw, rh, 1)
      rooms[#rooms + 1] = { x = rx, y = ry, w = rw, h = rh,
        cx = rx + math.floor(rw / 2),
        cy = ry + math.floor(rh / 2) }
    end
  end

  -- Connect rooms with L-shaped corridors
  for i = 2, #rooms do
    local a = rooms[i - 1]
    local b = rooms[i]
    local ax, ay = a.cx, a.cy
    local bx, by = b.cx, b.cy

    -- horizontal then vertical
    local x1, x2 = ax < bx and ax or bx, ax < bx and bx or ax
    for x = x1, x2 do
      map:set(x, ay, 1)
    end
    local y1, y2 = ay < by and ay or by, ay < by and by or ay
    for y = y1, y2 do
      map:set(bx, y, 1)
    end
  end

  return map
end

--- Generate a map using cellular automata.
-- opts.fill_prob: initial fill probability (default 0.45)
-- opts.iterations: smoothing iterations (default 5)
-- opts.seed: RNG seed (required)
-- opts.birth_rule: neighbor counts that birth a live cell (default {3,4,5,6,7,8})
-- opts.survive_rule: neighbor counts that keep a live cell (default {2,3,4,5})
-- Returns tilemap: 0=dead, 1=alive
function M.cellular_automata(width, height, opts)
  if not opts or not opts.seed then error("tilemap.cellular_automata: opts.seed is required") end
  local fill_prob = opts.fill_prob or 0.45
  local iterations = opts.iterations or 5
  local rng = make_rng(opts.seed)

  -- Build birth/survive lookup tables
  local birth_set = {}
  local birth_rule = opts.birth_rule or { 3, 4, 5, 6, 7, 8 }
  for _, n in ipairs(birth_rule) do birth_set[n] = true end

  local survive_set = {}
  local survive_rule = opts.survive_rule or { 2, 3, 4, 5 }
  for _, n in ipairs(survive_rule) do survive_set[n] = true end

  -- Initial random fill
  local tiles = {}
  for i = 1, width * height do
    tiles[i] = rng:float() < fill_prob and 1 or 0
  end

  local function count_live_neighbors(t, x, y)
    local n = 0
    for dy = -1, 1 do
      for dx = -1, 1 do
        if not (dx == 0 and dy == 0) then
          local nx, ny = x + dx, y + dy
          if nx >= 0 and nx < width and ny >= 0 and ny < height then
            if t[ny * width + nx + 1] == 1 then n = n + 1 end
          else
            -- treat out-of-bounds as alive (wall)
            n = n + 1
          end
        end
      end
    end
    return n
  end

  -- Smoothing iterations
  for _ = 1, iterations do
    local next_tiles = {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local idx = y * width + x + 1
        local alive = tiles[idx] == 1
        local nb = count_live_neighbors(tiles, x, y)
        if alive then
          next_tiles[idx] = survive_set[nb] and 1 or 0
        else
          next_tiles[idx] = birth_set[nb] and 1 or 0
        end
      end
    end
    tiles = next_tiles
  end

  local map_res = M.new(width, height, { default_tile = 0 } --[[: unknown]])
  local map = map_res --[[:! TileMap]]
  map._tiles = tiles
  return map
end

-- ========================
-- SERIALIZATION
-- ========================

--- Serialize the tilemap to a compact string.
-- Format: "w:h:hex_data" where hex_data encodes each tile as 2 hex digits (tile values 0-255).
-- For simplicity, clamps tile values to [0, 255].
--: (self: TileMap) -> string
function TileMap:serialize()
  local parts = {}
  local tiles = self._tiles
  for i = 1, #tiles do
    local v = tiles[i] --[[:! number]]
    if v < 0 then v = 0 elseif v > 255 then v = 255 end
    parts[i] = string.format("%02x", v)
  end
  return self._width .. ":" .. self._height .. ":" .. table.concat(parts)
end

--- Deserialize a tilemap from a serialized string.
--: (str: string) -> (TileMap | nil, string | nil)
function M.deserialize(str)
  local w_s, h_s, hex = str:match("^(%d+):(%d+):(.+)$")
  if not w_s then return nil, "invalid serialized tilemap" end
  local w = tonumber(w_s) or 0
  local h = tonumber(h_s) or 0
  if w < 1 or h < 1 then return nil, "invalid dimensions" end
  local expected = w * h
  local hex_ = hex --[[:! string]]
  if #hex_ ~= expected * 2 then return nil, "data length mismatch" end
  local map_res = M.new(w, h)
  local map = map_res --[[:! TileMap]]
  local tiles = map._tiles
  for i = 1, expected do
    local byte = tonumber(hex_:sub(i * 2 - 1, i * 2), 16)
    if not byte then return nil, "invalid hex data" end
    tiles[i] = byte
  end
  return map
end

-- ========================
-- LAYER SUPPORT
-- ========================

local LayeredMap = {}
LayeredMap.__index = LayeredMap

--- Create a layered tilemap.
function M.layers(width, height, num_layers)
  if type(num_layers) ~= "number" or num_layers < 1 then
    return nil, "num_layers must be a positive number"
  end
  local layers = {}
  for i = 1, num_layers do
    layers[i] = M.new(width, height)
  end
  return setmetatable({
    _width = width,
    _height = height,
    _num_layers = num_layers,
    _layers = layers,
  }, LayeredMap)
end

function LayeredMap:get(x, y, layer)
  local l = self._layers[layer]
  if not l then return nil, "invalid layer" end
  return l:get(x, y)
end

function LayeredMap:set(x, y, layer, value)
  local l = self._layers[layer]
  if not l then return nil, "invalid layer" end
  return l:set(x, y, value)
end

--- Return the flat TileMap for a given layer (1-indexed).
function LayeredMap:get_layer(layer)
  return self._layers[layer]
end

return M
