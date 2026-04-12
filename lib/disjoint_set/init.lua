if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- Basic DSU: path compression + union by rank
-- Elements labeled 0..n-1 for fixed-size, or auto-extended for dynamic.

local BasicDSU = {}
BasicDSU.__index = BasicDSU

function M.new(n)
  local self = setmetatable({}, BasicDSU)
  self._parent = {}
  self._rank = {}
  self._size = {}
  self._count = 0
  if n then
    for i = 0, n - 1 do
      self._parent[i] = i
      self._rank[i] = 0
      self._size[i] = 1
    end
    self._count = n
  end
  return self
end

-- Ensure element x exists (for dynamic mode)
function BasicDSU:_ensure(x)
  if self._parent[x] == nil then
    self._parent[x] = x
    self._rank[x] = 0
    self._size[x] = 1
    self._count = self._count + 1
  end
end

function BasicDSU:find(x)
  self:_ensure(x)
  -- Path compression: iterative two-pass
  local root = x
  while self._parent[root] ~= root do
    root = self._parent[root]
  end
  -- Compress path
  local cur = x
  while cur ~= root do
    local next = self._parent[cur]
    self._parent[cur] = root
    cur = next
  end
  return root
end

function BasicDSU:union(x, y)
  local rx = self:find(x)
  local ry = self:find(y)
  if rx == ry then return false end
  -- Union by rank
  local rankx = self._rank[rx]
  local ranky = self._rank[ry]
  if rankx < ranky then
    rx, ry = ry, rx
  end
  -- ry becomes child of rx
  self._parent[ry] = rx
  self._size[rx] = self._size[rx] + self._size[ry]
  if rankx == ranky then
    self._rank[rx] = self._rank[rx] + 1
  end
  self._count = self._count - 1
  return true
end

function BasicDSU:connected(x, y)
  return self:find(x) == self:find(y)
end

function BasicDSU:component_size(x)
  return self._size[self:find(x)]
end

function BasicDSU:count()
  return self._count
end

