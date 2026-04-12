-- lib/merkle_tree/merkle_tree_test.lua
-- Tests for the Merkle tree library.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.merkle_tree")

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Simple deterministic hash for testing: "h(<data>)"
local function test_hash(data)
  return M.default_hash(data)
end

-- Make items array of n strings: "item1", "item2", ...
local function make_items(n)
  local t = {}
  for i = 1, n do t[i] = "item" .. i end
  return t
end

-- ── Error handling ───────────────────────────────────────────────────────────

T.describe("merkle_tree: error handling", function()
  T.it("returns error on empty items", function()
    local tree, err = M.new({})
    T.eq(tree, nil, "tree is nil")
    T.eq(err, "merkle_tree: empty items list", "correct error message")
  end)

  T.it("returns error on nil items", function()
    local tree, err = M.new(nil)
    T.eq(tree, nil, "tree is nil")
    T.ok(err ~= nil, "error message set")
  end)

  T.it("proof returns error on out-of-range index", function()
    local tree = M.new({"a", "b"})
    local proof, err = tree:proof(0)
    T.eq(proof, nil, "nil on index 0")
    T.ok(err ~= nil, "error set")
    local proof2, err2 = tree:proof(3)
    T.eq(proof2, nil, "nil on index 3")
    T.ok(err2 ~= nil, "error set")
  end)
end)

-- ── Basic tree construction ──────────────────────────────────────────────────

