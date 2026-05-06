if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

--:: GCounter = { _id: string, _counts: { [string]: number }, increment: (GCounter, number | nil) -> nil, value: (GCounter) -> number, merge: (GCounter, GCounter) -> nil, clone: (GCounter) -> GCounter, eq: (GCounter, GCounter) -> boolean }
--:: PNCounter = { _id: string, _pos: GCounter, _neg: GCounter }
--:: LWWRegister = { _id: string, _value: unknown, _ts: number }
--:: TPSet = { _add: { [unknown]: boolean }, _rem: { [unknown]: boolean } }
--:: ORSet = { _id: string, _entries: { [unknown]: unknown }, _seq: integer }
--:: LWWMap = { _id: string, _entries: { [unknown]: unknown } }
--:: LWWEntry = { value: unknown, ts: number, deleted: boolean }

-- ─── helpers ────────────────────────────────────────────────────────────────

--: (unknown, unknown) -> boolean
local function tables_eq(a, b)
  for k, v in pairs(a) do
    if b[k] ~= v then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- ─── G-Counter ───────────────────────────────────────────────────────────────
-- Grow-only counter: each replica tracks its own count; merge takes per-key max.

local GCounter = {}
GCounter.__index = GCounter

--: (string) -> GCounter
function M.gcounter(replica_id)
  local g = setmetatable({ _id = replica_id, _counts = {} }, GCounter)
  return g --[[: any]]
end

--: ((number | nil)) -> nil
function GCounter:increment(n)
  local id = self._id
  self._counts[id] = (self._counts[id] or 0) + (n or 1)
end

--: () -> number
function GCounter:value()
  local sum = 0
  for _, v in pairs(self._counts) do
    sum = sum + v
  end
  return sum
end

--: (GCounter) -> nil
function GCounter:merge(other)
  for k, v in pairs(other._counts) do
    if (self._counts[k] or 0) < v then
      self._counts[k] = v
    end
  end
end

--: () -> GCounter
function GCounter:clone()
  local c = M.gcounter(self._id)
  for k, v in pairs(self._counts) do
    c._counts[k] = v
  end
  return c
end

--: (GCounter) -> boolean
function GCounter:eq(other)
  return tables_eq(self._counts, other._counts)
end

-- ─── PN-Counter ──────────────────────────────────────────────────────────────
-- Positive-negative counter: two G-counters, one for increments, one for decrements.

local PNCounter = {}
PNCounter.__index = PNCounter

--: (string) -> PNCounter
function M.pncounter(replica_id)
  return setmetatable({
    _id  = replica_id,
    _pos = M.gcounter(replica_id),
    _neg = M.gcounter(replica_id),
  }, PNCounter)
end

--: (PNCounter, number | nil) -> nil
function PNCounter:increment(n)
  self._pos:increment(n)
end

--: (PNCounter, number | nil) -> nil
function PNCounter:decrement(n)
  self._neg:increment(n)
end

--: (PNCounter) -> number
function PNCounter:value()
  return self._pos:value() - self._neg:value()
end

--: (PNCounter, PNCounter) -> nil
function PNCounter:merge(other)
  self._pos:merge(other._pos)
  self._neg:merge(other._neg)
end

--: (PNCounter) -> PNCounter
function PNCounter:clone()
  local c = M.pncounter(self._id)
  c._pos = self._pos:clone()
  c._neg = self._neg:clone()
  return c
end

--: (PNCounter, PNCounter) -> boolean
function PNCounter:eq(other)
  return self._pos:eq(other._pos) and self._neg:eq(other._neg) and true or false
end

-- ─── LWW-Register ────────────────────────────────────────────────────────────
-- Last-write-wins register: keeps the value with the highest timestamp.

local LWWRegister = {}
LWWRegister.__index = LWWRegister

--: (string) -> LWWRegister
function M.lww_register(replica_id)
  return setmetatable({ _id = replica_id, _value = nil, _ts = -1 }, LWWRegister)
end

--: (LWWRegister, unknown, number) -> nil
function LWWRegister:set(value, ts)
  if ts > self._ts then
    self._value = value
    self._ts    = ts
  end
end

--: (LWWRegister) -> (unknown, number)
function LWWRegister:get()
  return self._value, self._ts
