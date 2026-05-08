-- lib/merkle_tree/init.lua
-- Merkle tree for data integrity verification.
-- Supports proofs, diff, concat, and sparse Merkle trees.
--
-- Default hash: FNV-1a 64-bit folded to 32-bit (pure Lua, 8-char hex).
-- Production use: inject SHA-256 or better via opts.hash_fn.
--
-- API:
--   M.new(items, opts) -> tree | (nil, errmsg)
--   tree.root          -> hex string root hash
--   tree.leaves        -> array of leaf hashes
--   tree.depth         -> integer
--   tree:proof(index)  -> proof table
--   M.verify(proof, leaf_hash, hash_fn) -> boolean
--   tree:update_root(index, new_data) -> new_root_hash
--   tree:update(index, new_data) -> new_tree
--   M.diff(tree_a, tree_b) -> { changed_indices }
--   M.concat(tree_a, tree_b) -> new_tree
--   M.sparse(depth, opts) -> sparse_tree
--   sparse_tree:set(key_hash, value_hash) -> sparse_tree
--   sparse_tree:get_proof(key_hash) -> proof
--   sparse_tree.root   -> hex string
--   M.verify_sparse(proof, key_hash, value_hash, hash_fn) -> boolean

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band, bxor, rshift, lshift = bit.band, bit.bxor, bit.rshift, bit.lshift

local M = {}
M._tier = "pure"

-- ── Default hash: FNV-1a 64-bit folded to 32-bit → 8-char hex ─────────────
-- NOTE: Not cryptographically secure. Inject SHA-256 or better for production.

local HEX = "0123456789abcdef"

local function u32_to_hex(n)
  -- n is a Lua number treated as unsigned 32-bit
  n = band(n, 0xffffffff)
  local b = {}
  for i = 8, 1, -1 do
    b[i] = HEX:sub(band(n, 0xf) + 1, band(n, 0xf) + 1)
    n = rshift(n, 4)
  end
  return table.concat(b)
end

local FNV_PRIME_LO  = 0x1b3      -- lower 16 bits of 0x00000100000001b3
local FNV_PRIME_HI  = 0x01000000 -- upper 32 bits conceptually, but we keep two halves
-- FNV-1a 64-bit: offset_basis = 0xcbf29ce484222325
-- We maintain (hi, lo) as two Lua 32-bit unsigned integers.
local FNV_OFFSET_LO = 0x84222325
local FNV_OFFSET_HI = 0xcbf29ce4 -- note: stored as signed int32 in bit ops, that's fine

local function default_hash(data)
  -- FNV-1a 64-bit: process each byte
  local lo = FNV_OFFSET_LO
  local hi = FNV_OFFSET_HI
  for i = 1, #data do
    local b = data:byte(i)
    -- XOR low byte
    lo = bxor(lo, b)
    -- Multiply by FNV prime (0x00000100000001b3)
    -- prime = 2^40 + 2^8 + 0xb3
    -- (hi, lo) * prime:
    --   result_lo = lo * 0x1b3 (low 32 bits)
    --   result_hi = hi * 0x1b3 + lo * 0x100 (high portion, mod 2^32)
    -- We use 16-bit multiply to avoid float overflow in LuaJIT's double precision.
    local lo0 = band(lo, 0xffff)
    local lo1 = rshift(lo, 16)
    local hi0 = band(hi, 0xffff)
    local hi1 = rshift(hi, 16)

    -- lo * 0x1b3
    local new_lo = lo0 * 0x1b3 + lshift(lo1 * 0x1b3, 16)
    -- carry from lo into hi
    local carry  = rshift(lo0 * 0x1b3, 16) + lo1 * 0x1b3
    carry = rshift(carry, 16)
    -- hi * 0x1b3 + lo * 0x100 + carry
    local new_hi = (hi0 * 0x1b3) + (hi1 * 0x1b3) + (lo * 0x100) + carry

    lo = band(new_lo, 0xffffffff)
    hi = band(new_hi, 0xffffffff)
  end
  -- Fold 64→32: XOR high half into low half
  local folded = bxor(lo, hi)
  return u32_to_hex(folded)