T.describe("merkle_tree: construction", function()
  T.it("single leaf", function()
    local tree = M.new({"a"})
    T.ok(tree ~= nil, "tree created")
    T.eq(#tree.leaves, 1, "one leaf")
    T.eq(tree.depth, 1, "depth is 1 for single leaf")
    T.ok(type(tree.root) == "string", "root is a string")
    T.ok(#tree.root > 0, "root is non-empty")
  end)

  T.it("two leaves", function()
    local tree = M.new({"a", "b"})
    T.ok(tree ~= nil, "tree created")
    T.eq(#tree.leaves, 2, "two leaves")
    T.eq(tree.depth, 2, "depth is 2")
    -- Root should combine both leaf hashes
    T.neq(tree.root, tree.leaves[1], "root != leaf1")
    T.neq(tree.root, tree.leaves[2], "root != leaf2")
  end)

  T.it("three leaves", function()
    local tree = M.new({"a", "b", "c"})
    T.ok(tree ~= nil, "tree created")
    T.eq(#tree.leaves, 3, "three leaves")
    T.eq(tree.depth, 3, "depth is 3 (padded to 4)")
  end)

  T.it("four leaves (exact power of 2)", function()
    local tree = M.new({"a", "b", "c", "d"})
    T.ok(tree ~= nil, "tree created")
    T.eq(#tree.leaves, 4, "four leaves")
    T.eq(tree.depth, 3, "depth is 3 for 4 leaves")
  end)

  T.it("seven leaves", function()
    local tree = M.new(make_items(7))
    T.ok(tree ~= nil, "tree created")
    T.eq(#tree.leaves, 7, "seven leaves")
    T.eq(tree.depth, 4, "depth is 4 (padded to 8)")
  end)

  T.it("eight leaves (exact power of 2)", function()
    local tree = M.new(make_items(8))
    T.ok(tree ~= nil, "tree created")
    T.eq(#tree.leaves, 8, "eight leaves")
    T.eq(tree.depth, 4, "depth is 4")
  end)

  T.it("root differs for different data", function()
    local t1 = M.new({"a", "b"})
    local t2 = M.new({"a", "c"})
    T.neq(t1.root, t2.root, "different data → different root")
  end)

  T.it("same data → same root (deterministic)", function()
    local t1 = M.new({"x", "y", "z"})
    local t2 = M.new({"x", "y", "z"})
    T.eq(t1.root, t2.root, "same data → same root")
  end)
end)

-- ── Leaf hashes ──────────────────────────────────────────────────────────────

T.describe("merkle_tree: leaf hashes", function()
  T.it("leaf hashes are hashes of original data", function()
    local hash_fn = M.default_hash
    local items = {"foo", "bar", "baz"}
    local tree = M.new(items)
    for i, item in ipairs(items) do
      T.eq(tree.leaves[i], hash_fn(item), "leaf " .. i .. " hash correct")
    end
  end)

  T.it("custom hash function is used", function()
    local called = {}
    local function my_hash(data)
      called[#called + 1] = data
      return M.default_hash("custom:" .. data)
    end
    local tree = M.new({"a", "b"}, { hash_fn = my_hash })
    T.ok(#called >= 2, "custom hash called at least for leaves")
    T.eq(tree.leaves[1], my_hash("a"), "leaf1 uses custom hash")
    T.eq(tree.leaves[2], my_hash("b"), "leaf2 uses custom hash")
  end)
end)

-- ── Proof generation and verification ────────────────────────────────────────

T.describe("merkle_tree: proofs", function()
  T.it("proof for single leaf verifies", function()
    local tree = M.new({"only"})
    local proof = tree:proof(1)
    T.ok(proof ~= nil, "proof generated")
    T.eq(proof.index, 1, "proof index correct")
    T.eq(proof.root, tree.root, "proof root matches tree root")
    local ok = M.verify(proof, tree.leaves[1])
    T.ok(ok, "single-leaf proof verifies")
  end)

  T.it("proof verifies for each leaf (2 leaves)", function()
    local tree = M.new({"left", "right"})
    for i = 1, 2 do
      local proof = tree:proof(i)
      T.ok(proof ~= nil, "proof " .. i .. " generated")
      local ok = M.verify(proof, tree.leaves[i])
      T.ok(ok, "proof " .. i .. " verifies")
    end
  end)

  T.it("proof verifies for each leaf (4 leaves)", function()
    local tree = M.new({"a", "b", "c", "d"})
    for i = 1, 4 do
      local proof = tree:proof(i)
      local ok = M.verify(proof, tree.leaves[i])
      T.ok(ok, "proof " .. i .. " verifies for 4-leaf tree")
    end
  end)

  T.it("proof verifies for each leaf (8 leaves)", function()
    local tree = M.new(make_items(8))
    for i = 1, 8 do
      local proof = tree:proof(i)
      local ok = M.verify(proof, tree.leaves[i])
      T.ok(ok, "proof " .. i .. " verifies for 8-leaf tree")
    end
  end)

  T.it("proof verifies for each leaf (7 leaves)", function()
    local tree = M.new(make_items(7))
    for i = 1, 7 do
      local proof = tree:proof(i)
      local ok = M.verify(proof, tree.leaves[i])
      T.ok(ok, "proof " .. i .. " verifies for 7-leaf tree")
    end
  end)

  T.it("tampered leaf fails verification", function()
    local tree = M.new({"a", "b", "c", "d"})
    local proof = tree:proof(2)
    local fake_leaf = M.default_hash("tampered")
    local ok = M.verify(proof, fake_leaf)
    T.ok(not ok, "tampered leaf fails verification")
  end)

  T.it("tampered proof path fails verification", function()
    local tree = M.new({"a", "b", "c", "d"})
    local proof = tree:proof(1)
    -- Tamper with a sibling hash in the path
    if proof.path[1] then
      proof.path[1].hash = M.default_hash("tampered_sibling")
    end
    local ok = M.verify(proof, tree.leaves[1])
    T.ok(not ok, "tampered proof path fails verification")
  end)

  T.it("proof path length equals tree depth minus 1", function()
    for _, n in ipairs({2, 4, 8}) do
      local tree = M.new(make_items(n))
      local proof = tree:proof(1)
      T.eq(#proof.path, tree.depth - 1, "path length for n=" .. n)
    end
  end)

  T.it("proof from wrong root fails", function()
    local tree1 = M.new({"a", "b"})
    local tree2 = M.new({"x", "y"})
    -- Use tree1's proof but tree2's leaf
    local proof = tree1:proof(1)
    local ok = M.verify(proof, tree2.leaves[1])
    T.ok(not ok, "cross-tree proof fails")
  end)
end)

-- ── update / update_root ──────────────────────────────────────────────────────

T.describe("merkle_tree: update", function()
  T.it("update_root changes root when leaf changes", function()
    local tree = M.new({"a", "b", "c", "d"})
    local new_root = tree:update_root(2, "B")
    T.neq(new_root, tree.root, "root changes after update")
    T.eq(type(new_root), "string", "new root is a string")
  end)

  T.it("update_root same data → same root", function()
    local tree = M.new({"a", "b", "c", "d"})
    local new_root = tree:update_root(2, "b")
    T.eq(new_root, tree.root, "same data → same root")
  end)

  T.it("update returns a new tree with changed leaf", function()
    local tree = M.new({"a", "b", "c", "d"})
    local new_tree, err = tree:update(2, "B")
    T.ok(new_tree ~= nil, "new tree created")
    T.eq(err, nil, "no error")
    T.neq(new_tree.root, tree.root, "root changes")
    T.eq(new_tree.leaves[2], M.default_hash("B"), "leaf 2 updated")
    -- Other leaves unchanged
    T.eq(new_tree.leaves[1], tree.leaves[1], "leaf 1 unchanged")
    T.eq(new_tree.leaves[3], tree.leaves[3], "leaf 3 unchanged")
  end)

  T.it("update_root is consistent with update", function()
    local tree = M.new({"a", "b", "c", "d"})
    local new_root = tree:update_root(3, "C_new")
    local new_tree = tree:update(3, "C_new")
    T.eq(new_root, new_tree.root, "update_root matches update().root")
  end)

  T.it("updated leaf proof verifies against new root", function()
    local tree = M.new({"a", "b", "c", "d"})
    local new_tree = tree:update(2, "B")
    local proof = new_tree:proof(2)
    local ok = M.verify(proof, new_tree.leaves[2])
    T.ok(ok, "updated leaf proof verifies")
  end)

  T.it("update returns error on out-of-range index", function()
    local tree = M.new({"a", "b"})
    local t, err = tree:update(5, "x")
    T.eq(t, nil, "nil on bad index")
    T.ok(err ~= nil, "error set")
  end)
end)

-- ── diff ──────────────────────────────────────────────────────────────────────

T.describe("merkle_tree: diff", function()
  T.it("equal trees have no diff", function()
    local t1 = M.new({"a", "b", "c", "d"})
    local t2 = M.new({"a", "b", "c", "d"})
    local changed = M.diff(t1, t2)
    T.eq(#changed, 0, "no changed indices for identical trees")
  end)

  T.it("detects single changed leaf", function()
    local t1 = M.new({"a", "b", "c", "d"})
    local t2 = t1:update(3, "C")
    local changed = M.diff(t1, t2)
    T.eq(#changed, 1, "one changed index")
    T.eq(changed[1], 3, "index 3 changed")
  end)

  T.it("detects multiple changed leaves", function()
    local t1 = M.new({"a", "b", "c", "d"})
    local t2 = t1:update(1, "A"):update(4, "D")
    local changed = M.diff(t1, t2)
    -- Sort for determinism
    table.sort(changed)
    T.eq(#changed, 2, "two changed indices")
    T.eq(changed[1], 1, "index 1 changed")
    T.eq(changed[2], 4, "index 4 changed")
  end)

  T.it("detects all leaves changed", function()
    local t1 = M.new({"a", "b", "c", "d"})
    local t2 = M.new({"A", "B", "C", "D"})
    local changed = M.diff(t1, t2)
    T.eq(#changed, 4, "all four leaves changed")
  end)
end)

-- ── concat ────────────────────────────────────────────────────────────────────

T.describe("merkle_tree: concat", function()
  T.it("concat two trees has correct leaf count", function()
    local t1 = M.new({"a", "b"})
    local t2 = M.new({"c", "d", "e"})
    local t3 = M.concat(t1, t2)
    T.eq(#t3.leaves, 5, "combined leaf count")
  end)

  T.it("concat preserves leaf order", function()
    local t1 = M.new({"a", "b"})
    local t2 = M.new({"c", "d"})
    local t3 = M.concat(t1, t2)
    T.eq(t3.leaves[1], t1.leaves[1], "leaf 1 from t1")
    T.eq(t3.leaves[2], t1.leaves[2], "leaf 2 from t1")
    T.eq(t3.leaves[3], t2.leaves[1], "leaf 3 from t2")
    T.eq(t3.leaves[4], t2.leaves[2], "leaf 4 from t2")
  end)

  T.it("concat result proofs verify", function()
    local t1 = M.new({"a", "b"})
    local t2 = M.new({"c", "d"})
    local t3 = M.concat(t1, t2)
    for i = 1, 4 do
      local proof = t3:proof(i)
      local ok = M.verify(proof, t3.leaves[i])
      T.ok(ok, "concat proof " .. i .. " verifies")
    end
  end)

  T.it("concat is not same as separate trees", function()
    local t1 = M.new({"a", "b"})
    local t2 = M.new({"c", "d"})
    local t3 = M.concat(t1, t2)
    -- The combined tree has a different root than either part
    T.neq(t3.root, t1.root, "concat root != t1 root")
    T.neq(t3.root, t2.root, "concat root != t2 root")
  end)

  T.it("concat single + single", function()
    local t1 = M.new({"x"})
    local t2 = M.new({"y"})
    local t3 = M.concat(t1, t2)
    T.eq(#t3.leaves, 2, "two leaves")
    local expected = M.new({"x", "y"})
    T.eq(t3.root, expected.root, "matches direct construction")
  end)
end)

-- ── Sparse Merkle Tree ────────────────────────────────────────────────────────

T.describe("merkle_tree: sparse tree", function()
  T.it("creates sparse tree with zero root", function()
    local st = M.sparse(4)
    T.ok(st ~= nil, "sparse tree created")
    T.ok(type(st.root) == "string", "root is a string")
    -- Empty tree root is deterministic
    local st2 = M.sparse(4)
    T.eq(st.root, st2.root, "empty sparse trees have same root")
  end)

  T.it("set changes root", function()
    local st = M.sparse(4)
    local empty_root = st.root
    local key_hash = M.default_hash("key1")
    local val_hash = M.default_hash("val1")
    local st2 = st:set(key_hash, val_hash)
    T.neq(st2.root, empty_root, "root changes after set")
    -- Original tree is unmodified (non-mutating)
    T.eq(st.root, empty_root, "original tree root unchanged")
  end)

  T.it("set same key twice with different values changes root", function()
    local st = M.sparse(4)
    local key_hash = M.default_hash("key")
    local st1 = st:set(key_hash, M.default_hash("val1"))
    local st2 = st:set(key_hash, M.default_hash("val2"))
    T.neq(st1.root, st2.root, "different values → different roots")
  end)

  T.it("set same key+value twice → same root", function()
    local st = M.sparse(4)
    local key_hash = M.default_hash("key")
    local val_hash = M.default_hash("val")
    local st1 = st:set(key_hash, val_hash)
    local st2 = st:set(key_hash, val_hash)
    T.eq(st1.root, st2.root, "idempotent set → same root")
  end)

  T.it("sparse proof verifies for set key", function()
    local st = M.sparse(8)
    local key_hash = M.default_hash("mykey")
    local val_hash = M.default_hash("myvalue")
    local st2 = st:set(key_hash, val_hash)
    local proof = st2:get_proof(key_hash)
    T.ok(proof ~= nil, "proof generated")
    T.eq(proof.root, st2.root, "proof root matches tree root")
    T.eq(#proof.path, 8, "proof path length equals depth")
    local ok = M.verify_sparse(proof, key_hash, val_hash)
    T.ok(ok, "sparse proof verifies")
  end)

  T.it("sparse proof fails for wrong value", function()
    local st = M.sparse(8)
    local key_hash = M.default_hash("mykey")
    local val_hash = M.default_hash("myvalue")
    local st2 = st:set(key_hash, val_hash)
    local proof = st2:get_proof(key_hash)
    local wrong_val = M.default_hash("wrongvalue")
    local ok = M.verify_sparse(proof, key_hash, wrong_val)
    T.ok(not ok, "wrong value fails sparse proof")
  end)

  T.it("sparse proof for empty key (absent) verifies with zero value", function()
    local st = M.sparse(8)
    local key_hash = M.default_hash("absent_key")
    local zero_val = M.default_hash("")  -- the zero/empty leaf hash
    local proof = st:get_proof(key_hash)
    local ok = M.verify_sparse(proof, key_hash, zero_val)
    T.ok(ok, "absent key proof verifies with zero value")
  end)

  T.it("multiple keys in sparse tree", function()
    -- Use depth=32 so keys with short divergence still separate correctly.
    -- M.default_hash produces 8-char hex = 32-bit keys; depth=32 uses all bits.
    local st = M.sparse(32)
    local k1 = M.default_hash("k1")
    local k2 = M.default_hash("k2")
    local v1 = M.default_hash("v1")
    local v2 = M.default_hash("v2")
    local st2 = st:set(k1, v1):set(k2, v2)
    -- Both proofs verify
    local p1 = st2:get_proof(k1)
    local p2 = st2:get_proof(k2)
    T.ok(M.verify_sparse(p1, k1, v1), "k1 proof verifies")
    T.ok(M.verify_sparse(p2, k2, v2), "k2 proof verifies")
    -- Cross-proof fails
    T.ok(not M.verify_sparse(p1, k1, v2), "wrong value fails for k1")
  end)

  T.it("sparse error on invalid depth", function()
    local st, err = M.sparse(0)
    T.eq(st, nil, "nil on depth 0")
    T.ok(err ~= nil, "error set")
  end)
end)

-- ── Default hash properties ───────────────────────────────────────────────────

T.describe("merkle_tree: default_hash", function()
  T.it("returns 8-char hex string", function()
    local h = M.default_hash("hello")
    T.eq(type(h), "string", "returns string")
    T.eq(#h, 8, "8 hex chars")
    T.ok(h:match("^[0-9a-f]+$"), "lowercase hex")
  end)

  T.it("different inputs produce different hashes", function()
    local h1 = M.default_hash("foo")
    local h2 = M.default_hash("bar")
    T.neq(h1, h2, "different inputs → different hashes")
  end)

  T.it("same input always produces same hash", function()
    local h1 = M.default_hash("consistent")
    local h2 = M.default_hash("consistent")
    T.eq(h1, h2, "deterministic hash")
  end)

  T.it("empty string produces a valid hash", function()
    local h = M.default_hash("")
    T.eq(type(h), "string", "empty string hashes OK")
    T.eq(#h, 8, "8 hex chars")
  end)
end)