end

--: (LWWRegister, LWWRegister) -> nil
function LWWRegister:merge(other)
  if other._ts > self._ts then
    self._value = other._value
    self._ts    = other._ts
  end
end

--: (LWWRegister) -> LWWRegister
function LWWRegister:clone()
  local c = M.lww_register(self._id)
  c._value = self._value
  c._ts    = self._ts
  return c
end

--: (LWWRegister, LWWRegister) -> boolean
function LWWRegister:eq(other)
  return (self._value == other._value and self._ts == other._ts) and true or false
end

-- ─── 2P-Set ──────────────────────────────────────────────────────────────────
-- Two-phase set: elements added to _add; removals go to _rem.
-- Once removed, an element can never be re-added (remove wins).

local TPSet = {}
TPSet.__index = TPSet

--: () -> TPSet
function M.tpset()
  return setmetatable({ _add = {}, _rem = {} }, TPSet)
end

--: (TPSet, unknown) -> nil
function TPSet:add(elem)
  if not self._rem[elem] then
    self._add[elem] = true
  end
end

--: (TPSet, unknown) -> nil | string
function TPSet:remove(elem)
  if not self._add[elem] then
    return nil, "element not in add-set"
  end
  self._rem[elem] = true
end

--: (TPSet, unknown) -> boolean
function TPSet:contains(elem)
  return (self._add[elem] == true and not self._rem[elem]) and true or false
end

--: (TPSet) -> { [unknown]: boolean }
function TPSet:value()
  local result = {}
  for elem in pairs(self._add) do
    if not self._rem[elem] then
      result[elem] = true
    end
  end
  return result
end

--: (TPSet, TPSet) -> nil
function TPSet:merge(other)
  for elem in pairs(other._add) do
    self._add[elem] = true
  end
  for elem in pairs(other._rem) do
    self._rem[elem] = true
  end
end

--: (TPSet) -> TPSet
function TPSet:clone()
  local c = M.tpset()
  for k in pairs(self._add) do c._add[k] = true end
  for k in pairs(self._rem) do c._rem[k] = true end
  return c
end

--: (TPSet, TPSet) -> boolean
function TPSet:eq(other)
  return (tables_eq(self._add, other._add) and tables_eq(self._rem, other._rem)) and true or false
end

-- ─── OR-Set ───────────────────────────────────────────────────────────────────
-- Observed-remove set: each add operation creates a unique tag.
-- Remove wipes all observed tags; a fresh add creates a new tag, making re-add possible.

local ORSet = {}
ORSet.__index = ORSet

--: (string) -> ORSet
function M.orset(replica_id)
  return setmetatable({ _id = replica_id, _entries = {}, _seq = 0 }, ORSet)
end

-- _entries[elem] = { [unique_tag] = true, ... }

--: (ORSet, unknown) -> nil
function ORSet:add(elem)
  self._seq = self._seq + 1
  local tag = self._id .. ":" .. tostring(self._seq)
  if not self._entries[elem] then
    self._entries[elem] = {}
  end
  local tags_ = self._entries[elem] --[[:! { [string]: boolean }]]
  tags_[tag] = true
end

--: (ORSet, unknown) -> nil
function ORSet:remove(elem)
  -- wipe all currently observed tags
  self._entries[elem] = nil --[[: any]]
end

--: (ORSet, unknown) -> boolean
function ORSet:contains(elem)
  local tags = self._entries[elem]
  if not tags then return false end
  local tags_ = tags --[[:! { [string]: boolean }]]
  return next(tags_) ~= nil
end

--: (ORSet) -> { [unknown]: boolean }
function ORSet:value()
  local result = {}
  for elem, tags in pairs(self._entries) do
    local tags_ = tags --[[:! { [string]: boolean }]]
    if next(tags_) ~= nil then
      result[elem] = true
    end
  end
  return result
end

--: (ORSet, ORSet) -> nil
function ORSet:merge(other)
  for elem, tags in pairs(other._entries) do
    if not self._entries[elem] then
      self._entries[elem] = {}
    end
    local self_tags = self._entries[elem] --[[:! { [string]: boolean }]]
    local tags_ = tags --[[:! { [string]: boolean }]]
    for tag in pairs(tags_) do
      self_tags[tag] = true
    end
  end
