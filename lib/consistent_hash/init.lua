if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")

local M = {}
M._tier = "pure"

local function fnv1a(s)
  local h = 2166136261
  for i = 1, #s do
    h = bit.bxor(h, string.byte(s, i))
    h = bit.band(h * 16777619, 0xffffffff)
  end
  if h < 0 then h = h + 4294967296 end
  return h
end

-- Binary search: find index of first virtual node with hash >= target
-- Returns index in [1, #ring+1]; if > #ring, wrap to 1
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

local Ring = {}
Ring.__index = Ring

function Ring:add_node(name)
  if self._node_set[name] then return end
  self._node_set[name] = true
  self._node_count = self._node_count + 1

  local replicas = self._replicas
  local vring = self._vring
  for i = 0, replicas - 1 do
    local vkey = name .. ":" .. i
    local h = fnv1a(vkey)
    vring[#vring + 1] = {h, name}
  end

  table.sort(vring, function(a, b) return a[1] < b[1] end)
end

function Ring:remove_node(name)
  if not self._node_set[name] then return end
  self._node_set[name] = nil
  self._node_count = self._node_count - 1

  local vring = self._vring
  local new_vring = {}
  for i = 1, #vring do
    if vring[i][2] ~= name then
      new_vring[#new_vring + 1] = vring[i]
    end
  end
  self._vring = new_vring
end

function Ring:get_node(key)
  local vring = self._vring
  if #vring == 0 then return nil end
  local h = fnv1a(key)
  local idx = bisect(vring, h)
  if idx > #vring then idx = 1 end
  return vring[idx][2]
end

function Ring:get_nodes(key, n)
  local vring = self._vring
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
  local result = {}
  for name in pairs(self._node_set) do
    result[#result + 1] = name
  end
  table.sort(result)
  return result
end

function Ring:node_count()
  return self._node_count
end

function Ring:distribution(keys)
  local dist = {}
  for name in pairs(self._node_set) do
    dist[name] = 0
  end
  for i = 1, #keys do
    local node = self:get_node(keys[i])
    if node then
      dist[node] = (dist[node] or 0) + 1
    end
  end
  return dist
end

function M.new(opts)
  opts = opts or {}
  local replicas = opts.replicas or 150
  local ring = setmetatable({
    _replicas = replicas,
    _vring = {},
    _node_set = {},
    _node_count = 0,
  }, Ring)
  return ring
end

return M
