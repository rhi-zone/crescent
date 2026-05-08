if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band  = bit.band
local bor   = bit.bor
local bxor  = bit.bxor
local lshift = bit.lshift
local rshift = bit.rshift

local M = {}
M._tier = "pure"

-- Node types
local NODE_EMPTY      = 0
local NODE_LEAF       = 1
local NODE_INTERIOR   = 2
local NODE_COLLISION  = 3

-- 32-way branching: 5 bits per level, 6 levels covers 30 bits
local BITS = 5
local WIDTH = 32  -- 2^5
local MASK = 31   -- WIDTH - 1

-- ── Hash functions ────────────────────────────────────────────────────────────

-- Simple but decent hash for strings (FNV-1a variant)
local function hash_string(s)
  local h = 2166136261  -- FNV offset basis (32-bit)
  for i = 1, #s do
    h = bxor(h, string.byte(s, i))
    -- FNV prime 16777619; do multiply in two steps to stay in 32-bit range
    h = band(h * 16777619, 0xFFFFFFFF)
  end
  return h
end

-- Hash for numbers: use integer bit pattern
local function hash_number(n)
  local i = math.floor(n)
  if i == n then
    -- integer: simple mix
    local h = band(i, 0xFFFFFFFF)
    h = bxor(h, rshift(h, 16))
    h = band(h * 0x45d9f3b, 0xFFFFFFFF)
    h = bxor(h, rshift(h, 16))
    return h
  else
    -- float: hash string representation
    return hash_string(tostring(n))
  end
end

--: (k: unknown) -> number
local function hash_key(k)
  if type(k) == "string" then
    return hash_string(k)
  elseif type(k) == "number" then
    return hash_number(k)
  else
    -- fallback: tostring
    return hash_string(tostring(k))
  end
end

-- ── Bitmap helpers ────────────────────────────────────────────────────────────

-- Count set bits (popcount) — used to find index in sparse array
local function popcount(x)
  x = band(x, 0xFFFFFFFF)
  x = x - band(rshift(x, 1), 0x55555555)
  x = band(x, 0x33333333) + band(rshift(x, 2), 0x33333333)
  x = band(x + rshift(x, 4), 0x0F0F0F0F)
  x = band(x * 0x01010101, 0xFFFFFFFF)
  return rshift(x, 24)
end

-- Given the 5-bit fragment at this level and the bitmap, return sparse index
local function sparse_index(bitmap, bit_pos)
  -- count bits set below bit_pos
  local mask = bit_pos - 1
  return popcount(band(bitmap, mask))
end

-- ── Node constructors ─────────────────────────────────────────────────────────

local function make_leaf(hash, key, val)
  return { type = NODE_LEAF, hash = hash, key = key, val = val }
end

local function make_collision(hash, entries)
  -- entries: array of {key, val} pairs sharing the same hash
  return { type = NODE_COLLISION, hash = hash, entries = entries }
end

local function make_interior(bitmap, children)
  -- children: sparse array indexed by popcount of bits below
  return { type = NODE_INTERIOR, bitmap = bitmap, children = children }
end

-- ── Trie operations ───────────────────────────────────────────────────────────

-- Get value from subtree rooted at `node` for key with given hash at `shift` bits
local function trie_get(node, hash, key, shift)
  if node == nil then return nil end
  local ntype = node.type

  if ntype == NODE_LEAF then
    if node.hash == hash and node.key == key then
      return node.val
    end
    return nil

  elseif ntype == NODE_COLLISION then
    if node.hash ~= hash then return nil end
    for _, e in ipairs(node.entries) do
      if e[1] == key then return e[2] end
    end
    return nil

  elseif ntype == NODE_INTERIOR then
    local frag = band(rshift(hash, shift), MASK)
    local bit_pos = lshift(1, frag)
    if band(node.bitmap, bit_pos) == 0 then return nil end
    local idx = sparse_index(node.bitmap, bit_pos) + 1
    return trie_get(node.children[idx], hash, key, shift + BITS)
  end
  return nil
end

-- Copy array with one element replaced/inserted at position idx
local function array_set(arr, idx, val)
  local n = #arr
  local new = {}
  for i = 1, n do new[i] = arr[i] end
  new[idx] = val
  return new
end

-- Copy array with one element inserted at position idx (shifting right)
local function array_insert(arr, idx, val)
  local n = #arr
  local new = {}
  for i = 1, idx - 1 do new[i] = arr[i] end
  new[idx] = val
  for i = idx, n do new[i + 1] = arr[i] end
  return new
