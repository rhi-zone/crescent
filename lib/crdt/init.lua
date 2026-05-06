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

function PNCounter:increment(n)
  local self_ = self --[[:! PNCounter]]
  self_._pos:increment(n)
end

function PNCounter:decrement(n)
  local self_ = self --[[:! PNCounter]]
  self_._neg:increment(n)
end

--: () -> number
function PNCounter:value()
  local self_ = self --[[:! PNCounter]]
  return self_._pos:value() - self_._neg:value()
end

--: (PNCounter) -> nil
function PNCounter:merge(other)
  local self_ = self --[[:! PNCounter]]
  local other_ = other --[[:! PNCounter]]
  self_._pos:merge(other_._pos)
  self_._neg:merge(other_._neg)
end

--: () -> PNCounter
function PNCounter:clone()
  local self_ = self --[[:! PNCounter]]
  local c = M.pncounter(self_._id)
  c._pos = self_._pos:clone()
  c._neg = self_._neg:clone()
  return c
end

--: (PNCounter) -> boolean
function PNCounter:eq(other)
  local self_ = self --[[:! PNCounter]]
  local other_ = other --[[:! PNCounter]]
  return self_._pos:eq(other_._pos) and self_._neg:eq(other_._neg) and true or false
end

-- ─── LWW-Register ────────────────────────────────────────────────────────────
-- Last-write-wins register: keeps the value with the highest timestamp.

local LWWRegister = {}
LWWRegister.__index = LWWRegister

--: (string) -> LWWRegister
function M.lww_register(replica_id)
  return setmetatable({ _id = replica_id, _value = nil, _ts = -1 }, LWWRegister)
end

--: (unknown, number) -> nil
function LWWRegister:set(value, ts)
  local self_ = self --[[:! LWWRegister]]
  if ts > self_._ts then
    self_._value = value
    self_._ts    = ts
  end
end

--: () -> (unknown, number)
function LWWRegister:get()
  local self_ = self --[[:! LWWRegister]]
  return self_._value, self_._ts
end

--: (LWWRegister) -> nil
function LWWRegister:merge(other)
  local self_ = self --[[:! LWWRegister]]
  local other_ = other --[[:! LWWRegister]]
  if other_._ts > self_._ts then
    self_._value = other_._value
    self_._ts    = other_._ts
  end
end

--: () -> LWWRegister
function LWWRegister:clone()
  local self_ = self --[[:! LWWRegister]]
  local c = M.lww_register(self_._id)
  c._value = self_._value
  c._ts    = self_._ts
  return c
end

--: (LWWRegister) -> boolean
function LWWRegister:eq(other)
  local self_ = self --[[:! LWWRegister]]
  local other_ = other --[[:! LWWRegister]]
  return (self_._value == other_._value and self_._ts == other_._ts) and true or false
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

--: (unknown) -> nil
function TPSet:add(elem)
  local self_ = self --[[:! TPSet]]
  if not self_._rem[elem] then
    self_._add[elem] = true
  end
end

--: (unknown) -> nil | string
function TPSet:remove(elem)
  local self_ = self --[[:! TPSet]]
  if not self_._add[elem] then
    return nil, "element not in add-set"
  end
  self_._rem[elem] = true
end

--: (unknown) -> boolean
function TPSet:contains(elem)
  local self_ = self --[[:! TPSet]]
  return (self_._add[elem] == true and not self_._rem[elem]) and true or false
end

--: () -> { [unknown]: boolean }
function TPSet:value()
  local self_ = self --[[:! TPSet]]
  local result = {}
  for elem in pairs(self_._add) do
    if not self_._rem[elem] then
      result[elem] = true
    end
  end
  return result
end

--: (TPSet) -> nil
function TPSet:merge(other)
  local self_ = self --[[:! TPSet]]
  local other_ = other --[[:! TPSet]]
  for elem in pairs(other_._add) do
    self_._add[elem] = true
  end
  for elem in pairs(other_._rem) do
    self_._rem[elem] = true
  end
end

--: () -> TPSet
function TPSet:clone()
  local self_ = self --[[:! TPSet]]
  local c = M.tpset()
  for k in pairs(self_._add) do c._add[k] = true end
  for k in pairs(self_._rem) do c._rem[k] = true end
  return c
end

--: (TPSet) -> boolean
function TPSet:eq(other)
  local self_ = self --[[:! TPSet]]
  local other_ = other --[[:! TPSet]]
  return (tables_eq(self_._add, other_._add) and tables_eq(self_._rem, other_._rem)) and true or false
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

--: (unknown) -> nil
function ORSet:add(elem)
  local self_ = self --[[:! ORSet]]
  self_._seq = self_._seq + 1
  local tag = self_._id .. ":" .. tostring(self_._seq)
  if not self_._entries[elem] then
    self_._entries[elem] = {}
  end
  local tags_ = self_._entries[elem] --[[:! { [string]: boolean }]]
  tags_[tag] = true
end

--: (unknown) -> nil
function ORSet:remove(elem)
  -- wipe all currently observed tags
  local self_ = self --[[:! ORSet]]
  self_._entries[elem] = nil --[[: any]]
end

