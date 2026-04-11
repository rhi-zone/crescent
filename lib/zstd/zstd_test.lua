-- lib/zstd/zstd_test.lua
-- Tests for lib/zstd.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local zstd = require("lib.zstd")
local T = require("lib.test.assert")

T.describe("lib.zstd", function()

  -- ── Tier detection ──────────────────────────────────────────────────────────

  T.describe("tier", function()
    T.it("has _tier field", function()
      T.ok(
        zstd._tier == "system" or
        zstd._tier == "stub",
        "expected _tier to be 'system' or 'stub', got: " .. tostring(zstd._tier)
      )
    end)

    T.it("has compress function", function()
      T.ok(type(zstd.compress) == "function")
    end)

    T.it("has decompress function", function()
      T.ok(type(zstd.decompress) == "function")
    end)

    T.it("has is_zstd function", function()
      T.ok(type(zstd.is_zstd) == "function")
    end)

    T.it("encode is alias for compress", function()
      T.ok(zstd.encode == zstd.compress)
    end)

    T.it("decode is alias for decompress", function()
      T.ok(zstd.decode == zstd.decompress)
    end)
  end)

  -- ── is_zstd (pure Lua, available on all tiers) ──────────────────────────────

  T.describe("is_zstd", function()
    T.it("recognises zstd magic prefix", function()
      T.ok(zstd.is_zstd("\x28\xb5\x2f\xfd" .. "rest of frame"))
    end)

    T.it("recognises exact 4-byte magic", function()
      T.ok(zstd.is_zstd("\x28\xb5\x2f\xfd"))
    end)

    T.it("rejects non-zstd data", function()
      T.ok(not zstd.is_zstd("not zstd data"))
    end)

    T.it("rejects empty string", function()
      T.ok(not zstd.is_zstd(""))
    end)

    T.it("rejects string shorter than 4 bytes", function()
      T.ok(not zstd.is_zstd("\x28\xb5\x2f"))
    end)

    T.it("rejects non-string input (number)", function()
      T.ok(not zstd.is_zstd(42))
    end)

    T.it("rejects nil", function()
      T.ok(not zstd.is_zstd(nil))
    end)

    T.it("rejects wrong magic (gzip)", function()
      -- gzip magic: \x1f\x8b
      T.ok(not zstd.is_zstd("\x1f\x8b\x08\x00"))
    end)
  end)

  -- ── System tier tests ───────────────────────────────────────────────────────

  if zstd._tier == "system" then
    T.describe("compress/decompress (system)", function()

      T.it("round-trips empty string", function()
        local c, err = zstd.compress("")
        T.ok(c ~= nil, "compress failed: " .. tostring(err))
        local d, err2 = zstd.decompress(c)
        T.ok(d ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(d, "")
      end)

      T.it("round-trips short string", function()
        local pt = "Hello, Zstandard!"
        local ct, err = zstd.compress(pt)
        T.ok(ct ~= nil, "compress failed: " .. tostring(err))
        local dt, err2 = zstd.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("compressed output starts with zstd magic", function()
        local ct, err = zstd.compress("hello world")
        T.ok(ct ~= nil, "compress failed: " .. tostring(err))
        T.ok(zstd.is_zstd(ct), "expected compressed output to have zstd magic bytes")
      end)

      T.it("compresses repetitive data well (< 10% of original)", function()
        local pt = ("abcdefghij"):rep(1000)
        local ct, err = zstd.compress(pt)
        T.ok(ct ~= nil, "compress failed: " .. tostring(err))
        T.ok(#ct < #pt * 0.1,
          string.format("expected compressed size < %d, got %d", math.floor(#pt * 0.1), #ct))
        local dt, err2 = zstd.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("round-trips all byte values (binary data)", function()
        local bytes = {}
        for i = 0, 255 do bytes[i + 1] = string.char(i) end
        local pt = table.concat(bytes)
        T.eq(#pt, 256)
        local ct, err = zstd.compress(pt)
        T.ok(ct ~= nil, "compress failed: " .. tostring(err))
        local dt, err2 = zstd.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("round-trips single null byte", function()
        local pt = "\0"
        local ct, err = zstd.compress(pt)
        T.ok(ct ~= nil, "compress failed: " .. tostring(err))
        local dt, err2 = zstd.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("round-trips longer text", function()
        local pt = ("The quick brown fox jumps over the lazy dog. "):rep(200)
        local ct, err = zstd.compress(pt)
        T.ok(ct ~= nil, "compress failed: " .. tostring(err))
        local dt, err2 = zstd.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("level 1 (fastest) round-trips", function()
        local pt = "test data " .. ("x"):rep(500)
        local ct, err = zstd.compress(pt, { level = 1 })
        T.ok(ct ~= nil, "compress level=1 failed: " .. tostring(err))
        local dt, err2 = zstd.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("level 19 (high) round-trips", function()
        local pt = "test data " .. ("x"):rep(500)
        local ct, err = zstd.compress(pt, { level = 19 })
        T.ok(ct ~= nil, "compress level=19 failed: " .. tostring(err))
        local dt, err2 = zstd.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("higher level compresses at least as well as lower on repetitive data", function()
        local pt = ("hello world "):rep(500)
        local ct1, err1 = zstd.compress(pt, { level = 1 })
        local ct19, err19 = zstd.compress(pt, { level = 19 })
        T.ok(ct1  ~= nil, "level 1 compress failed: "  .. tostring(err1))
        T.ok(ct19 ~= nil, "level 19 compress failed: " .. tostring(err19))
        T.ok(#ct19 <= #ct1,
          string.format("expected level 19 (%d) <= level 1 (%d)", #ct19, #ct1))
      end)

      T.it("decompress rejects invalid data", function()
        local r, e = zstd.decompress("not zstd data at all")
        T.eq(r, nil)
        T.ok(e ~= nil, "expected error message")
        T.ok(type(e) == "string", "expected error to be string, got " .. type(e))
      end)

      T.it("decompress rejects empty string as invalid frame", function()
        local r, e = zstd.decompress("")
        T.eq(r, nil)
        T.ok(e ~= nil, "expected error on empty input")
      end)

      T.it("decompress rejects truncated frame", function()
        local pt = ("hello zstd "):rep(50)
        local ct = zstd.compress(pt)
        if ct and #ct > 8 then
          local r, e = zstd.decompress(ct:sub(1, math.floor(#ct / 2)))
          T.eq(r, nil)
          T.ok(e ~= nil, "expected error on truncated frame")
        end
      end)

      T.it("compress rejects non-string input", function()
        local r, e = zstd.compress(42)
        T.eq(r, nil)
        T.ok(e ~= nil, "expected error on non-string input")
      end)

      T.it("decompress rejects non-string input", function()
        local r, e = zstd.decompress(42)
        T.eq(r, nil)
        T.ok(e ~= nil, "expected error on non-string input")
      end)

      T.it("encode/decode aliases work end-to-end", function()
        local pt = "alias round-trip test"
        local ct, err = zstd.encode(pt)
        T.ok(ct ~= nil, "encode failed: " .. tostring(err))
        local dt, err2 = zstd.decode(ct)
        T.ok(dt ~= nil, "decode failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

    end)

  -- ── Stub tier tests ─────────────────────────────────────────────────────────

  else -- stub
    T.describe("stub behavior", function()
      T.it("compress returns nil+errmsg", function()
        local r, e = zstd.compress("anything")
        T.eq(r, nil)
        T.ok(e ~= nil, "expected non-nil error message")
        T.ok(type(e) == "string", "expected string error, got " .. type(e))
      end)

      T.it("decompress returns nil+errmsg", function()
        local r, e = zstd.decompress("anything")
        T.eq(r, nil)
        T.ok(e ~= nil, "expected non-nil error message")
        T.ok(type(e) == "string", "expected string error, got " .. type(e))
      end)

      T.it("encode alias returns nil+errmsg", function()
        local r, e = zstd.encode("anything")
        T.eq(r, nil)
        T.ok(e ~= nil)
      end)

      T.it("decode alias returns nil+errmsg", function()
        local r, e = zstd.decode("anything")
        T.eq(r, nil)
        T.ok(e ~= nil)
      end)
    end)
  end

end)
