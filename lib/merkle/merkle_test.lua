-- lib/merkle/merkle_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local merkle = require("lib.merkle")
local sha256_mod = require("lib.hash.sha256")
local sha256 = sha256_mod.sha256

-- Helper: hex_to_bytes for computing expected hashes inline.
local function hex_to_bytes(hex)
	return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

local function hash_leaf(data)
	return sha256("\x00" .. data)
end

local function hash_pair(l, r)
	return sha256("\x01" .. hex_to_bytes(l) .. hex_to_bytes(r))
end

-- ── Single leaf ───────────────────────────────────────────────────────────────

T.describe("single leaf", function()
	T.it("root equals H(\\x00 || data)", function()
		local tree = merkle.build({ "hello" })
		local expected = hash_leaf("hello")
		T.eq(tree:root(), expected)
		T.eq(#tree:root(), 64)
	end)

	T.it("size is 1, height is 0, node_count is 1", function()
		local tree = merkle.build({ "hello" })
		T.eq(tree:size(), 1)
		T.eq(tree:height(), 0)
		T.eq(tree:node_count(), 1)
	end)

	T.it("leaf_hash(1) matches root", function()
		local tree = merkle.build({ "hello" })
		T.eq(tree:leaf_hash(1), tree:root())
	end)

	T.it("proof is empty, verify returns true", function()
		local tree = merkle.build({ "hello" })
		local proof = tree:proof(1)
		T.eq(#proof, 0)
		T.ok(merkle.verify("hello", proof, tree:root()))
	end)
end)

-- ── Two leaves ────────────────────────────────────────────────────────────────

T.describe("two leaves", function()
	local blocks = { "alpha", "beta" }
	local h1 = hash_leaf("alpha")
	local h2 = hash_leaf("beta")
	local expected_root = hash_pair(h1, h2)

	T.it("root equals H(\\x01 || H(leaf1) || H(leaf2))", function()
		local tree = merkle.build(blocks)
		T.eq(tree:root(), expected_root)
	end)

	T.it("size=2, height=1, node_count=3", function()
		local tree = merkle.build(blocks)
		T.eq(tree:size(), 2)
		T.eq(tree:height(), 1)
		T.eq(tree:node_count(), 3)
	end)

	T.it("leaf_hash returns correct hashes", function()
		local tree = merkle.build(blocks)
		T.eq(tree:leaf_hash(1), h1)
		T.eq(tree:leaf_hash(2), h2)
	end)

	T.it("proof for leaf 1: sibling is right=h2", function()
		local tree = merkle.build(blocks)
		local proof = tree:proof(1)
		T.eq(#proof, 1)
		T.eq(proof[1].side, "right")
		T.eq(proof[1].hash, h2)
	end)

	T.it("proof for leaf 2: sibling is left=h1", function()
		local tree = merkle.build(blocks)
		local proof = tree:proof(2)
		T.eq(#proof, 1)
		T.eq(proof[1].side, "left")
		T.eq(proof[1].hash, h1)
	end)

	T.it("verify returns true for both leaves", function()
		local tree = merkle.build(blocks)
		T.ok(merkle.verify("alpha", tree:proof(1), tree:root()))
		T.ok(merkle.verify("beta",  tree:proof(2), tree:root()))
	end)
end)

-- ── Four leaves ───────────────────────────────────────────────────────────────

T.describe("four leaves", function()
	local blocks = { "a", "b", "c", "d" }
	local ha = hash_leaf("a")
	local hb = hash_leaf("b")
	local hc = hash_leaf("c")
	local hd = hash_leaf("d")
	local hab = hash_pair(ha, hb)
	local hcd = hash_pair(hc, hd)
	local expected_root = hash_pair(hab, hcd)

	T.it("root is correct", function()
		local tree = merkle.build(blocks)
		T.eq(tree:root(), expected_root)
	end)

	T.it("size=4, height=2, node_count=7", function()
		local tree = merkle.build(blocks)
		T.eq(tree:size(), 4)
		T.eq(tree:height(), 2)
		T.eq(tree:node_count(), 7)
	end)

	T.it("all proofs verify", function()
		local tree = merkle.build(blocks)
		local root = tree:root()
		for i = 1, 4 do
			T.ok(merkle.verify(blocks[i], tree:proof(i), root))
		end
	end)

	T.it("proof for leaf 1 has 2 steps", function()
		local tree = merkle.build(blocks)
		local proof = tree:proof(1)
		T.eq(#proof, 2)
		-- step 1: sibling of 'a' is 'b' (right)
		T.eq(proof[1].side, "right")
		T.eq(proof[1].hash, hb)
		-- step 2: sibling of hab is hcd (right)
		T.eq(proof[2].side, "right")
		T.eq(proof[2].hash, hcd)
	end)

	T.it("proof for leaf 3 has 2 steps", function()
		local tree = merkle.build(blocks)
		local proof = tree:proof(3)
		T.eq(#proof, 2)
		T.eq(proof[1].side, "right")
		T.eq(proof[1].hash, hd)
		T.eq(proof[2].side, "left")
		T.eq(proof[2].hash, hab)
	end)
end)

-- ── Odd leaf counts (last duplicated) ────────────────────────────────────────

T.describe("odd leaves", function()
	T.it("3 leaves: last leaf duplicated for padding", function()
		local blocks = { "x", "y", "z" }
		local hx = hash_leaf("x")
		local hy = hash_leaf("y")
		local hz = hash_leaf("z")
		local hxy = hash_pair(hx, hy)
		local hzz = hash_pair(hz, hz)  -- last duplicated
		local expected_root = hash_pair(hxy, hzz)
		local tree = merkle.build(blocks)
		T.eq(tree:root(), expected_root)
		T.eq(tree:size(), 3)
		T.eq(tree:height(), 2)
		T.eq(tree:node_count(), 7)
	end)

	T.it("3 leaves: all proofs verify", function()
		local blocks = { "x", "y", "z" }
		local tree = merkle.build(blocks)
		local root = tree:root()
		for i = 1, 3 do
			T.ok(merkle.verify(blocks[i], tree:proof(i), root))
		end
	end)

	T.it("5 leaves: root computed correctly and all proofs verify", function()
		local blocks = { "a", "b", "c", "d", "e" }
		-- padded to 8
		local ha = hash_leaf("a"); local hb = hash_leaf("b")
		local hc = hash_leaf("c"); local hd = hash_leaf("d")
		local he = hash_leaf("e")
		local hab = hash_pair(ha, hb)
		local hcd = hash_pair(hc, hd)
		local hee = hash_pair(he, he)
		local hhabcd = hash_pair(hab, hcd)
		-- padded 8: leaves are a b c d e e e e? No, only duplicate last once.
		-- Actually for 5 leaves padded to 8: positions 6,7,8 = he,he,he? No.
		-- The code duplicates leaf[n] for positions n+1..padded.
		-- For n=5, padded=8: leaf_hashes[6]=he, leaf_hashes[7]=he, leaf_hashes[8]=he
		local hef = hash_pair(he, he)
		local hgh = hash_pair(he, he)
		local hleft  = hash_pair(hab, hcd)
		local hright = hash_pair(hef, hgh)
		local expected_root = hash_pair(hleft, hright)
		local tree = merkle.build(blocks)
		T.eq(tree:root(), expected_root)
		T.eq(tree:size(), 5)
		T.eq(tree:height(), 3)
		T.eq(tree:node_count(), 15)
		local root = tree:root()
		for i = 1, 5 do
			T.ok(merkle.verify(blocks[i], tree:proof(i), root))
		end
	end)

	T.it("7 leaves: all proofs verify", function()
		local blocks = {}
		for i = 1, 7 do blocks[i] = "leaf" .. i end
		local tree = merkle.build(blocks)
		local root = tree:root()
		T.eq(tree:size(), 7)
		T.eq(tree:height(), 3)
		for i = 1, 7 do
			T.ok(merkle.verify(blocks[i], tree:proof(i), root))
		end
	end)
end)

-- ── Proof/verify failure cases ────────────────────────────────────────────────

T.describe("verify failure cases", function()
	local blocks = { "one", "two", "three", "four" }
	local tree = merkle.build(blocks)
	local root = tree:root()

	T.it("modified leaf fails verification", function()
		local proof = tree:proof(2)
		T.eq(merkle.verify("TAMPERED", proof, root), false)
	end)

	T.it("wrong root fails verification", function()
		local proof = tree:proof(1)
		local bad_root = ("a"):rep(64)
		T.eq(merkle.verify("one", proof, bad_root), false)
	end)

	T.it("wrong proof step fails verification", function()
		local proof = tree:proof(3)
		-- Corrupt the first step hash.
		local bad_proof = {}
		for i, step in ipairs(proof) do
			bad_proof[i] = { hash = step.hash, side = step.side }
		end
		bad_proof[1].hash = ("0"):rep(64)
		T.eq(merkle.verify("three", bad_proof, root), false)
	end)

	T.it("proof from different index fails for wrong leaf", function()
		local proof_for_1 = tree:proof(1)
		-- Using proof for leaf 1 to verify leaf 2.
		T.eq(merkle.verify("two", proof_for_1, root), false)
	end)
end)

-- ── update ────────────────────────────────────────────────────────────────────

T.describe("update", function()
	T.it("updating a leaf changes the root", function()
		local tree = merkle.build({ "a", "b", "c", "d" })
		local old_root = tree:root()
		local new_root = tree:update(2, "B")
		T.neq(new_root, old_root)
		T.eq(tree:root(), new_root)
	end)

	T.it("updated root matches freshly built tree", function()
		local blocks = { "a", "b", "c", "d" }
		local tree = merkle.build(blocks)
		tree:update(3, "C")
		local fresh = merkle.build({ "a", "b", "C", "d" })
		T.eq(tree:root(), fresh:root())
	end)

	T.it("proofs verify after update", function()
		local blocks = { "a", "b", "c", "d" }
		local tree = merkle.build(blocks)
		tree:update(1, "A")
		local root = tree:root()
		T.ok(merkle.verify("A", tree:proof(1), root))
		T.ok(merkle.verify("b", tree:proof(2), root))
		T.ok(merkle.verify("c", tree:proof(3), root))
		T.ok(merkle.verify("d", tree:proof(4), root))
	end)

	T.it("update last leaf in odd tree", function()
		local tree = merkle.build({ "p", "q", "r" })
		local new_root = tree:update(3, "R")
		T.eq(tree:root(), new_root)
		local fresh = merkle.build({ "p", "q", "R" })
		T.eq(new_root, fresh:root())
		-- proof for updated leaf verifies
		T.ok(merkle.verify("R", tree:proof(3), new_root))
	end)

	T.it("multiple sequential updates", function()
		local tree = merkle.build({ "a", "b", "c", "d" })
		tree:update(1, "A")
		tree:update(4, "D")
		local fresh = merkle.build({ "A", "b", "c", "D" })
		T.eq(tree:root(), fresh:root())
	end)
end)

-- ── build_from_hashes ─────────────────────────────────────────────────────────

T.describe("build_from_hashes", function()
	T.it("same result as build when given pre-hashed leaves", function()
		local blocks = { "alpha", "beta", "gamma", "delta" }
		local hashes = {}
		for i, b in ipairs(blocks) do
			hashes[i] = sha256("\x00" .. b)
		end
		local tree1 = merkle.build(blocks)
		local tree2 = merkle.build_from_hashes(hashes)
		T.eq(tree1:root(), tree2:root())
	end)

	T.it("size and height match build", function()
		local blocks = { "x", "y", "z" }
		local hashes = {}
		for i, b in ipairs(blocks) do hashes[i] = sha256("\x00" .. b) end
		local t1 = merkle.build(blocks)
		local t2 = merkle.build_from_hashes(hashes)
		T.eq(t1:size(), t2:size())
		T.eq(t1:height(), t2:height())
		T.eq(t1:node_count(), t2:node_count())
	end)
end)

-- ── size / height / node_count ────────────────────────────────────────────────

T.describe("tree dimensions", function()
	local cases = {
		{ n = 1,  h = 0, nc = 1  },
		{ n = 2,  h = 1, nc = 3  },
		{ n = 3,  h = 2, nc = 7  },
		{ n = 4,  h = 2, nc = 7  },
		{ n = 5,  h = 3, nc = 15 },
		{ n = 8,  h = 3, nc = 15 },
		{ n = 9,  h = 4, nc = 31 },
		{ n = 16, h = 4, nc = 31 },
	}
	for _, c in ipairs(cases) do
		T.it(("n=%d: height=%d, node_count=%d"):format(c.n, c.h, c.nc), function()
			local blocks = {}
			for i = 1, c.n do blocks[i] = tostring(i) end
			local tree = merkle.build(blocks)
			T.eq(tree:size(), c.n)
			T.eq(tree:height(), c.h)
			T.eq(tree:node_count(), c.nc)
		end)
	end
end)

-- ── serialize / deserialize ───────────────────────────────────────────────────

T.describe("serialize/deserialize", function()
	T.it("restored tree gives same root", function()
		local blocks = { "a", "b", "c", "d", "e" }
		local tree = merkle.build(blocks)
		local t = tree:serialize()
		local tree2 = merkle.deserialize(t)
		T.eq(tree2:root(), tree:root())
	end)

	T.it("restored tree gives same proofs", function()
		local blocks = { "a", "b", "c", "d" }
		local tree = merkle.build(blocks)
		local tree2 = merkle.deserialize(tree:serialize())
		for i = 1, 4 do
			local p1 = tree:proof(i)
			local p2 = tree2:proof(i)
			T.eq(#p1, #p2)
			for j = 1, #p1 do
				T.eq(p1[j].hash, p2[j].hash)
				T.eq(p1[j].side, p2[j].side)
			end
		end
	end)

	T.it("verify works on deserialized tree", function()
		local blocks = { "foo", "bar", "baz" }
		local tree = merkle.build(blocks)
		local tree2 = merkle.deserialize(tree:serialize())
		local root = tree2:root()
		for i = 1, 3 do
			T.ok(merkle.verify(blocks[i], tree2:proof(i), root))
		end
	end)

	T.it("size/height/node_count preserved", function()
		local blocks = { "a", "b", "c", "d", "e", "f", "g" }
		local tree = merkle.build(blocks)
		local tree2 = merkle.deserialize(tree:serialize())
		T.eq(tree2:size(), tree:size())
		T.eq(tree2:height(), tree:height())
		T.eq(tree2:node_count(), tree:node_count())
	end)
end)

-- ── _tier ────────────────────────────────────────────────────────────────────

T.describe("metadata", function()
	T.it("_tier is 'pure'", function()
		T.eq(merkle._tier, "pure")
	end)
end)

-- ── Large tree ────────────────────────────────────────────────────────────────

T.describe("large tree (100 leaves)", function()
	T.it("all 100 proofs verify", function()
		local blocks = {}
		for i = 1, 100 do blocks[i] = "block-" .. i end
		local tree = merkle.build(blocks)
		local root = tree:root()
		T.eq(tree:size(), 100)
		T.eq(tree:height(), 7)  -- 2^7 = 128 >= 100
		T.eq(tree:node_count(), 255)
		for i = 1, 100 do
			T.ok(merkle.verify(blocks[i], tree:proof(i), root))
		end
	end)

	T.it("100-leaf root matches build_from_hashes", function()
		local blocks = {}
		local hashes = {}
		for i = 1, 100 do
			blocks[i] = "block-" .. i
			hashes[i] = sha256("\x00" .. blocks[i])
		end
		local t1 = merkle.build(blocks)
		local t2 = merkle.build_from_hashes(hashes)
		T.eq(t1:root(), t2:root())
	end)
end)

-- ── leaf_hash out-of-range ───────────────────────────────────────────────────

T.describe("error handling", function()
	T.it("leaf_hash returns nil for out-of-range index", function()
		local tree = merkle.build({ "a", "b" })
		local h, err = tree:leaf_hash(0)
		T.eq(h, nil)
		T.ok(err ~= nil)
		local h2, err2 = tree:leaf_hash(3)
		T.eq(h2, nil)
		T.ok(err2 ~= nil)
	end)

	T.it("proof returns nil for out-of-range index", function()
		local tree = merkle.build({ "a", "b" })
		local p, err = tree:proof(0)
		T.eq(p, nil)
		T.ok(err ~= nil)
	end)

	T.it("update returns nil for out-of-range index", function()
		local tree = merkle.build({ "a", "b" })
		local r, err = tree:update(5, "x")
		T.eq(r, nil)
		T.ok(err ~= nil)
	end)

	T.it("build returns nil for empty blocks", function()
		local t, err = merkle.build({})
		T.eq(t, nil)
		T.ok(err ~= nil)
	end)
end)
