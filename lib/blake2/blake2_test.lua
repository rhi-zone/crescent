if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local blake2 = require("lib.blake2")

-- RFC 7693 and official BLAKE2 test vectors.

T.describe("lib.blake2", function()

  T.describe("tier", function()
    T.it("_tier is 'pure'", function()
      T.eq(blake2._tier, "pure")
    end)
  end)

  -- ---------------------------------------------------------------------------
  -- BLAKE2b
  -- ---------------------------------------------------------------------------
  T.describe("blake2b", function()

    T.describe("RFC 7693 vectors (unkeyed)", function()
      T.it("b('') matches RFC 7693 Appendix A", function()
        T.eq(blake2.b(""),
          "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419" ..
          "d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
      end)

      T.it("b('abc') matches RFC 7693 Appendix A", function()
        T.eq(blake2.b("abc"),
          "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1" ..
          "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
      end)

      T.it("b('The quick brown fox jumps over the lazy dog') matches known vector", function()
        T.eq(blake2.b("The quick brown fox jumps over the lazy dog"),
          "a8add4bdddfd93e4877d2746e62817b116364a1fa7bc148d95090bc7333b3673" ..
          "f82401cf7aa2e4cb1ecd90296e3f14cb5413f8ed77be73045b13914cdcd6a918")
      end)
    end)

    T.describe("output length", function()
      T.it("default output is 128 hex chars (64 bytes)", function()
        T.eq(#blake2.b("test"), 128)
      end)

      T.it("hash_len=32 produces 64 hex chars", function()
        local h = blake2.b("test", {hash_len = 32})
        T.eq(#h, 64)
        T.ok(h:match("^[0-9a-f]+$") ~= nil)
      end)

      T.it("hash_len=1 produces 2 hex chars", function()
        local h = blake2.b("test", {hash_len = 1})
        T.eq(#h, 2)
      end)

      T.it("hash_len=64 (max) produces 128 hex chars", function()
        local h = blake2.b("test", {hash_len = 64})
        T.eq(#h, 128)
      end)

      T.it("hash_len=20 produces 40 hex chars", function()
        local h = blake2.b("test", {hash_len = 20})
        T.eq(#h, 40)
      end)
    end)

    T.describe("b_binary", function()
      T.it("returns raw bytes of correct length", function()
        local raw = blake2.b_binary("abc")
        T.eq(type(raw), "string")
        T.eq(#raw, 64)
      end)

      T.it("b_binary with hash_len=32 returns 32 bytes", function()
        local raw = blake2.b_binary("abc", {hash_len = 32})
        T.eq(#raw, 32)
      end)

      T.it("b_binary and b agree — hex of binary matches b output", function()
        local raw = blake2.b_binary("abc")
        local hex = blake2.b("abc")
        local reconstructed = {}
        for i = 1, #raw do
          reconstructed[i] = string.format("%02x", string.byte(raw, i))
        end
        T.eq(table.concat(reconstructed), hex)
      end)
    end)

    T.describe("keyed hashing", function()
      T.it("keyed hash differs from unkeyed", function()
        local keyed   = blake2.b("abc", {key = "secretkey"})
        local unkeyed = blake2.b("abc")
        T.neq(keyed, unkeyed)
      end)

      T.it("same key produces same hash (deterministic)", function()
        local a = blake2.b("hello", {key = "mykey"})
        local b = blake2.b("hello", {key = "mykey"})
        T.eq(a, b)
      end)

      T.it("different keys produce different hashes", function()
        local h1 = blake2.b("hello", {key = "key1"})
        local h2 = blake2.b("hello", {key = "key2"})
        T.neq(h1, h2)
      end)

      T.it("64-byte (max) key is accepted", function()
        local maxkey = string.rep("k", 64)
        local h = blake2.b("msg", {key = maxkey})
        T.ok(type(h) == "string" and #h == 128)
      end)
    end)

    T.describe("input lengths", function()
      T.it("exactly 128 bytes (one full block) works", function()
        local h = blake2.b(string.rep("a", 128))
        T.eq(#h, 128)
      end)

      T.it("129 bytes (one full + partial block) works", function()
        local h = blake2.b(string.rep("a", 129))
        T.eq(#h, 128)
      end)

      T.it("256 bytes (two full blocks) works", function()
        local h = blake2.b(string.rep("a", 256))
        T.eq(#h, 128)
      end)

      T.it("different lengths produce different hashes", function()
        local h1 = blake2.b(string.rep("a", 127))
        local h2 = blake2.b(string.rep("a", 128))
        local h3 = blake2.b(string.rep("a", 129))
        T.neq(h1, h2)
        T.neq(h2, h3)
      end)

      T.it("single byte input works", function()
        local h = blake2.b("x")
        T.eq(#h, 128)
      end)
    end)

    T.describe("determinism and collision resistance", function()
      T.it("same input always produces same output", function()
        local a = blake2.b("some input")
        local b = blake2.b("some input")
        T.eq(a, b)
      end)

      T.it("different inputs produce different outputs", function()
        local h1 = blake2.b("input one")
        local h2 = blake2.b("input two")
        T.neq(h1, h2)
      end)

      T.it("output is lowercase hex", function()
        local h = blake2.b("test")
        T.ok(h:match("^[0-9a-f]+$") ~= nil)
      end)
    end)

    T.describe("error handling", function()
      T.it("non-string input returns nil, errmsg", function()
        local r, e = blake2.b(42)
        T.eq(r, nil)
        T.ok(type(e) == "string")
      end)

      T.it("hash_len=0 returns nil, errmsg", function()
        local r, e = blake2.b("x", {hash_len = 0})
        T.eq(r, nil)
        T.ok(type(e) == "string")
      end)

      T.it("hash_len=65 returns nil, errmsg", function()
        local r, e = blake2.b("x", {hash_len = 65})
        T.eq(r, nil)
        T.ok(type(e) == "string")
      end)

      T.it("key longer than 64 bytes returns nil, errmsg", function()
        local r, e = blake2.b("x", {key = string.rep("k", 65)})
        T.eq(r, nil)
        T.ok(type(e) == "string")
      end)
    end)

  end)

  -- ---------------------------------------------------------------------------
  -- BLAKE2s
  -- ---------------------------------------------------------------------------
  T.describe("blake2s", function()

    T.describe("RFC 7693 vectors (unkeyed)", function()
      T.it("s('') matches RFC 7693 Appendix A", function()
        T.eq(blake2.s(""),
          "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9")
      end)

      T.it("s('abc') matches RFC 7693 Appendix A", function()
        T.eq(blake2.s("abc"),
          "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982")
      end)

      T.it("s('The quick brown fox jumps over the lazy dog') matches known vector", function()
        T.eq(blake2.s("The quick brown fox jumps over the lazy dog"),
          "606beeec743ccbeff6cbcdf5d5302aa855c256c29b88c8ed331ea1a6bf3c8812")
      end)
    end)

    T.describe("output length", function()
      T.it("default output is 64 hex chars (32 bytes)", function()
        T.eq(#blake2.s("test"), 64)
      end)

      T.it("hash_len=16 produces 32 hex chars", function()
        local h = blake2.s("test", {hash_len = 16})
        T.eq(#h, 32)
        T.ok(h:match("^[0-9a-f]+$") ~= nil)
      end)

      T.it("hash_len=1 produces 2 hex chars", function()
        local h = blake2.s("test", {hash_len = 1})
        T.eq(#h, 2)
      end)

      T.it("hash_len=32 (max) produces 64 hex chars", function()
        local h = blake2.s("test", {hash_len = 32})
        T.eq(#h, 64)
      end)
    end)

    T.describe("s_binary", function()
      T.it("returns raw bytes of correct length", function()
        local raw = blake2.s_binary("abc")
        T.eq(type(raw), "string")
        T.eq(#raw, 32)
      end)

      T.it("s_binary with hash_len=16 returns 16 bytes", function()
        local raw = blake2.s_binary("abc", {hash_len = 16})
        T.eq(#raw, 16)
      end)

      T.it("s_binary and s agree — hex of binary matches s output", function()
        local raw = blake2.s_binary("abc")
        local hex = blake2.s("abc")
        local reconstructed = {}
        for i = 1, #raw do
          reconstructed[i] = string.format("%02x", string.byte(raw, i))
        end
        T.eq(table.concat(reconstructed), hex)
      end)
    end)

    T.describe("keyed hashing", function()
      T.it("keyed hash differs from unkeyed", function()
        local keyed   = blake2.s("abc", {key = "secretkey"})
        local unkeyed = blake2.s("abc")
        T.neq(keyed, unkeyed)
      end)

      T.it("same key produces same hash (deterministic)", function()
        local a = blake2.s("hello", {key = "mykey"})
        local b = blake2.s("hello", {key = "mykey"})
        T.eq(a, b)
      end)

      T.it("different keys produce different hashes", function()
        local h1 = blake2.s("hello", {key = "key1"})
        local h2 = blake2.s("hello", {key = "key2"})
        T.neq(h1, h2)
      end)

      T.it("32-byte (max) key is accepted", function()
        local maxkey = string.rep("k", 32)
        local h = blake2.s("msg", {key = maxkey})
        T.ok(type(h) == "string" and #h == 64)
      end)
    end)

    T.describe("input lengths", function()
      T.it("exactly 64 bytes (one full block) works", function()
        local h = blake2.s(string.rep("a", 64))
        T.eq(#h, 64)
      end)

      T.it("65 bytes (one full + partial block) works", function()
        local h = blake2.s(string.rep("a", 65))
        T.eq(#h, 64)
      end)

      T.it("128 bytes (two full blocks) works", function()
        local h = blake2.s(string.rep("a", 128))
        T.eq(#h, 64)
      end)

      T.it("different lengths produce different hashes", function()
        local h1 = blake2.s(string.rep("a", 63))
        local h2 = blake2.s(string.rep("a", 64))
        local h3 = blake2.s(string.rep("a", 65))
        T.neq(h1, h2)
        T.neq(h2, h3)
      end)
    end)

    T.describe("determinism and collision resistance", function()
      T.it("same input always produces same output", function()
        local a = blake2.s("some input")
        local b = blake2.s("some input")
        T.eq(a, b)
      end)

      T.it("different inputs produce different outputs", function()
        local h1 = blake2.s("input one")
        local h2 = blake2.s("input two")
        T.neq(h1, h2)
      end)

      T.it("output is lowercase hex", function()
        local h = blake2.s("test")
        T.ok(h:match("^[0-9a-f]+$") ~= nil)
      end)
    end)

    T.describe("error handling", function()
      T.it("non-string input returns nil, errmsg", function()
        local r, e = blake2.s(42)
        T.eq(r, nil)
        T.ok(type(e) == "string")
      end)

      T.it("hash_len=0 returns nil, errmsg", function()
        local r, e = blake2.s("x", {hash_len = 0})
        T.eq(r, nil)
        T.ok(type(e) == "string")
      end)

      T.it("hash_len=33 returns nil, errmsg", function()
        local r, e = blake2.s("x", {hash_len = 33})
        T.eq(r, nil)
        T.ok(type(e) == "string")
      end)

      T.it("key longer than 32 bytes returns nil, errmsg", function()
        local r, e = blake2.s("x", {key = string.rep("k", 33)})
        T.eq(r, nil)
        T.ok(type(e) == "string")
      end)
    end)

  end)

  -- ---------------------------------------------------------------------------
  -- Cross-variant properties
  -- ---------------------------------------------------------------------------
  T.describe("cross-variant properties", function()
    T.it("BLAKE2b and BLAKE2s produce different hashes for same input", function()
      local hb = blake2.b("test")
      local hs = blake2.s("test")
      -- They have different lengths anyway, but verify they don't share a prefix
      T.neq(hb:sub(1, 64), hs)
    end)

    T.it("BLAKE2b-256 (hash_len=32) and BLAKE2s-256 produce different values", function()
      local hb = blake2.b("test", {hash_len = 32})
      local hs = blake2.s("test", {hash_len = 32})
      T.neq(hb, hs)
    end)
  end)

end)
