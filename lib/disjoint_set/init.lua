if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- Basic DSU: path compression + union by rank
-- Elements labeled 0..n-1 for fixed-size, or auto-extended for dynamic.

--:: BasicDSU = { _parent: { [integer]: integer }, _rank: { [integer]: integer }, _size: { [integer]: integer }, _count: integer, _ensure: (BasicDSU, integer) -> (), find: (BasicDSU, integer) -> integer, union: (BasicDSU, integer, integer) -> boolean, connected: (BasicDSU, integer, integer) -> boolean, component_size: (BasicDSU, integer) -> integer, count: (BasicDSU) -> integer, components: (BasicDSU) -> { [integer]: { [integer]: integer } } }
--:: NamedDSU = { _inner: BasicDSU, _name_to_id: { [string]: integer }, _id_to_name: { [integer]: string }, _next_id: integer, _id: (NamedDSU, string) -> integer, find: (NamedDSU, string) -> string, union: (NamedDSU, string, string) -> boolean, connected: (NamedDSU, string, string) -> boolean, component: (NamedDSU, string) -> { [integer]: string }, components: (NamedDSU) -> { [string]: { [integer]: string } } }
--:: PersistentDSU = { _parent: { [integer]: integer }, _rank: { [integer]: integer }, _size: { [integer]: integer }, _count: integer, _undo: { [integer]: { [integer]: any } }, _find_root: (PersistentDSU, integer) -> integer, find: (PersistentDSU, integer) -> integer, union: (PersistentDSU, integer, integer) -> boolean, connected: (PersistentDSU, integer, integer) -> boolean, component_size: (PersistentDSU, integer) -> integer, count: (PersistentDSU) -> integer, save: (PersistentDSU) -> integer, restore: (PersistentDSU, integer) -> () }
--:: WeightedDSU = { _parent: { [integer]: integer }, _rank: { [integer]: integer }, _size: { [integer]: integer }, _weight: { [integer]: integer }, _bipartite: boolean, _count: integer, _find: (WeightedDSU, integer) -> (integer, integer), find: (WeightedDSU, integer) -> integer, merge: (WeightedDSU, integer, integer, integer) -> boolean, diff: (WeightedDSU, integer, integer) -> (integer | nil), is_bipartite: (WeightedDSU) -> boolean, connected: (WeightedDSU, integer, integer) -> boolean, count: (WeightedDSU) -> integer }

local BasicDSU = {}
BasicDSU.__index = BasicDSU

--: ((integer | nil)) -> BasicDSU
function M.new(n)
  local self = setmetatable({
    _parent = {},
    _rank = {},
    _size = {},
    _count = 0,
  }, BasicDSU) --[[: unknown]]
  local self_ = self --[[:! BasicDSU]]
  if n then
    for i = 0, n - 1 do
      self_._parent[i] = i
      self_._rank[i] = 0
      self_._size[i] = 1
    end
    self_._count = n
  end
  return self_
end

-- Ensure element x exists (for dynamic mode)
--: (BasicDSU, integer) -> ()
function BasicDSU:_ensure(x)
  if self._parent[x] == nil then
    self._parent[x] = x
    self._rank[x] = 0
    self._size[x] = 1
    self._count = self._count + 1
  end
end

--: (BasicDSU, integer) -> integer
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

--: (BasicDSU, integer, integer) -> boolean
function BasicDSU:union(x, y)
  local rx = self:find(x)
  local ry = self:find(y)
  if rx == ry then return false end
  -- Union by rank
  local rankx = self._rank[rx]
  local ranky = self._rank[ry]
  if rankx < ranky then
    rx, ry = ry, rx
    rankx, ranky = ranky, rankx
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

--: (BasicDSU, integer, integer) -> boolean
function BasicDSU:connected(x, y)
  return self:find(x) == self:find(y)
end

--: (BasicDSU, integer) -> integer
function BasicDSU:component_size(x)
  return self._size[self:find(x)]
end

--: (BasicDSU) -> integer
function BasicDSU:count()
  return self._count
end

--: (BasicDSU) -> { [integer]: { [integer]: integer } }
function BasicDSU:components()
  -- Group elements by root
  local groups = {} --: { [integer]: { [integer]: integer } }
  local root_index = {} --: { [integer]: integer }
  for k, _ in pairs(self._parent) do
    local r = self:find(k)
    if root_index[r] == nil then
      local g = {} --: { [integer]: integer }
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
  local self = setmetatable({
    _inner = M.new(),
    _name_to_id = {},
    _id_to_name = {},
    _next_id = 0,
  }, NamedDSU) --[[: unknown]]
  return self --[[:! NamedDSU]]
end

--: (NamedDSU, string) -> integer
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

--: (NamedDSU, string) -> string
function NamedDSU:find(name)
  local id = self:_id(name)
  local root_id = self._inner:find(id)
  return self._id_to_name[root_id]
end

--: (NamedDSU, string, string) -> boolean
function NamedDSU:union(x, y)
  local ix = self:_id(x)
  local iy = self:_id(y)
  return self._inner:union(ix, iy)
end