function BasicDSU:components()
  -- Group elements by root
  local groups = {}
  local root_index = {}
  for k, _ in pairs(self._parent) do
    local r = self:find(k)
    if root_index[r] == nil then
      local g = {}
      groups[#groups + 1] = g
      root_index[r] = #groups
    end
    local g = groups[root_index[r]]
    g[#g + 1] = k
  end
  return groups
end

-- Named DSU: string-keyed, backed by a BasicDSU
local NamedDSU = {}
NamedDSU.__index = NamedDSU

function M.named()
  local self = setmetatable({}, NamedDSU)
  self._inner = M.new()
  self._name_to_id = {}
  self._id_to_name = {}
  self._next_id = 0
  return self
end

function NamedDSU:_id(name)
  if self._name_to_id[name] == nil then
    local id = self._next_id
    self._next_id = id + 1
    self._name_to_id[name] = id
    self._id_to_name[id] = name
    self._inner:_ensure(id)
  end
  return self._name_to_id[name]
end

function NamedDSU:find(name)
  local id = self:_id(name)
  local root_id = self._inner:find(id)
  return self._id_to_name[root_id]
end

function NamedDSU:union(x, y)
  local ix = self:_id(x)
  local iy = self:_id(y)
  return self._inner:union(ix, iy)
end

function NamedDSU:connected(x, y)
  local ix = self:_id(x)
  local iy = self:_id(y)
  return self._inner:connected(ix, iy)
end

function NamedDSU:component(name)
  local target_root = self._inner:find(self:_id(name))
  local result = {}
  for n, id in pairs(self._name_to_id) do
    if self._inner:find(id) == target_root then
      result[#result + 1] = n
    end
  end
  return result
end

function NamedDSU:components()
  -- Returns table of root_name -> [member, ...]
  local groups = {}
  for name, id in pairs(self._name_to_id) do
    local root_id = self._inner:find(id)
    local root_name = self._id_to_name[root_id]
    if groups[root_name] == nil then
      groups[root_name] = {}
    end
    local g = groups[root_name]
    g[#g + 1] = name
  end
  return groups
end

-- Persistent (rollback) DSU: union by rank, NO path compression
-- Uses an explicit undo stack.
local PersistentDSU = {}
PersistentDSU.__index = PersistentDSU

function M.persistent(n)
  local self = setmetatable({}, PersistentDSU)
  self._parent = {}
  self._rank = {}
  self._size = {}
  self._count = n or 0
  self._undo = {}  -- stack of {node, field, old_value}
  if n then
    for i = 0, n - 1 do
      self._parent[i] = i
      self._rank[i] = 0
      self._size[i] = 1
    end
  end
  return self
end

function PersistentDSU:_find_root(x)
  -- No path compression — just walk up
  while self._parent[x] ~= x do
    x = self._parent[x]
  end
  return x
end

function PersistentDSU:find(x)
  return self:_find_root(x)
end

function PersistentDSU:union(x, y)
  local rx = self:_find_root(x)
  local ry = self:_find_root(y)
  if rx == ry then return false end

  local rankx = self._rank[rx]
  local ranky = self._rank[ry]
  if rankx < ranky then
    rx, ry = ry, rx
  end

  -- Record undo entries before mutating
  local undo = self._undo
  undo[#undo + 1] = { "parent", ry, self._parent[ry] }
  undo[#undo + 1] = { "size", rx, self._size[rx] }
  undo[#undo + 1] = { "count", nil, self._count }

  self._parent[ry] = rx
  self._size[rx] = self._size[rx] + self._size[ry]
  self._count = self._count - 1

  if rankx == ranky then
    undo[#undo + 1] = { "rank", rx, self._rank[rx] }
    self._rank[rx] = self._rank[rx] + 1
  end

  return true
end

function PersistentDSU:connected(x, y)
  return self:_find_root(x) == self:_find_root(y)
end

function PersistentDSU:component_size(x)
  return self._size[self:_find_root(x)]
end

function PersistentDSU:count()
  return self._count
end

function PersistentDSU:save()
  return #self._undo
end

function PersistentDSU:restore(depth)
  local undo = self._undo
  while #undo > depth do
    local entry = undo[#undo]
    undo[#undo] = nil
    local field = entry[1]
    local node = entry[2]
    local old_val = entry[3]
    if field == "parent" then
      self._parent[node] = old_val
    elseif field == "rank" then
      self._rank[node] = old_val
    elseif field == "size" then
      self._size[node] = old_val
    elseif field == "count" then
      self._count = old_val
    end
  end
end

-- Weighted/bipartite DSU
-- weight[i] = parity of i relative to its parent (XOR accumulates to root)
local WeightedDSU = {}
WeightedDSU.__index = WeightedDSU

function M.weighted(n)
  local self = setmetatable({}, WeightedDSU)
  self._parent = {}
  self._rank = {}
  self._size = {}
  self._weight = {}  -- parity relative to parent
  self._bipartite = true
  self._count = n or 0
  if n then
    for i = 0, n - 1 do
      self._parent[i] = i
      self._rank[i] = 0
      self._size[i] = 1
      self._weight[i] = 0
    end
  end
  return self
end

-- Returns root, accumulated parity from x to root
function WeightedDSU:_find(x)
  if self._parent[x] == x then
    return x, 0
  end
  local root, parent_parity = self:_find(self._parent[x])
  -- Path compression: update weight to be relative to root directly
  local new_weight = (self._weight[x] + parent_parity) % 2
  self._parent[x] = root
  self._weight[x] = new_weight
  return root, new_weight
end

function WeightedDSU:find(x)
  local root, _ = self:_find(x)
  return root
end

-- merge(x, y, w): require that diff(x, y) == w (0 or 1)
-- returns true if they were in different components, false if same component
function WeightedDSU:merge(x, y, w)
  w = w or 0
  local rx, wx = self:_find(x)
  local ry, wy = self:_find(y)
  if rx == ry then
    -- Check if existing parity matches
    if (wx + wy) % 2 ~= w % 2 then
      self._bipartite = false
    end
    return false
  end
  -- Union by rank; attach ry under rx
  local rankx = self._rank[rx]
  local ranky = self._rank[ry]
  -- We need: weight_rx_of_x XOR weight_ry_of_y XOR edge_w = 0
  -- i.e., new weight of ry relative to rx = wx XOR w XOR wy
  local new_ry_weight = (wx + w + wy) % 2
  if rankx < ranky then
    -- Swap: ry becomes new root, rx becomes child of ry
    -- weight of rx relative to ry = new_ry_weight (symmetric)
    local tmp_r = rx; rx = ry; ry = tmp_r
    local tmp_w = wx; wx = wy; wy = tmp_w
    -- Recompute: new_ry_weight was (old_wx + w + old_wy) % 2
    -- Now ry is old rx, and we need weight of (old rx) under (old ry)
    -- same value: new_ry_weight stays the same
  end
  -- ry under rx
  self._parent[ry] = rx
  self._weight[ry] = new_ry_weight
  self._size[rx] = self._size[rx] + self._size[ry]
  if rankx == ranky then
    self._rank[rx] = self._rank[rx] + 1
  end
  self._count = self._count - 1
  return true
end

-- diff(x, y): parity difference between x and y; nil if different components
function WeightedDSU:diff(x, y)
  local rx, wx = self:_find(x)
  local ry, wy = self:_find(y)
  if rx ~= ry then return nil end
  return (wx + wy) % 2
end

function WeightedDSU:is_bipartite()
  return self._bipartite
end

function WeightedDSU:connected(x, y)
  return self:find(x) == self:find(y)
end

function WeightedDSU:count()
  return self._count
end

return M
