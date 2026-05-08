if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- 2D spatial hash grid for efficient proximity queries.
-- Cell size determines granularity; set to the size of your largest object
-- for best performance. Each cell maps to a set of object IDs.
-- Points are stored with w=nil, h=nil. Rects store w and h.

local M = {}
M._tier = "pure"

local floor = math.floor
local sqrt  = math.sqrt

-- Internal helper: compute the cell key string from integer cell coords.
local function cell_key(cx, cy)
  return cx .. "," .. cy
end

-- Internal helper: add id to a cell, creating the cell set if needed.
local function cell_add(cells, key, id)
  local c = cells[key]
  if not c then
    c = {}
    cells[key] = c
  end
  c[id] = true
end

-- Internal helper: remove id from a cell; delete empty cells.
local function cell_remove(cells, key, id)
  local c = cells[key]
  if c then
    c[id] = nil
    -- remove empty cell to keep stats accurate
    local empty = true
    for _ in pairs(c) do empty = false; break end
    if empty then cells[key] = nil end
  end
end

--:: SpatialObj = { x: number, y: number, w: number | nil, h: number | nil, cells: { [integer]: string } }
--:: SpatialGrid = { _cs: number, _cells: { [string]: { [string]: boolean } }, _objects: { [string]: SpatialObj }, _count: integer }