--: (unknown) -> boolean
function ORSet:contains(elem)
  local self_ = self --[[:! ORSet]]
  local tags = self_._entries[elem]
  if not tags then return false end
  local tags_ = tags --[[:! { [string]: boolean }]]
  return next(tags_) ~= nil
end

--: () -> { [unknown]: boolean }
function ORSet:value()
  local self_ = self --[[:! ORSet]]
  local result = {}
  for elem, tags in pairs(self_._entries) do
    local tags_ = tags --[[:! { [string]: boolean }]]
    if next(tags_) ~= nil then
      result[elem] = true
    end
  end
  return result
end

--: (ORSet) -> nil
function ORSet:merge(other)
  local self_ = self --[[:! ORSet]]
  local other_ = other --[[:! ORSet]]
  for elem, tags in pairs(other_._entries) do
    if not self_._entries[elem] then
      self_._entries[elem] = {}
    end
    local self_tags = self_._entries[elem] --[[:! { [string]: boolean }]]
    local tags_ = tags --[[:! { [string]: boolean }]]
    for tag in pairs(tags_) do
      self_tags[tag] = true
    end
  end
end

--: () -> ORSet
function ORSet:clone()
  local self_ = self --[[:! ORSet]]
  local c = M.orset(self_._id)
  c._seq = self_._seq
  for elem, tags in pairs(self_._entries) do
    local t = {} --: { [string]: boolean }
    local tags_ = tags --[[:! { [string]: boolean }]]
    for tag in pairs(tags_) do t[tag] = true end
    c._entries[elem] = t
  end
  return c
end

--: (ORSet) -> boolean
function ORSet:eq(other)
  local self_ = self --[[:! ORSet]]
  local other_ = other --[[:! ORSet]]
  for elem, tags in pairs(self_._entries) do
    local otags = other_._entries[elem]
    if not otags then return false end
    if not tables_eq(tags, otags) then return false end
  end
  for elem in pairs(other_._entries) do
    if not self_._entries[elem] then return false end
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

--: (unknown, unknown, number) -> nil
function LWWMap:set(key, value, ts)
  local self_ = self --[[:! LWWMap]]
  local entry = self_._entries[key] --[[:! LWWEntry | nil]]
  local should_set = not entry
  if entry then
    local entry_ = entry --[[:! LWWEntry]]
    if ts > entry_.ts then should_set = true end
  end
  if should_set then
    self_._entries[key] = { value = value, ts = ts, deleted = false }
  end
end

--: (unknown) -> (unknown, number)
function LWWMap:get(key)
  local self_ = self --[[:! LWWMap]]
  local entry = self_._entries[key] --[[:! LWWEntry | nil]]
  if not entry or entry.deleted then return nil end
  return entry.value, entry.ts
end

--: (unknown, number) -> nil
function LWWMap:delete(key, ts)
  local self_ = self --[[:! LWWMap]]
  local entry = self_._entries[key] --[[:! LWWEntry | nil]]
  local should_del = not entry
  if entry then
    local entry_ = entry --[[:! LWWEntry]]
    if ts > entry_.ts then should_del = true end
  end
  if should_del then
    self_._entries[key] = { value = nil, ts = ts, deleted = true }
  end
end

--: () -> { [integer]: unknown }
function LWWMap:keys()
  local self_ = self --[[:! LWWMap]]
  local result = {}
  for k, entry in pairs(self_._entries) do
    local entry_ = entry --[[:! LWWEntry]]
    if not entry_.deleted then
      result[#result + 1] = k
    end
  end
  return result
end

--: (LWWMap) -> nil
function LWWMap:merge(other)
  local self_ = self --[[:! LWWMap]]
  local other_ = other --[[:! LWWMap]]
  for key, other_entry in pairs(other_._entries) do
    local oe_ = other_entry --[[:! LWWEntry]]
    local my_entry = self_._entries[key] --[[:! LWWEntry | nil]]
    local should_merge = not my_entry
    if my_entry then
      local my_ = my_entry --[[:! LWWEntry]]
      if oe_.ts > my_.ts then should_merge = true end
    end
    if should_merge then
      self_._entries[key] = {
        value   = oe_.value,
        ts      = oe_.ts,
        deleted = oe_.deleted,
      }
    end
  end
end

--: () -> LWWMap
function LWWMap:clone()
  local self_ = self --[[:! LWWMap]]
  local c = M.lww_map(self_._id)
  for key, entry in pairs(self_._entries) do
    local entry_ = entry --[[:! LWWEntry]]
    c._entries[key] = { value = entry_.value, ts = entry_.ts, deleted = entry_.deleted }
  end
  return c
end

--: (LWWMap) -> boolean
function LWWMap:eq(other)
  local self_ = self --[[:! LWWMap]]
  local other_ = other --[[:! LWWMap]]
  for key, entry in pairs(self_._entries) do
    local entry_ = entry --[[:! LWWEntry]]
    local oe = other_._entries[key] --[[:! LWWEntry | nil]]
    if not oe then return false end
    if entry_.value ~= oe.value or entry_.ts ~= oe.ts or entry_.deleted ~= oe.deleted then
      return false
    end
  end
  for key in pairs(other_._entries) do
    if not self_._entries[key] then return false end
  end
  return true
end

return M
