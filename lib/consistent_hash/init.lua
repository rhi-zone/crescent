if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")

local M = {}
M._tier = "pure"

--: (s: string) -> integer
local function fnv1a(s)
  local h = math.floor(2166136261) --[[:! integer]]
  for i = 1, #s do
    h = bit.bxor(h, (string.byte(s, i) or 0) --[[:! integer]])
    h = bit.band(h * 16777619, 0xffffffff)
  end
  if h < 0 then h = (h + 4294967296) --[[:! integer]] end
  return h --[[:! integer]]
end

-- Binary search: find index of first virtual node with hash >= target
-- Returns index in [1, #ring+1]; if > #ring, wrap to 1
--: (ring: { [integer]: { [integer]: unknown } }, target: integer) -> integer
local function bisect(ring, target)
  local lo, hi = 1, #ring
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if ring[mid][1] < target then
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return lo
end

--:: Ring = { _replicas: integer, _vring: { [integer]: { [integer]: unknown } }, _node_set: { [string]: boolean | nil }, _node_count: integer, get_node: (self: Ring, key: string) -> string | nil, ... }

local Ring = {}
Ring.__index = Ring

function Ring:add_node(name)
  local self_ = self --[[:! Ring]]
  if self_._node_set[name] then return end
  self_._node_set[name] = true
  self_._node_count = self_._node_count + 1

  local replicas = self_._replicas
  local vring = self_._vring
  for i = 0, replicas - 1 do
    local vkey = name .. ":" .. i
    local h = fnv1a(vkey)
    vring[#vring + 1] = {h, name}
  end

  table.sort(vring, function(a, b) return a[1] < b[1] end)
end

function Ring:remove_node(name)
  local self_ = self --[[:! Ring]]
  if not self_._node_set[name] then return end
  self_._node_set[name] = nil --[[: unknown]]
  self_._node_count = self_._node_count - 1

  local vring = self_._vring
  local new_vring = {} --: { [integer]: { [integer]: unknown } }
  for i = 1, #vring do
    if vring[i][2] ~= name then
      new_vring[#new_vring + 1] = vring[i]
    end
  end
  self_._vring = new_vring
end

function Ring:get_node(key)
  local self_ = self --[[:! Ring]]
  local vring = self_._vring
  if #vring == 0 then return nil end
  local h = fnv1a(key)
  local idx = bisect(vring, h)
  if idx > #vring then idx = 1 end
  return vring[idx][2]
end

function Ring:get_nodes(key, n)
  local self_ = self --[[:! Ring]]
  local vring = self_._vring
  local result = {}
  local seen = {}
  if #vring == 0 or n <= 0 then return result end

  local h = fnv1a(key)
  local start = bisect(vring, h)
  local len = #vring

  for offset = 0, len - 1 do
    local idx = ((start - 1 + offset) % len) + 1
    local node = vring[idx][2]
    if not seen[node] then
      seen[node] = true
      result[#result + 1] = node
      if #result >= n then break end
    end
  end

  return result
end

function Ring:nodes()
  local self_ = self --[[:! Ring]]
  local result = {} --: { [integer]: string }
  for name in pairs(self_._node_set) do
    result[#result + 1] = name
  end
  table.sort(result --[[: unknown]])
  return result
end

function Ring:node_count()
  local self_ = self --[[:! Ring]]
  return self_._node_count
end

function Ring:distribution(keys)
  local self_ = self --[[:! Ring]]
  local dist = {} --: { [string]: integer }
  for name in pairs(self_._node_set) do
    dist[name] = 0
  end
  for i = 1, #keys do
    local node = self_:get_node(keys[i])
    if node then
      dist[node] = (dist[node] or 0) + 1
    end
  end
  return dist
end

function M.new(opts)
  opts = opts or {}
  local replicas = opts.replicas or 150
  local ring = (setmetatable({
    _replicas = replicas,
    _vring = {},
    _node_set = {},
    _node_count = 0,
  }, Ring) --[[: unknown]]) --[[:! Ring]]
  return ring
end

return M