-- Internal helper: insert an object into all cells it spans.
-- obj must have: x, y, w (or nil), h (or nil), cells (empty table)
--: ({ [string]: { [string]: boolean } }, number, SpatialObj, unknown) -> nil
local function obj_insert_cells(grid_cells, cs, obj, id)
  local x, y, w, h = obj.x, obj.y, obj.w, obj.h
  local cx0 = floor(x / cs)
  local cy0 = floor(y / cs)
  local cx1 = w and floor((x + w) / cs) or cx0
  local cy1 = h and floor((y + h) / cs) or cy0
  for cx = cx0, cx1 do
    for cy = cy0, cy1 do
      local key = cell_key(cx, cy)
      cell_add(grid_cells, key, id)
      obj.cells[#obj.cells + 1] = key
    end
  end
end

-- Internal helper: remove an object from all its registered cells.
local function obj_remove_cells(grid_cells, obj, id)
  for _, key in ipairs(obj.cells) do
    cell_remove(grid_cells, key, id)
  end
end

-- Create a new spatial hash grid.
-- cell_size: world units per cell (default 64).
function M.new(cell_size)
  local cs = cell_size or 64
  local self = {
    _cs      = cs,
    _cells   = {} --[[:! { [string]: { [string]: boolean } }]],
    _objects = {} --[[:! { [string]: SpatialObj }]],
    _count   = 0,
  } --[[:! SpatialGrid]]

  -- Insert a point object.
  --: (SpatialGrid, unknown, number, number) -> nil
  function self:insert(id, x, y)
    if self._objects[id] then self:remove(id) end
    local obj = { x = x, y = y, w = nil, h = nil, cells = {} }
    self._objects[id] = obj
    obj_insert_cells(self._cells, self._cs, obj, id)
    self._count = self._count + 1
  end

  -- Insert a rect object covering the AABB [x, x+w] x [y, y+h].
  --: (SpatialGrid, unknown, number, number, number, number) -> nil
  function self:insert_rect(id, x, y, w, h)
    if self._objects[id] then self:remove(id) end
    local obj = { x = x, y = y, w = w, h = h, cells = {} }
    self._objects[id] = obj
    obj_insert_cells(self._cells, self._cs, obj, id)
    self._count = self._count + 1
  end

  -- Remove an object by id. Returns true if found, false otherwise.
  --: (SpatialGrid, unknown) -> boolean
  function self:remove(id)
    local obj = self._objects[id]
    if not obj then return false end
    obj_remove_cells(self._cells, obj, id)
    self._objects[id] = nil
    self._count = self._count - 1
    return true
  end

  -- Internal: collect all unique IDs from cells in a cell range.
  -- Returns a fresh array.
  local function collect_range(cells, cx0, cy0, cx1, cy1)
    local seen = {}
    local result = {}
    for cx = cx0, cx1 do
      for cy = cy0, cy1 do
        local key = cell_key(cx, cy)
        local c = cells[key]
        if c then
          for id in pairs(c) do
            if not seen[id] then
              seen[id] = true
              result[#result + 1] = id
            end
          end
        end
      end
    end
    return result
  end

  -- Query: return all objects whose point/rect overlaps a point (px, py).
  -- For point objects: exact match (the point is in the same cell).
  -- For rect objects: point must be inside [x, x+w] x [y, y+h].
  function self:query_point(px, py)
    local cs = self._cs
    local cx = floor(px / cs)
    local cy = floor(py / cs)
    local key = cell_key(cx, cy)
    local c = self._cells[key]
    if not c then return {} end
    local result = {}
    local objects = self._objects
    for id in pairs(c) do
      local obj = objects[id]
      if obj then
        if obj.w then
          -- rect: check exact containment
          if px >= obj.x and px <= obj.x + obj.w
             and py >= obj.y and py <= obj.y + obj.h then
            result[#result + 1] = id
          end
        else
          -- point: same cell means match (point is its own location)
          result[#result + 1] = id
        end
      end
    end
    return result
  end

  -- Query: return all objects whose point/rect overlaps the given AABB.
  -- Broad-phase only (candidates sharing a cell). No exact narrow phase.
  function self:query_rect(x, y, w, h)
    local cs = self._cs
    local cx0 = floor(x / cs)
    local cy0 = floor(y / cs)
    local cx1 = floor((x + w) / cs)
    local cy1 = floor((y + h) / cs)
    return collect_range(self._cells, cx0, cy0, cx1, cy1)
  end

  -- Query: return all objects whose point/rect overlaps a circle.
  -- Scans bounding-box cells, then does exact distance check for point objects.
  -- Rect objects that share a cell are returned as candidates (broad phase).
  function self:query_radius(cx_world, cy_world, radius)
    local cs = self._cs
    local cx0 = floor((cx_world - radius) / cs)
    local cy0 = floor((cy_world - radius) / cs)
    local cx1 = floor((cx_world + radius) / cs)
    local cy1 = floor((cy_world + radius) / cs)
    local candidates = collect_range(self._cells, cx0, cy0, cx1, cy1)
    local result = {}
    local objects = self._objects
    local r2 = radius * radius
    for _, id in ipairs(candidates) do
      local obj = objects[id]
      if obj then
        if obj.w then
          -- rect: include as candidate (broad phase)
          result[#result + 1] = id
        else
          -- point: exact distance check
          local dx = obj.x - cx_world
          local dy = obj.y - cy_world
          if dx * dx + dy * dy <= r2 then
            result[#result + 1] = id
          end
        end
      end
    end
    return result
  end

  -- Nearest neighbors (point objects only), sorted by distance ascending.
  -- Returns up to n ids.
  --: (SpatialGrid, number, number, integer) -> { [integer]: unknown }
  function self:nearest(x, y, n)
    -- Expand search rings until we have n candidates or covered all objects.
    local cs = self._cs
    local objects = self._objects
    -- Simple approach: collect all point objects, sort by distance.
    -- For large grids, use expanding ring search.
    local candidates = {}
    for id, obj in pairs(objects) do
      if not obj.w then  -- point only
        local dx = obj.x - x
        local dy = obj.y - y
        candidates[#candidates + 1] = { id = id, d2 = dx * dx + dy * dy }
      end
    end
    table.sort(candidates, function(a, b) return a.d2 < b.d2 end)
    local result = {}
    local limit = n < #candidates and n or #candidates
    for i = 1, limit do
      result[i] = candidates[i].id
    end
    return result
  end

  -- Move a point object to a new position.
  --: (SpatialGrid, unknown, number, number) -> nil
  function self:move(id, new_x, new_y)
    local obj = self._objects[id]
    if not obj then return end
    obj_remove_cells(self._cells, obj, id)
    obj.cells = {}
    obj.x = new_x
    obj.y = new_y
    obj_insert_cells(self._cells, self._cs, obj, id)
  end

  -- Move a rect object to a new position/size.
  --: (SpatialGrid, unknown, number, number, number, number) -> nil
  function self:move_rect(id, new_x, new_y, new_w, new_h)
    local obj = self._objects[id]
    if not obj then return end
    obj_remove_cells(self._cells, obj, id)
    obj.cells = {}
    obj.x = new_x
    obj.y = new_y
    obj.w = new_w
    obj.h = new_h
    obj_insert_cells(self._cells, self._cs, obj, id)
  end

  -- Get the position of an object.
  -- Returns x, y for points; x, y, w, h for rects.
  function self:get(id)
    local obj = self._objects[id]
    if not obj then return nil end
    if obj.w then
      return obj.x, obj.y, obj.w, obj.h
    else
      return obj.x, obj.y
    end
  end

  -- Return total number of objects in the grid.
  function self:count()
    return self._count
  end

  -- Iterate over all objects. fn(id, x, y) for points; fn(id, x, y, w, h) for rects.
  function self:each(fn)
    for id, obj in pairs(self._objects) do
      if obj.w then
        fn(id, obj.x, obj.y, obj.w, obj.h)
      else
        fn(id, obj.x, obj.y)
      end
    end
  end

  -- Remove all objects and cells.
  function self:clear()
    self._cells   = {}
    self._objects = {}
    self._count   = 0
  end

  -- Broad-phase collision pairs. Calls fn(id1, id2) for each pair of objects
  -- that share at least one cell. Each pair reported at most once.
  -- Uses internal index ordering to avoid duplicates.
  function self:pairs(fn)
    local reported = {}
    for _, cell in pairs(self._cells) do
      -- collect ids in this cell
      local ids = {}
      for id in pairs(cell) do
        ids[#ids + 1] = id
      end
      -- report each pair once (use tostring comparison for stable ordering)
      for i = 1, #ids do
        for j = i + 1, #ids do
          local a, b = ids[i], ids[j]
          -- canonical order: smaller tostring first
          local ka, kb = tostring(a), tostring(b)
          local key
          if ka <= kb then
            key = ka .. "|" .. kb
          else
            key = kb .. "|" .. ka
            a, b = b, a
          end
          if not reported[key] then
            reported[key] = true
            fn(a, b)
          end
        end
      end
    end
  end

  -- Return stats table: { cells=N, objects=M, avg_per_cell=F }
  function self:stats()
    local cell_count = 0
    local total_occupants = 0
    for _, c in pairs(self._cells) do
      cell_count = cell_count + 1
      for _ in pairs(c) do
        total_occupants = total_occupants + 1
      end
    end
    local avg = cell_count > 0 and (total_occupants / cell_count) or 0
    return {
      cells         = cell_count,
      objects       = self._count,
      avg_per_cell  = avg,
    }
  end

  return self
end

return M
