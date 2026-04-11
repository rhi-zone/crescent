-- lib/brotli/brotli_test.lua
-- Tests for lib/brotli.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local brotli = require("lib.brotli")
local T = require("lib.test.assert")

T.describe("lib.brotli", function()

  -- ── Tier detection ──────────────────────────────────────────────────────────

  T.describe("tier", function()
    T.it("has _tier field", function()
      T.ok(
        brotli._tier == "system" or
        brotli._tier == "pure"   or
        brotli._tier == "stub",
        "expected _tier to be 'system', 'pure', or 'stub', got: " .. tostring(brotli._tier)
      )
    end)

    T.it("has decompress function", function()
      T.ok(type(brotli.decompress) == "function")
    end)

    T.it("has compress function", function()
      T.ok(type(brotli.compress) == "function")
    end)

    T.it("encode is alias for compress", function()
      T.ok(brotli.encode == brotli.compress)
    end)

    T.it("decode is alias for decompress", function()
      T.ok(brotli.decode == brotli.decompress)
    end)
  end)

  -- ── System tier tests ───────────────────────────────────────────────────────

  if brotli._tier == "system" then
    T.describe("compress/decompress (system)", function()

      T.it("round-trips empty string", function()
        local c, err = brotli.compress("")
        T.ok(c ~= nil, "compress failed: " .. tostring(err))
        local d, err2 = brotli.decompress(c)
        T.ok(d ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(d, "")
      end)

      T.it("round-trips short string", function()
        local pt = "Hello, Brotli!"
        local ct, err = brotli.compress(pt)
        T.ok(ct ~= nil, "compress failed: " .. tostring(err))
        local dt, err2 = brotli.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("compresses repetitive data well", function()
        local pt = ("abcdef"):rep(1000)
        local ct, err = brotli.compress(pt)
        T.ok(ct ~= nil, "compress failed: " .. tostring(err))
        -- Brotli should compress repetitive data heavily (< 10%)
        T.ok(#ct < #pt * 0.1,
          string.format("expected compressed size < %d, got %d", math.floor(#pt * 0.1), #ct))
        local dt, err2 = brotli.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("round-trips all byte values (binary data)", function()
        local bytes = {}
        for i = 0, 255 do bytes[i + 1] = string.char(i) end
        local pt = table.concat(bytes)
        T.eq(#pt, 256)
        local ct, err = brotli.compress(pt)
        T.ok(ct ~= nil, "compress failed: " .. tostring(err))
        local dt, err2 = brotli.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("round-trips longer text", function()
        local pt = ("The quick brown fox jumps over the lazy dog. "):rep(200)
        local ct, err = brotli.compress(pt)
        T.ok(ct ~= nil, "compress failed: " .. tostring(err))
        local dt, err2 = brotli.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("quality option accepted (0 = fastest)", function()
        local pt = "test data " .. ("x"):rep(500)
        local ct, err = brotli.compress(pt, { quality = 0 })
        T.ok(ct ~= nil, "compress quality=0 failed: " .. tostring(err))
        local dt, err2 = brotli.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("quality option accepted (11 = best)", function()
        local pt = "test data " .. ("x"):rep(500)
        local ct, err = brotli.compress(pt, { quality = 11 })
        T.ok(ct ~= nil, "compress quality=11 failed: " .. tostring(err))
        local dt, err2 = brotli.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("mode=1 (text) round-trips", function()
        local pt = string.rep("Lorem ipsum dolor sit amet. ", 100)
        local ct, err = brotli.compress(pt, { mode = 1 })
        T.ok(ct ~= nil, "compress mode=1 failed: " .. tostring(err))
        local dt, err2 = brotli.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("decompress rejects invalid data", function()
        local r, e = brotli.decompress("not brotli data")
        T.eq(r, nil)
        T.ok(e ~= nil, "expected error message")
        T.ok(type(e) == "string", "expected error to be string, got " .. type(e))
      end)

      T.it("decompress rejects truncated data", function()
        -- Compress something, then truncate the result
        local pt = "some data to compress"
        local ct = brotli.compress(pt)
        if ct and #ct > 4 then
          local r, e = brotli.decompress(ct:sub(1, math.floor(#ct / 2)))
          T.eq(r, nil)
          T.ok(e ~= nil, "expected error on truncated input")
        end
      end)

      T.it("compress rejects non-string input", function()
        local r, e = brotli.compress(42)
        T.eq(r, nil)
        T.ok(e ~= nil, "expected error on non-string input")
      end)

      T.it("decompress rejects non-string input", function()
        local r, e = brotli.decompress(42)
        T.eq(r, nil)
        T.ok(e ~= nil, "expected error on non-string input")
      end)

      T.it("encode/decode aliases work", function()
        local pt = "alias test"
        local ct, err = brotli.encode(pt)
        T.ok(ct ~= nil, "encode failed: " .. tostring(err))
        local dt, err2 = brotli.decode(ct)
        T.ok(dt ~= nil, "decode failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

      T.it("single null byte round-trips", function()
        local pt = "\0"
        local ct, err = brotli.compress(pt)
        T.ok(ct ~= nil, "compress failed: " .. tostring(err))
        local dt, err2 = brotli.decompress(ct)
        T.ok(dt ~= nil, "decompress failed: " .. tostring(err2))
        T.eq(dt, pt)
      end)

    end)

  -- ── Pure Lua tier tests ─────────────────────────────────────────────────────

  elseif brotli._tier == "pure" then
    T.describe("decompress (pure)", function()
      T.it("returns nil+errmsg on invalid data", function()
        local r, e = brotli.decompress("garbage")
        T.eq(r, nil)
        T.ok(e ~= nil, "expected error message")
      end)

      T.it("compress returns nil+errmsg (not implemented)", function()
        local r, e = brotli.compress("anything")
        T.eq(r, nil)
        T.ok(e ~= nil, "expected error message")
      end)
    end)

  -- ── Stub tier tests ─────────────────────────────────────────────────────────

  else -- stub
    T.describe("stub behavior", function()
      T.it("decompress returns nil+errmsg", function()
        local r, e = brotli.decompress("anything")
        T.eq(r, nil)
        T.ok(e ~= nil, "expected non-nil error message")
        T.ok(type(e) == "string", "expected string error, got " .. type(e))
      end)

      T.it("compress returns nil+errmsg", function()
        local r, e = brotli.compress("anything")
        T.eq(r, nil)
        T.ok(e ~= nil, "expected non-nil error message")
        T.ok(type(e) == "string", "expected string error, got " .. type(e))
      end)

      T.it("encode alias returns nil+errmsg", function()
        local r, e = brotli.encode("anything")
        T.eq(r, nil)
        T.ok(e ~= nil)
      end)

      T.it("decode alias returns nil+errmsg", function()
        local r, e = brotli.decode("anything")
        T.eq(r, nil)
        T.ok(e ~= nil)
      end)
    end)
  end

end)
