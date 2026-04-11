-- lib/hash/xxhash/xxhash_test.lua
-- Tests for xxHash32 and xxHash64 (LuaJIT FFI tier for 64-bit).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local xxh = require("lib.hash.xxhash")

-- ── xxHash32 ──────────────────────────────────────────────────────────────────

T.describe("xxh32 — known vectors (seed=0)", function()
	-- Official xxHash32 test vectors, verified against the reference C impl.
	T.it("empty string → 0x02CC5D05", function()
		T.eq(xxh.xxh32("", 0), 0x02CC5D05)
	end)
	T.it("\"a\" → 0x550D7456", function()
		T.eq(xxh.xxh32("a", 0), 0x550D7456)
	end)
	T.it("\"abc\" → 0x32D153FF", function()
		T.eq(xxh.xxh32("abc", 0), 0x32D153FF)
	end)
	T.it("\"message digest\" → consistent value", function()
		T.eq(xxh.xxh32("message digest", 0), 0x7C948494)
	end)
	T.it("26-letter lowercase alphabet → consistent value", function()
		T.eq(xxh.xxh32("abcdefghijklmnopqrstuvwxyz", 0), 0x63A14D5F)
	end)
end)

T.describe("xxh32 — seeded", function()
	T.it("empty string, seed=42 → consistent value", function()
		T.eq(xxh.xxh32("", 42), 0xD5BE6EB8)
	end)
	T.it("non-zero seed changes result", function()
		T.neq(xxh.xxh32("test", 0), xxh.xxh32("test", 1))
	end)
	T.it("seed=0 is the default", function()
		T.eq(xxh.xxh32("abc"), xxh.xxh32("abc", 0))
	end)
end)

T.describe("xxh32 — input lengths", function()
	T.it("1 byte", function()
		T.ok(type(xxh.xxh32("x", 0)) == "number")
	end)
	T.it("15 bytes (just under 16-byte stripe threshold)", function()
		T.ok(type(xxh.xxh32(("x"):rep(15), 0)) == "number")
	end)
	T.it("16 bytes (exactly one stripe)", function()
		local v15 = xxh.xxh32(("x"):rep(15), 0)
		local v16 = xxh.xxh32(("x"):rep(16), 0)
		T.neq(v15, v16)  -- different lengths → different hash
	end)
	T.it("17 bytes (stripe + 1)", function()
		T.ok(type(xxh.xxh32(("x"):rep(17), 0)) == "number")
	end)
	T.it("32 bytes (two stripes)", function()
		T.ok(type(xxh.xxh32(("x"):rep(32), 0)) == "number")
	end)
	T.it("100 bytes", function()
		T.ok(type(xxh.xxh32(("x"):rep(100), 0)) == "number")
	end)
	T.it("returns unsigned (≥ 0)", function()
		T.ok(xxh.xxh32("hello", 0) >= 0)
		T.ok(xxh.xxh32(("z"):rep(100), 0) >= 0)
	end)
end)

T.describe("xxh32 — collision resistance", function()
	T.it("different strings give different hashes", function()
		T.neq(xxh.xxh32("foo", 0), xxh.xxh32("bar", 0))
		T.neq(xxh.xxh32("hello", 0), xxh.xxh32("world", 0))
	end)
	T.it("appending bytes changes the hash", function()
		T.neq(xxh.xxh32("abc", 0), xxh.xxh32("abcd", 0))
	end)
	T.it("deterministic — same input always gives same output", function()
		local s = "deterministic test string"
		T.eq(xxh.xxh32(s, 0), xxh.xxh32(s, 0))
		T.eq(xxh.xxh32(s, 7), xxh.xxh32(s, 7))
	end)
	T.it("binary data with null bytes", function()
		local a = "\0\1\2\3"
		local b = "\0\1\2\4"
		T.neq(xxh.xxh32(a, 0), xxh.xxh32(b, 0))
	end)
end)

-- ── xxHash32 streaming ────────────────────────────────────────────────────────