--: (NamedDSU, string, string) -> boolean
function NamedDSU:connected(x, y)
  local ix = self:_id(x)
  local iy = self:_id(y)
  return self._inner:connected(ix, iy)
end

--: (NamedDSU, string) -> { [integer]: string }
function NamedDSU:component(name)
  local target_root = self._inner:find(self:_id(name))
  local result = {} --: { [integer]: string }
  for n, id in pairs(self._name_to_id) do
    if self._inner:find(id) == target_root then
      result[#result + 1] = n
    end
  end
  return result
end

--: (NamedDSU) -> { [string]: { [integer]: string } }
function NamedDSU:components()
  -- Returns table of root_name -> [member, ...]
  local groups = {} --: { [string]: { [integer]: string } }
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
  local self = setmetatable({
    _parent = {},
    _rank = {},
    _size = {},
    _count = n or 0,
    _undo = {},
  }, PersistentDSU) --[[: unknown]]
  local self_ = self --[[:! PersistentDSU]]
  if n then
    for i = 0, n - 1 do
      self_._parent[i] = i
      self_._rank[i] = 0
      self_._size[i] = 1
    end
  end
  return self_
end

--: (PersistentDSU, integer) -> integer
function PersistentDSU:_find_root(x)
  -- No path compression — just walk up
  while self._parent[x] ~= x do
    x = self._parent[x]
  end
  return x
end

--: (PersistentDSU, integer) -> integer
function PersistentDSU:find(x)
  return self:_find_root(x)
end

--: (PersistentDSU, integer, integer) -> boolean
function PersistentDSU:union(x, y)
  local rx = self:_find_root(x)
  local ry = self:_find_root(y)
  if rx == ry then return false end

  local rankx = self._rank[rx]
  local ranky = self._rank[ry]
  if rankx < ranky then
    rx, ry = ry, rx
    rankx, ranky = ranky, rankx
  end

  -- Record undo entries before mutating
  local undo = self._undo
  undo[#undo + 1] = { "parent", ry, self._parent[ry] } --[[: unknown]]
  undo[#undo + 1] = { "size",   rx, self._size[rx]   } --[[: unknown]]
  undo[#undo + 1] = { "count",  0,  self._count       } --[[: unknown]]

  self._parent[ry] = rx
  self._size[rx] = self._size[rx] + self._size[ry]
  self._count = self._count - 1

  if rankx == ranky then
    undo[#undo + 1] = { "rank", rx, self._rank[rx] } --[[: unknown]]
    self._rank[rx] = self._rank[rx] + 1
  end

  return true
end

--: (PersistentDSU, integer, integer) -> boolean
function PersistentDSU:connected(x, y)
  return self:_find_root(x) == self:_find_root(y)
end

--: (PersistentDSU, integer) -> integer
function PersistentDSU:component_size(x)
  return self._size[self:_find_root(x)]
end

--: (PersistentDSU) -> integer
function PersistentDSU:count()
  return self._count
end

--: (PersistentDSU) -> integer
function PersistentDSU:save()
  return #self._undo
end

--: (PersistentDSU, integer) -> ()
function PersistentDSU:restore(depth)
  local undo = self._undo
  while #undo > depth do
    local entry = undo[#undo] --[[: unknown]]
    undo[#undo] = nil
    local field = entry[1] --[[:! string]]
    local node  = entry[2] --[[:! integer]]
    local old_val = entry[3] --[[:! integer]]
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
  local self = setmetatable({
    _parent    = {},
    _rank      = {},
    _size      = {},
    _weight    = {},
    _bipartite = true,
    _count     = n or 0,
  }, WeightedDSU) --[[: unknown]]
  local self_ = self --[[:! WeightedDSU]]
  if n then
    for i = 0, n - 1 do
      self_._parent[i] = i
      self_._rank[i] = 0
      self_._size[i] = 1
      self_._weight[i] = 0
    end
  end
  return self_
end

-- Returns root, accumulated parity from x to root
--: (WeightedDSU, integer) -> (integer, integer)
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

--: (WeightedDSU, integer) -> integer
function WeightedDSU:find(x)
  local root, _ = self:_find(x)
  return root
end

-- merge(x, y, w): require that diff(x, y) == w (0 or 1)
-- returns true if they were in different components, false if same component
--: (WeightedDSU, integer, integer, integer) -> boolean
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
    rankx, ranky = ranky, rankx
    -- Recompute: new_ry_weight was (old_wx + w + old_wy) % 2
    -- Now ry is old rx, and we need weight of (old rx) under (old ry)
    -- same value: new_ry_weight stays the same
    local _ = tmp_r; _ = ranky
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
--: (WeightedDSU, integer, integer) -> (integer | nil)
function WeightedDSU:diff(x, y)
  local rx, wx = self:_find(x)
  local ry, wy = self:_find(y)
  if rx ~= ry then return nil end
  return (wx + wy) % 2
end

--: (WeightedDSU) -> boolean
function WeightedDSU:is_bipartite()
  return self._bipartite
end

--: (WeightedDSU, integer, integer) -> boolean
function WeightedDSU:connected(x, y)
  return self:find(x) == self:find(y)
end

--: (WeightedDSU) -> integer
function WeightedDSU:count()
  return self._count
end

return M
