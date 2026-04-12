-- lib/merkle/init.lua
-- Merkle tree for data integrity and efficient verification.
--
-- Public API:
--   merkle.build(blocks)              -> tree
--   merkle.build_from_hashes(hashes)  -> tree
--   merkle.verify(leaf_data, proof, root_hash) -> bool
--
--   tree:root()       -> 64-char hex string
--   tree:proof(i)     -> array of {hash=hex, side="left"|"right"}
--   tree:leaf_hash(i) -> 64-char hex string
--   tree:size()       -> number of original leaves
--   tree:height()     -> depth of tree (0 for single leaf)
--   tree:node_count() -> total nodes in tree
--   tree:update(i, new_data) -> new root hex string
--   tree:serialize()  -> plain Lua table
--   merkle.deserialize(t) -> tree
--
-- Hashing (domain-separated to prevent second-preimage attacks):
--   Leaf:   H("\x00" || data)
--   Parent: H("\x01" || left_hex_bytes || right_hex_bytes)
--
-- Tree layout: perfect binary tree of size 2^h stored as 1-indexed flat array.
--   nodes[1]         = root
--   left child of i  = 2*i
--   right child of i = 2*i + 1
-- Leaves occupy nodes[padded..2*padded-1] (last level).
--
-- merkle._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sha256_mod = require("lib.hash.sha256")
local sha256 = sha256_mod.sha256

local M = {}
M._tier = "pure"

-- ── Internal helpers ──────────────────────────────────────────────────────────

-- Convert a 64-char hex string to a 32-byte binary string.
local function hex_to_bytes(hex)
	return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

-- Hash a leaf block (domain separation byte \x00).
local function hash_leaf(data)
	return sha256("\x00" .. data)
end

-- Hash two child hex strings into a parent hex string (domain separation byte \x01).
local function hash_pair(left_hex, right_hex)
	return sha256("\x01" .. hex_to_bytes(left_hex) .. hex_to_bytes(right_hex))
end

-- Next power of 2 >= n (n >= 1).
local function next_pow2(n)
	local p = 1
	while p < n do p = p * 2 end
	return p
end

-- ── Tree builder ──────────────────────────────────────────────────────────────

-- Build a perfect binary tree from an array of leaf hex hashes.
-- Returns nodes[] (flat 1-indexed array) and padded (number of leaves in last layer).
local function build_tree(leaf_hashes, padded)
	-- Total nodes in a perfect binary tree of depth h where padded = 2^h.
	local total = 2 * padded - 1
	local nodes = {}

	-- Fill leaf layer (indices padded..2*padded-1 in 1-indexed flat array).
	for i = 1, padded do
		nodes[padded + i - 1] = leaf_hashes[i]
	end

	-- Build interior nodes bottom-up.
	for i = padded - 1, 1, -1 do
		nodes[i] = hash_pair(nodes[2 * i], nodes[2 * i + 1])
	end

	return nodes, total
end

-- ── Tree object ───────────────────────────────────────────────────────────────

local Tree = {}
Tree.__index = Tree

-- tree._nodes   flat 1-indexed array of hex hashes
-- tree._size    original (unpadded) number of leaves
-- tree._padded  padded leaf count (power of 2)
-- tree._height  log2(padded)

local function make_tree(nodes, size, padded)
	local height = 0
	local p = padded
	while p > 1 do height = height + 1; p = p / 2 end
	return setmetatable({
		_nodes  = nodes,
		_size   = size,
		_padded = padded,
		_height = height,
	}, Tree)
end

function Tree:root()
	return self._nodes[1]
end

function Tree:size()
	return self._size
end

function Tree:height()
	return self._height
end

function Tree:node_count()
	return 2 * self._padded - 1
end

-- Leaf index in flat nodes array (1-indexed leaf i).
function Tree:_leaf_idx(i)
	return self._padded + i - 1
end