end

-- Copy array with element at idx removed (shifting left)
local function array_remove(arr, idx)
  local n = #arr
  local new = {}
  for i = 1, idx - 1 do new[i] = arr[i] end
  for i = idx + 1, n do new[i - 1] = arr[i] end
  return new
end

-- Merge two leaves (or a leaf and an existing subtree) that both belong at a
-- deeper level (they differ somewhere at shift..shift+BITS-1 or deeper).
local function merge_leaves(existing, new_leaf, shift)
  -- Both are leaves (or collision node) — need to push them down
  local e_hash = existing.hash
  local n_hash = new_leaf.hash

  if e_hash == n_hash then
    -- True collision — make or extend a collision node
    if existing.type == NODE_COLLISION then
      -- Replace or append
      local entries = existing.entries
      for i, e in ipairs(entries) do
        if e[1] == new_leaf.key then
          local new_entries = array_set(entries, i, {new_leaf.key, new_leaf.val})
          return make_collision(e_hash, new_entries)
        end
      end
      -- Not found — append
      local new_entries = {}
      for i, e in ipairs(entries) do new_entries[i] = e end
      new_entries[#new_entries + 1] = {new_leaf.key, new_leaf.val}
      return make_collision(e_hash, new_entries)
    else
      -- Both are leaves with same hash
      if existing.key == new_leaf.key then
        return new_leaf  -- replace
      end
      return make_collision(e_hash, {{existing.key, existing.val}, {new_leaf.key, new_leaf.val}})
    end
  end

  -- Hashes differ — create an interior node and recurse
  local e_frag = band(rshift(e_hash, shift), MASK)
  local n_frag = band(rshift(n_hash, shift), MASK)

  if e_frag == n_frag then
    -- Same fragment at this level — push both down
    local child = merge_leaves(existing, new_leaf, shift + BITS)
    local bit_pos = lshift(1, e_frag)
    return make_interior(bit_pos, {child})
  else
    local e_bit = lshift(1, e_frag)
    local n_bit = lshift(1, n_frag)
    local bitmap = bor(e_bit, n_bit)
    local children
    if e_frag < n_frag then
      children = {existing, new_leaf}
    else
      children = {new_leaf, existing}
    end
    return make_interior(bitmap, children)
  end
end

-- Insert/update: returns (new_node, size_delta)
-- size_delta is +1 if new key, 0 if replace
local function trie_set(node, hash, key, val, shift)
  if node == nil then
    return make_leaf(hash, key, val), 1
  end

  local ntype = node.type

  if ntype == NODE_LEAF then
    if node.hash == hash and node.key == key then
      -- Replace value
      return make_leaf(hash, key, val), 0
    else
      -- Need to split
      return merge_leaves(node, make_leaf(hash, key, val), shift), 1
    end

  elseif ntype == NODE_COLLISION then
    if node.hash ~= hash then
      -- Different hash — merge with new leaf into interior
      return merge_leaves(node, make_leaf(hash, key, val), shift), 1
    end
    -- Same hash — replace or append in collision entries
    local entries = node.entries
    for i, e in ipairs(entries) do
      if e[1] == key then
        local new_entries = array_set(entries, i, {key, val})
        return make_collision(hash, new_entries), 0
      end
    end
    local new_entries = {}
    for i, e in ipairs(entries) do new_entries[i] = e end
    new_entries[#new_entries + 1] = {key, val}
    return make_collision(hash, new_entries), 1

  elseif ntype == NODE_INTERIOR then
    local frag = band(rshift(hash, shift), MASK)
    local bit_pos = lshift(1, frag)
    local idx = sparse_index(node.bitmap, bit_pos) + 1

    if band(node.bitmap, bit_pos) == 0 then
      -- Slot empty — insert new leaf here
      local new_children = array_insert(node.children, idx, make_leaf(hash, key, val))
      return make_interior(bor(node.bitmap, bit_pos), new_children), 1
    else
      -- Recurse into existing child
      local child, delta = trie_set(node.children[idx], hash, key, val, shift + BITS)
      local new_children = array_set(node.children, idx, child)
      return make_interior(node.bitmap, new_children), delta
    end
  end

  -- Should never reach here
  return make_leaf(hash, key, val), 1
end

-- Delete: returns (new_node_or_nil, size_delta)
-- new_node is nil if the subtree becomes empty
-- size_delta is -1 if deleted, 0 if not found
local function trie_delete(node, hash, key, shift)
  if node == nil then return nil, 0 end

  local ntype = node.type

  if ntype == NODE_LEAF then
    if node.hash == hash and node.key == key then
      return nil, -1
    end
    return node, 0

  elseif ntype == NODE_COLLISION then
    if node.hash ~= hash then return node, 0 end
    local entries = node.entries
    for i, e in ipairs(entries) do
      if e[1] == key then
        if #entries == 2 then
          -- Collapse to a single leaf
          local other = entries[i == 1 and 2 or 1]
          return make_leaf(hash, other[1], other[2]), -1
        end
        local new_entries = array_remove(entries, i)
        return make_collision(hash, new_entries), -1
      end
    end
    return node, 0

  elseif ntype == NODE_INTERIOR then
    local frag = band(rshift(hash, shift), MASK)
    local bit_pos = lshift(1, frag)

    if band(node.bitmap, bit_pos) == 0 then
      return node, 0  -- key not present
    end

    local idx = sparse_index(node.bitmap, bit_pos) + 1
    local child, delta = trie_delete(node.children[idx], hash, key, shift + BITS)

    if delta == 0 then return node, 0 end

    if child == nil then
      -- Remove slot from interior
      local new_children = array_remove(node.children, idx)
      local new_bitmap = band(node.bitmap, bxor(0xFFFFFFFF, bit_pos))
      -- If only one child remains and it's a leaf, collapse
      if new_bitmap ~= 0 and #new_children == 1 then
        local only = new_children[1]
        if only.type == NODE_LEAF or only.type == NODE_COLLISION then
          return only, -1
        end
      end
      if new_bitmap == 0 then
        return nil, -1
      end
      return make_interior(new_bitmap, new_children), -1
    else
      local new_children = array_set(node.children, idx, child)
      return make_interior(node.bitmap, new_children), -1
    end
  end

  return node, 0
end

-- Iterate all entries in a subtree, calling fn(key, val)
local function trie_each(node, fn)
  if node == nil then return end
  local ntype = node.type
  if ntype == NODE_LEAF then
    fn(node.key, node.val)
  elseif ntype == NODE_COLLISION then
    for _, e in ipairs(node.entries) do
      fn(e[1], e[2])
    end
  elseif ntype == NODE_INTERIOR then
    for _, child in ipairs(node.children) do
      trie_each(child, fn)
    end
  end
end

-- ── Map object ────────────────────────────────────────────────────────────────

local Map = {}
Map.__index = Map

function Map:get(key)
  return trie_get(self._root, hash_key(key), key, 0)
end

function Map:has(key)
  return trie_get(self._root, hash_key(key), key, 0) ~= nil
end

function Map:set(key, val)
  local new_root, delta = trie_set(self._root, hash_key(key), key, val, 0)
  local new_map = setmetatable({}, Map)
  new_map._root = new_root
  new_map._size = self._size + delta
  return new_map
end

function Map:delete(key)
  local new_root, delta = trie_delete(self._root, hash_key(key), key, 0)
  if delta == 0 then return self end
  local new_map = setmetatable({}, Map)
  new_map._root = new_root
  new_map._size = self._size + delta
  return new_map
end

function Map:size()
  return self._size
end

function Map:pairs()
  -- Collect all entries, then return a stateful iterator
  local keys = {}
  local vals = {}
  local n = 0
  trie_each(self._root, function(k, v)
    n = n + 1
    keys[n] = k
    vals[n] = v
  end)
  local i = 0
  return function()
    i = i + 1
    if i <= n then return keys[i], vals[i] end
  end
end

function Map:to_table()
  local t = {}
  trie_each(self._root, function(k, v)
    t[k] = v
  end)
  return t
end

-- ── Module API ────────────────────────────────────────────────────────────────

function M.new()
  local map = setmetatable({}, Map)
  map._root = nil
  map._size = 0
  return map
end

function M.from_table(t)
  local map = M.new()
  for k, v in pairs(t) do
    map = map:set(k, v)
  end
  return map
end

function M.merge(m1, m2)
  -- m2 wins on conflict — iterate m2 and set into m1
  local result = m1
  for k, v in m2:pairs() do
    result = result:set(k, v)
  end
  return result
end

return M