end

--: (ORSet) -> ORSet
function ORSet:clone()
  local c = M.orset(self._id)
  c._seq = self._seq
  for elem, tags in pairs(self._entries) do
    local t = {} --: { [string]: boolean }
    local tags_ = tags --[[:! { [string]: boolean }]]
    for tag in pairs(tags_) do t[tag] = true end
    c._entries[elem] = t
  end
  return c
end

--: (ORSet, ORSet) -> boolean
function ORSet:eq(other)
  for elem, tags in pairs(self._entries) do
    local otags = other._entries[elem]
    if not otags then return false end
    if not tables_eq(tags, otags) then return false end
  end
  for elem in pairs(other._entries) do
    if not self._entries[elem] then return false end
  end
  return true
end

-- ─── LWW-Map ──────────────────────────────────────────────────────────────────
-- Last-write-wins map: each key carries its own timestamp.
-- delete() writes a tombstone; a later set() with a higher timestamp revives the key.

local LWWMap = {}
LWWMap.__index = LWWMap

--: (string) -> LWWMap
function M.lww_map(replica_id)
  return setmetatable({ _id = replica_id, _entries = {} }, LWWMap)
end

-- _entries[key] = { value = v, ts = t, deleted = bool }

--: (LWWMap, unknown, unknown, number) -> nil
function LWWMap:set(key, value, ts)
  local entry = self._entries[key] --[[:! LWWEntry | nil]]
  local should_set = not entry
  if entry then
    local entry_ = entry --[[:! LWWEntry]]
    if ts > entry_.ts then should_set = true end
  end
  if should_set then
    self._entries[key] = { value = value, ts = ts, deleted = false }
  end
end

--: (LWWMap, unknown) -> (unknown, number)
function LWWMap:get(key)
  local entry = self._entries[key] --[[:! LWWEntry | nil]]
  if not entry or entry.deleted then return nil end
  return entry.value, entry.ts
end

--: (LWWMap, unknown, number) -> nil
function LWWMap:delete(key, ts)
  local entry = self._entries[key] --[[:! LWWEntry | nil]]
  local should_del = not entry
  if entry then
    local entry_ = entry --[[:! LWWEntry]]
    if ts > entry_.ts then should_del = true end
  end
  if should_del then
    self._entries[key] = { value = nil, ts = ts, deleted = true }
  end
end

--: (LWWMap) -> { [integer]: unknown }
function LWWMap:keys()
  local result = {}
  for k, entry in pairs(self._entries) do
    local entry_ = entry --[[:! LWWEntry]]
    if not entry_.deleted then
      result[#result + 1] = k
    end
  end
  return result
end

--: (LWWMap, LWWMap) -> nil
function LWWMap:merge(other)
  for key, other_entry in pairs(other._entries) do
    local oe_ = other_entry --[[:! LWWEntry]]
    local my_entry = self._entries[key] --[[:! LWWEntry | nil]]
    local should_merge = not my_entry
    if my_entry then
      local my_ = my_entry --[[:! LWWEntry]]
      if oe_.ts > my_.ts then should_merge = true end
    end
    if should_merge then
      self._entries[key] = {
        value   = oe_.value,
        ts      = oe_.ts,
        deleted = oe_.deleted,
      }
    end
  end
end

--: (LWWMap) -> LWWMap
function LWWMap:clone()
  local c = M.lww_map(self._id)
  for key, entry in pairs(self._entries) do
    local entry_ = entry --[[:! LWWEntry]]
    c._entries[key] = { value = entry_.value, ts = entry_.ts, deleted = entry_.deleted }
  end
  return c
end

--: (LWWMap, LWWMap) -> boolean
function LWWMap:eq(other)
  for key, entry in pairs(self._entries) do
    local entry_ = entry --[[:! LWWEntry]]
    local oe = other._entries[key] --[[:! LWWEntry | nil]]
    if not oe then return false end
    if entry_.value ~= oe.value or entry_.ts ~= oe.ts or entry_.deleted ~= oe.deleted then
      return false
    end
  end
  for key in pairs(other._entries) do
    if not self._entries[key] then return false end
  end
  return true
end

return M
