if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local S = require("lib.siphash")

-- Reference key: bytes 0x00..0x0f (16 bytes)
local KEY = string.char(
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
  0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
)

-- Reference vectors from https://github.com/veorq/SipHash/blob/master/vectors.h
-- SipHash-2-4, key = 0x00..0x0f, message = first N bytes of 0x00..0x0e
--
-- Raw 64-bit result values (big-endian integer representation):
--   len=0: 0x726fdb47dd0e0e31
--   len=1: 0x74f839c593dc67fd
--   len=2: 0x0d6c8009d9a94f5a
--   len=3: 0x85676696d7fb7e2d
--   len=4: 0xcf2794e0277187b7
--
-- hash_hex() returns the 8 bytes of the uint64 in little-endian order (lo byte first),
-- so 0x726fdb47dd0e0e31 → bytes 31 0e 0e dd 47 db 6f 72 → "310e0edd47db6f72"
local VECTORS = {
  { msg = "",                 hex = "310e0edd47db6f72" },
  { msg = "\x00",             hex = "fd67dc93c539f874" },
  { msg = "\x00\x01",         hex = "5a4fa9d909806c0d" },
  { msg = "\x00\x01\x02",     hex = "2d7efbd796666785" },
  { msg = "\x00\x01\x02\x03", hex = "b7877127e09427cf" },
}

T.describe("lib.siphash", function()

  T.describe("tier", function()
    T.it("M._tier is 'pure'", function()
      T.eq(S._tier, "pure")
    end)
  end)

  T.describe("hash / hash_hex — reference vectors", function()
    for _, v in ipairs(VECTORS) do
      local desc = string.format("msg len=%d", #v.msg)
      T.it(desc, function()
        local got = S.hash_hex(KEY, v.msg)
        T.eq(got, v.hex)
      end)
    end

    T.it("wrong key length returns nil, errmsg", function()
      local r, err = S.hash("short", "hello")
      T.eq(r, nil)
      T.ok(type(err) == "string")
    end)

    T.it("non-string key returns nil, errmsg", function()
      local r, err = S.hash(123, "hello")
      T.eq(r, nil)
      T.ok(type(err) == "string")
    end)

    T.it("non-string message returns nil, errmsg", function()
      local r, err = S.hash(KEY, 42)
      T.eq(r, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("hash_pair", function()
    T.it("consistent with hash_hex for each reference vector", function()
      for _, v in ipairs(VECTORS) do
        local pair = S.hash_pair(KEY, v.msg)
        T.ok(pair ~= nil)
        -- Reconstruct little-endian hex from {lo, hi} and compare
        local function safe_hex8(val)
          local u = val
          if u < 0 then u = u + 0x100000000 end
          local bytes = {}
          for _ = 1, 4 do
            bytes[#bytes + 1] = string.format("%02x", u % 256)
            u = math.floor(u / 256)
          end
          return table.concat(bytes)
        end
        local reconstructed = safe_hex8(pair.lo) .. safe_hex8(pair.hi)
        T.eq(reconstructed, v.hex)
      end
    end)

    T.it("error propagation on bad key", function()
      local r, err = S.hash_pair("bad", "msg")
      T.eq(r, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("hash13 (SipHash-1-3)", function()
    T.it("produces a non-nil result", function()
      local h = S.hash13(KEY, "hello")
      T.ok(h ~= nil)
    end)

    T.it("hash13_hex returns 16 hex characters", function()
      local h = S.hash13_hex(KEY, "test")
      T.eq(#h, 16)
      T.ok(h:match("^[0-9a-f]+$") ~= nil)
    end)

    T.it("differs from hash (SipHash-2-4) — different round counts", function()
      local h24 = S.hash_hex(KEY, "hello, world!")
      local h13 = S.hash13_hex(KEY, "hello, world!")
      T.neq(h13, h24)
    end)

    T.it("hash13 is deterministic", function()
      local a = S.hash13_hex(KEY, "same input")
      local b = S.hash13_hex(KEY, "same input")
      T.eq(a, b)
    end)

    T.it("error propagation on bad key", function()
      local r, err = S.hash13("tooshort", "msg")
      T.eq(r, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("properties", function()
    T.it("deterministic — same key+msg yields same hash", function()
      local a = S.hash_hex(KEY, "test message")
      local b = S.hash_hex(KEY, "test message")
      T.eq(a, b)
    end)

    T.it("different messages → different hashes (avalanche)", function()
      local h1 = S.hash_hex(KEY, "message one")
      local h2 = S.hash_hex(KEY, "message two")
      T.neq(h1, h2)
    end)

    T.it("different keys → different hashes", function()
      local key2 = string.rep("\xff", 16)
      local h1 = S.hash_hex(KEY, "same message")
      local h2 = S.hash_hex(key2, "same message")
      T.neq(h1, h2)
    end)

    T.it("long input (1000 bytes, exact multiple of 8) works", function()
      local long_msg = string.rep("abcdefgh", 125)  -- exactly 1000 bytes
      local h = S.hash_hex(KEY, long_msg)
      T.ok(type(h) == "string" and #h == 16)
    end)

    T.it("input length not a multiple of 8 works", function()
      local h = S.hash_hex(KEY, "hello")  -- 5 bytes
      T.ok(type(h) == "string" and #h == 16)
    end)

    T.it("input of exactly 8 bytes works (single full block)", function()
      local h = S.hash_hex(KEY, "12345678")
      T.ok(type(h) == "string" and #h == 16)
    end)

    T.it("input of 9 bytes works (one full block + 1 remainder)", function()
      local h = S.hash_hex(KEY, "123456789")
      T.ok(type(h) == "string" and #h == 16)
    end)

    T.it("input of 7 bytes works (max partial block, no full blocks)", function()
      local h = S.hash_hex(KEY, "1234567")
      T.ok(type(h) == "string" and #h == 16)
    end)

    T.it("hash_hex always returns 16 lowercase hex characters", function()
      local h = S.hash_hex(KEY, "any message here")
      T.eq(#h, 16)
      T.ok(h:match("^[0-9a-f]+$") ~= nil)
    end)

    T.it("empty key (all zeros) produces different output than reference key", function()
      local zero_key = string.rep("\x00", 16)
      local h1 = S.hash_hex(KEY, "test")
      local h2 = S.hash_hex(zero_key, "test")
      T.neq(h1, h2)
    end)
  end)

end)