T.describe("xxh32 streaming", function()
	T.it("single chunk matches one-shot", function()
		local h = xxh.new32(0)
		h:update("abc")
		T.eq(h:digest(), xxh.xxh32("abc", 0))
	end)
	T.it("multi-chunk matches one-shot", function()
		local h = xxh.new32(0)
		h:update("a")
		h:update("b")
		h:update("c")
		T.eq(h:digest(), xxh.xxh32("abc", 0))
	end)
	T.it("empty stream matches one-shot empty", function()
		local h = xxh.new32(0)
		T.eq(h:digest(), xxh.xxh32("", 0))
	end)
	T.it("can call digest multiple times (non-destructive)", function()
		local h = xxh.new32(0)
		h:update("test")
		local d1 = h:digest()
		local d2 = h:digest()
		T.eq(d1, d2)
	end)
	T.it("reset clears state", function()
		local h = xxh.new32(0)
		h:update("some data")
		h:reset(0)
		T.eq(h:digest(), xxh.xxh32("", 0))
	end)
	T.it("seed is respected in streaming", function()
		local h = xxh.new32(42)
		T.eq(h:digest(), xxh.xxh32("", 42))
	end)
	T.it("32-byte chunk (crosses stripe boundary)", function()
		local s = ("abcdefghijklmnop"):rep(2)  -- 32 bytes
		local h = xxh.new32(0)
		h:update(s:sub(1, 16))
		h:update(s:sub(17, 32))
		T.eq(h:digest(), xxh.xxh32(s, 0))
	end)
	T.it("large input streaming consistency", function()
		local s = ("Hello, World! "):rep(10)
		local h = xxh.new32(0)
		for i = 1, #s, 7 do
			h:update(s:sub(i, i + 6))
		end
		T.eq(h:digest(), xxh.xxh32(s, 0))
	end)
end)

-- ── xxHash64 ──────────────────────────────────────────────────────────────────

T.describe("xxh64 — known vectors (seed=0)", function()
	-- Official xxHash64 test vectors (spec-verified).
	T.it("empty string → ef46db3751d8e999", function()
		if not xxh.xxh64 then T.skip("xxh64 requires FFI") end
		T.eq(xxh.xxh64("", 0), "ef46db3751d8e999")
	end)
	T.it("\"a\" → d24ec4f1a98c6e5b", function()
		if not xxh.xxh64 then T.skip("xxh64 requires FFI") end
		T.eq(xxh.xxh64("a", 0), "d24ec4f1a98c6e5b")
	end)
	T.it("\"abc\" → 44bc2cf5ad770999", function()
		if not xxh.xxh64 then T.skip("xxh64 requires FFI") end
		T.eq(xxh.xxh64("abc", 0), "44bc2cf5ad770999")
	end)
	T.it("\"message digest\" → consistent value", function()
		if not xxh.xxh64 then T.skip("xxh64 requires FFI") end
		T.eq(xxh.xxh64("message digest", 0), "066ed728fceeb3be")
	end)
	T.it("seed=42 empty string → consistent value", function()
		if not xxh.xxh64 then T.skip("xxh64 requires FFI") end
		T.eq(xxh.xxh64("", 42), "98b1582b0977e704")
	end)
	T.it("returns 16-char lowercase hex string", function()
		if not xxh.xxh64 then T.skip("xxh64 requires FFI") end
		local r = xxh.xxh64("test", 0)
		T.ok(type(r) == "string")
		T.eq(#r, 16)
		T.ok(r:match("^[0-9a-f]+$") ~= nil)
	end)
end)

T.describe("xxh64 streaming", function()
	T.it("single chunk matches one-shot", function()
		if not xxh.new64 then T.skip("xxh64 requires FFI") end
		local h = xxh.new64(0)
		h:update("abc")
		T.eq(h:digest(), xxh.xxh64("abc", 0))
	end)
	T.it("multi-chunk matches one-shot", function()
		if not xxh.new64 then T.skip("xxh64 requires FFI") end
		local h = xxh.new64(0)
		h:update("a"); h:update("b"); h:update("c")
		T.eq(h:digest(), xxh.xxh64("abc", 0))
	end)
	T.it("empty stream matches one-shot empty", function()
		if not xxh.new64 then T.skip("xxh64 requires FFI") end
		local h = xxh.new64(0)
		T.eq(h:digest(), xxh.xxh64("", 0))
	end)
	T.it("32-byte boundary streaming consistency", function()
		if not xxh.new64 then T.skip("xxh64 requires FFI") end
		local s = ("abcdefghijklmnopqrstuvwxyz012345"):rep(2)  -- 64 bytes
		local h = xxh.new64(0)
		h:update(s:sub(1, 33))
		h:update(s:sub(34))
		T.eq(h:digest(), xxh.xxh64(s, 0))
	end)
end)

-- ── Tier ──────────────────────────────────────────────────────────────────────

T.describe("tier", function()
	T.it("_tier is 'pure'", function()
		T.eq(xxh._tier, "pure")
	end)
end)