end

-- ── Internal helpers ────────────────────────────────────────────────────────

-- Next power of 2 >= n (minimum 1)
local function next_pow2(n)
  if n <= 1 then return 1 end
  local p = 1
  while p < n do p = lshift(p, 1) end
  return p
end

-- Combine two hashes into a parent hash.
--: (string, string, (string) -> string) -> string
local function combine(h1, h2, hash_fn)
  return hash_fn(h1 .. h2)
end

-- Build internal node array from leaf hashes.
-- Nodes are stored in a flat array, level by level bottom-up.
-- nodes[1..n_leaves] = leaves (padded), nodes[n+1..2n-1] = internal nodes.
-- For i-th leaf (1-indexed), parent index = floor(i/2) in the next level.
-- We use a complete binary tree with leaves padded to next power of 2.
local function build_nodes(leaf_hashes, hash_fn)
  local n = next_pow2(#leaf_hashes)
  -- nodes: 1-indexed flat array, size = 2*n - 1
  -- index layout: root at index 1, left child of i at 2i, right child at 2i+1
  local nodes = {}
  -- Place leaves at indices n..2n-1
  for i = 1, n do
    local leaf = leaf_hashes[i] or leaf_hashes[#leaf_hashes] -- pad with last leaf
    nodes[n + i - 1] = leaf
  end
  -- Build internal nodes bottom-up
  for i = n - 1, 1, -1 do
    nodes[i] = combine(nodes[2 * i], nodes[2 * i + 1], hash_fn)
  end
  return nodes, n
end

-- Compute depth: number of levels including root and leaves.
local function tree_depth(n_padded)
  if n_padded == 1 then return 1 end
  local d = 0
  local x = n_padded
  while x > 0 do
    d = d + 1
    x = rshift(x, 1)
  end
  return d
end

-- ── Tree object methods ─────────────────────────────────────────────────────

--:: MerkleTree = { root: string, leaves: string[], depth: integer, _nodes: string[], _n_padded: integer, _n_real: integer, _hash_fn: (string) -> string, ... }
local Tree = {}
Tree.__index = Tree

-- Return a proof that the leaf at `index` (1-based) is in the tree.
--: (self: MerkleTree, integer) -> ({ root: string, index: integer, path: { hash: string, direction: string }[] } | nil, string | nil)
function Tree:proof(index)
  if index < 1 or index > self._n_real then
    return nil, "merkle_tree: index out of range"
  end
  local n = self._n_padded
  local nodes = self._nodes
  local path = {}
  -- Leaf node position in flat array
  local pos = n + index - 1
  while pos > 1 do
    local sibling
    local direction
    if band(pos, 1) == 0 then
      -- pos is a left child (even index)
      sibling = nodes[pos + 1]
      direction = "right"
    else
      -- pos is a right child (odd index)
      sibling = nodes[pos - 1]
      direction = "left"
    end
    path[#path + 1] = { hash = sibling, direction = direction }
    pos = rshift(pos, 1)
  end
  return {
    root  = self.root,
    index = index,
    path  = path,
  }
end

-- Return new root hash after updating leaf at index with new_data (non-mutating).
--: (self: MerkleTree, integer, string) -> (string | nil, string | nil)
function Tree:update_root(index, new_data)
  if index < 1 or index > self._n_real then
    return nil, "merkle_tree: index out of range"
  end
  local hash_fn = self._hash_fn
  local new_leaf = hash_fn(new_data)
  local n = self._n_padded
  -- Copy nodes
  local nodes = {}
  for i = 1, #self._nodes do nodes[i] = self._nodes[i] end
  -- Update leaf
  nodes[n + index - 1] = new_leaf
  -- Recompute ancestors
  local pos = rshift(n + index - 1, 1)
  while pos >= 1 do
    nodes[pos] = combine(nodes[2 * pos], nodes[2 * pos + 1], hash_fn)
    if pos == 1 then break end
    pos = rshift(pos, 1)
  end
  return nodes[1]
end

-- Return a new tree with the leaf at index replaced by hash_fn(new_data).
--: (self: MerkleTree, integer, string) -> (MerkleTree | nil, string | nil)
function Tree:update(index, new_data)
  if index < 1 or index > self._n_real then
    return nil, "merkle_tree: index out of range"
  end
  local hash_fn = self._hash_fn
  local new_leaves = {}
  for i = 1, #self.leaves do new_leaves[i] = self.leaves[i] end
  new_leaves[index] = hash_fn(new_data)
  return M.new_from_leaf_hashes(new_leaves, self._n_real, hash_fn)
end

-- ── Public API ──────────────────────────────────────────────────────────────

-- Build a tree from raw data items.
-- opts: { hash_fn = function(data) -> hex_string }
function M.new(items, opts)
  if not items or #items == 0 then
    return nil, "merkle_tree: empty items list"
  end
  opts = opts or {}
  local hash_fn = opts.hash_fn or default_hash
  local leaf_hashes = {}
  for i = 1, #items do
    leaf_hashes[i] = hash_fn(items[i])
  end
  return M.new_from_leaf_hashes(leaf_hashes, #items, hash_fn)
end

-- Internal: build tree from already-hashed leaves.
function M.new_from_leaf_hashes(leaf_hashes, n_real, hash_fn)
  local nodes, n_padded = build_nodes(leaf_hashes, hash_fn)
  local t = setmetatable({}, Tree)
  t.root       = nodes[1]
  t.leaves     = leaf_hashes  -- only real leaves (not padded)
  t.depth      = tree_depth(n_padded)
  t._nodes     = nodes
  t._n_padded  = n_padded
  t._n_real    = n_real or #leaf_hashes
  t._hash_fn   = hash_fn
  return t
end

-- Verify a proof for a known leaf hash.
-- proof: { root, index, path = [{hash, direction}] }
function M.verify(proof, leaf_hash, hash_fn)
  if not proof or not proof.path then return false end
  hash_fn = hash_fn or default_hash
  local current = leaf_hash
  for _, step in ipairs(proof.path) do
    if step.direction == "left" then
      current = combine(step.hash, current, hash_fn)
    else
      current = combine(current, step.hash, hash_fn)
    end
  end
  return current == proof.root
end

-- Return list of leaf indices that differ between two trees.
function M.diff(tree_a, tree_b)
  -- Walk the trees together, pruning subtrees that match.
  local changed = {}
  local n = math.max(tree_a._n_padded, tree_b._n_padded)
  -- Normalize both trees to same padded size for comparison
  local function get(tree, pos)
    return tree._nodes[pos]
  end
  local function walk(a, b, pos, leaf_start, leaf_end)
    local ha = get(a, pos)
    local hb = get(b, pos)
    if ha == hb then return end  -- subtree identical
    -- Leaf level?
    local a_leaf_start = a._n_padded
    local b_leaf_start = b._n_padded
    -- Determine if we're at a leaf level for tree_a
    if pos >= a_leaf_start and pos >= b_leaf_start then
      -- Leaf node
      local idx = math.min(
        pos - a_leaf_start + 1,
        pos - b_leaf_start + 1
      )
      -- Use tree_a's offset
      local idx_a = pos - a._n_padded + 1
      local idx_b = pos - b._n_padded + 1
      -- Only report if within real leaves of either tree
      if idx_a >= 1 and idx_a <= a._n_real then
        changed[#changed + 1] = idx_a
      elseif idx_b >= 1 and idx_b <= b._n_real then
        changed[#changed + 1] = idx_b
      end
      return
    end
    -- We need to handle mismatched tree sizes: recurse differently
    -- Simplest approach for equal-sized trees
    if a._n_padded == b._n_padded then
      walk(a, b, 2 * pos,     leaf_start, leaf_start + (leaf_end - leaf_start) / 2 - 1)
      walk(a, b, 2 * pos + 1, leaf_start + (leaf_end - leaf_start) / 2, leaf_end)
    else
      -- Different sizes: fall back to leaf-by-leaf comparison
      return nil, "different_sizes"
    end
  end
  if tree_a._n_padded == tree_b._n_padded then
    walk(tree_a, tree_b, 1, 1, tree_a._n_padded)
  else
    -- Different padded sizes: compare leaf-by-leaf directly
    local max_real = math.max(tree_a._n_real, tree_b._n_real)
    for i = 1, max_real do
      local ha = tree_a.leaves[i]
      local hb = tree_b.leaves[i]
      if ha ~= hb then
        changed[#changed + 1] = i
      end
    end
  end
  return changed
end

-- Concatenate two trees into a new tree with combined leaf set.
function M.concat(tree_a, tree_b)
  local hash_fn = tree_a._hash_fn
  local leaves = {}
  for i = 1, #tree_a.leaves do
    leaves[#leaves + 1] = tree_a.leaves[i]
  end
  for i = 1, #tree_b.leaves do
    leaves[#leaves + 1] = tree_b.leaves[i]
  end
  return M.new_from_leaf_hashes(leaves, #leaves, hash_fn)
end

-- ── Sparse Merkle Tree ──────────────────────────────────────────────────────
-- A sparse Merkle tree over a key space of 2^depth positions.
-- Empty slots have hash = default_hash("") (the "zero" hash).
-- Implemented as a persistent (non-mutating) trie over the key's bits.

local Sparse = {}
Sparse.__index = Sparse

-- Sentinel zero-hash cache: zero_hashes[i] = hash at depth i (0 = leaf)
local function make_zero_hashes(depth, hash_fn)
  local zh = {}
  zh[0] = hash_fn("")  -- empty leaf
  for i = 1, depth do
    zh[i] = hash_fn(zh[i - 1] .. zh[i - 1])
  end
  return zh
end

-- Internal node representation: { left, right } or nil (use zero hash)
-- Leaf nodes are stored in the `values` table: key_hash -> value_hash

-- Compute root from trie nodes + zero hashes.
-- node is a Lua table {left=node|nil, right=node|nil} or nil.
-- level: current level (depth at root, 0 at leaf).
local function sparse_root(node, level, zh, hash_fn)
  if node == nil then
    return zh[level]
  end
  if level == 0 then
    -- Leaf: node.value is the stored value hash
    return node.value or zh[0]
  end
  local left  = sparse_root(node.left,  level - 1, zh, hash_fn)
  local right = sparse_root(node.right, level - 1, zh, hash_fn)
  return hash_fn(left .. right)
end

-- Extract the i-th bit (MSB first) of a hex string key (bit 0 = most significant).
-- hex key must be at least ceil(depth/4) chars.
local function hex_bit(key_hex, i)
  -- i is 0-based bit index
  local char_idx = rshift(i, 2) + 1  -- which hex character (1-based)
  local bit_idx  = 3 - band(i, 3)    -- which bit within that nybble (3=MSB)
  local c = key_hex:sub(char_idx, char_idx)
  local nybble = tonumber(c, 16) or 0
  return band(rshift(nybble, bit_idx), 1)
end

-- Set a value in the trie (returns new root node).
local function sparse_set_node(node, key_hex, value_hash, level)
  if level < 0 then
    -- Leaf level
    return { value = value_hash }
  end
  node = node or {}
  local bit = hex_bit(key_hex, node._depth or (level))  -- use level as bit index
  -- bit_index: at depth=D (root), we use bit 0; at depth=0 (just above leaf), bit D-1.
  -- We'll pass the current bit index separately.
  -- Actually restructure: pass bit_pos = D - level (0 at root, D-1 just above leaf).
  -- Let's redo with explicit bit_pos parameter below.
  return node  -- placeholder, see sparse_set below
end

-- Proper recursive set with explicit bit position.
local function trie_set(node, key_hex, value_hash, bit_pos, max_bit)
  node = node and { left = node.left, right = node.right, value = node.value } or {}
  if bit_pos > max_bit then
    -- Leaf
    node.value = value_hash
    return node
  end
  local b = hex_bit(key_hex, bit_pos)
  if b == 0 then
    node.left  = trie_set(node.left,  key_hex, value_hash, bit_pos + 1, max_bit)
  else
    node.right = trie_set(node.right, key_hex, value_hash, bit_pos + 1, max_bit)
  end
  return node
end

-- Build proof path for a key.
-- Returns path array: [{hash=sibling_hash, direction="left"|"right"}, ...]
-- from leaf to root.
local function trie_proof_path(node, key_hex, bit_pos, max_bit, zh, hash_fn)
  if bit_pos > max_bit then
    return {}
  end
  local level = max_bit - bit_pos  -- zero-hash level for sibling
  local b = hex_bit(key_hex, bit_pos)
  local sibling_node
  if b == 0 then
    sibling_node = node and node.right or nil
  else
    sibling_node = node and node.left or nil
  end
  local sibling_hash = sparse_root(sibling_node, level, zh, hash_fn)
  local child_node   = node and (b == 0 and node.left or node.right) or nil
  local path = trie_proof_path(child_node, key_hex, bit_pos + 1, max_bit, zh, hash_fn)
  -- Insert at beginning: path goes from leaf→root, so append in reverse
  -- We build bottom-up: deepest first, so append here.
  if b == 0 then
    path[#path + 1] = { hash = sibling_hash, direction = "right" }
  else
    path[#path + 1] = { hash = sibling_hash, direction = "left" }
  end
  return path
end

-- Create a new sparse Merkle tree.
-- depth: number of key bits (e.g. 32 for a 2^32 key space)
function M.sparse(depth, opts)
  if not depth or depth < 1 then
    return nil, "merkle_tree: sparse depth must be >= 1"
  end
  opts = opts or {}
  local hash_fn = opts.hash_fn or default_hash
  local zh = make_zero_hashes(depth, hash_fn)
  local st = setmetatable({}, Sparse)
  st._depth   = depth
  st._hash_fn = hash_fn
  st._zh      = zh
  st._trie    = nil  -- empty trie
  st.root     = zh[depth]
  return st
end

-- Return a new sparse tree with key_hash -> value_hash set.
function Sparse:set(key_hash, value_hash)
  local new_trie = trie_set(self._trie, key_hash, value_hash, 0, self._depth - 1)
  local st = setmetatable({}, Sparse)
  st._depth   = self._depth
  st._hash_fn = self._hash_fn
  st._zh      = self._zh
  st._trie    = new_trie
  st.root     = sparse_root(new_trie, self._depth, self._zh, self._hash_fn)
  return st
end

-- Return a proof for key_hash.
-- proof: { root, key_hash, path = [{hash, direction}] }
-- path[1] is the sibling closest to the leaf; path[depth] is the sibling at root level.
function Sparse:get_proof(key_hash)
  local path = trie_proof_path(
    self._trie, key_hash, 0, self._depth - 1, self._zh, self._hash_fn
  )
  return {
    root     = self.root,
    key_hash = key_hash,
    path     = path,
  }
end

-- Verify a sparse Merkle proof.
-- value_hash: the expected value at key_hash (use hash_fn("") for empty/absent)
function M.verify_sparse(proof, key_hash, value_hash, hash_fn)
  if not proof or not proof.path then return false end
  hash_fn = hash_fn or default_hash
  -- Reconstruct root from value_hash and path.
  -- path[1] is shallowest sibling (nearest leaf), path[depth] is deepest (nearest root).
  -- Walk path in order (leaf to root).
  local current = value_hash
  for _, step in ipairs(proof.path) do
    if step.direction == "left" then
      current = hash_fn(step.hash .. current)
    else
      current = hash_fn(current .. step.hash)
    end
  end
  return current == proof.root
end

-- ── Default hash export (for tests) ─────────────────────────────────────────
M.default_hash = default_hash

return M