function Tree:leaf_hash(i)
	if i < 1 or i > self._size then
		return nil, "index out of range"
	end
	return self._nodes[self:_leaf_idx(i)]
end

-- Return a proof for leaf i (1-indexed).
-- proof is an array of {hash=hex, side="left"|"right"}.
-- "side" is the side of the SIBLING, so to recompute the parent:
--   if side == "left":  parent = H(sibling || current)
--   if side == "right": parent = H(current || sibling)
function Tree:proof(i)
	if i < 1 or i > self._size then
		return nil, "index out of range"
	end
	local nodes = self._nodes
	local steps = {}
	local idx = self:_leaf_idx(i)

	while idx > 1 do
		local parent = math.floor(idx / 2)
		local sibling
		local side
		if idx % 2 == 0 then
			-- idx is left child, sibling is right
			sibling = idx + 1
			side = "right"
		else
			-- idx is right child, sibling is left
			sibling = idx - 1
			side = "left"
		end
		steps[#steps + 1] = { hash = nodes[sibling], side = side }
		idx = parent
	end

	return steps
end

-- Verify a proof for leaf_data against root_hash.
function M.verify(leaf_data, proof, root_hash)
	local current = hash_leaf(leaf_data)
	for _, step in ipairs(proof) do
		if step.side == "right" then
			current = hash_pair(current, step.hash)
		else
			current = hash_pair(step.hash, current)
		end
	end
	return current == root_hash
end

-- Update leaf i (1-indexed) with new_data; recompute the path to root.
function Tree:update(i, new_data)
	if i < 1 or i > self._size then
		return nil, "index out of range"
	end
	local nodes = self._nodes
	local padded = self._padded
	local idx = padded + i - 1

	-- Update the leaf.
	nodes[idx] = hash_leaf(new_data)

	-- Recompute duplicate if last leaf and padded > size.
	-- When i == self._size and padded > size, the next slot is a duplicate.
	if i == self._size and padded > self._size then
		nodes[padded + self._size] = nodes[idx]
	end

	-- Walk up, recomputing parents.
	idx = math.floor(idx / 2)
	while idx >= 1 do
		nodes[idx] = hash_pair(nodes[2 * idx], nodes[2 * idx + 1])
		if idx == 1 then break end
		idx = math.floor(idx / 2)
	end

	return nodes[1]
end

-- Serialize: returns a plain Lua table with all fields needed to restore.
function Tree:serialize()
	local t = {
		size   = self._size,
		padded = self._padded,
		nodes  = {},
	}
	for i, h in ipairs(self._nodes) do
		t.nodes[i] = h
	end
	return t
end

-- ── Public constructors ───────────────────────────────────────────────────────

-- Build from raw data blocks (strings).
function M.build(blocks)
	local n = #blocks
	if n == 0 then
		return nil, "blocks must not be empty"
	end

	local padded = next_pow2(n)

	-- Hash leaves.
	local leaf_hashes = {}
	for i = 1, n do
		leaf_hashes[i] = hash_leaf(blocks[i])
	end
	-- Duplicate last leaf to fill odd gaps (Bitcoin-style).
	for i = n + 1, padded do
		leaf_hashes[i] = leaf_hashes[n]
	end

	local nodes = build_tree(leaf_hashes, padded)
	return make_tree(nodes, n, padded)
end

-- Build from pre-hashed leaves (64-char hex strings).
function M.build_from_hashes(hashes)
	local n = #hashes
	if n == 0 then
		return nil, "hashes must not be empty"
	end

	local padded = next_pow2(n)

	local leaf_hashes = {}
	for i = 1, n do
		leaf_hashes[i] = hashes[i]
	end
	for i = n + 1, padded do
		leaf_hashes[i] = leaf_hashes[n]
	end

	local nodes = build_tree(leaf_hashes, padded)
	return make_tree(nodes, n, padded)
end

-- Restore a tree from a serialized table.
function M.deserialize(t)
	return make_tree(t.nodes, t.size, t.padded)
end

return M
