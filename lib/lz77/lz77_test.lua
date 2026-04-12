-- lib/lz77/lz77_test.lua
-- Tests for lib/lz77 pure Lua LZ77 compression and decompression.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local lz77 = require("lib.lz77")

local char   = string.char
local byte   = string.byte
local rep    = string.rep

-- Helper: build a string with all 256 byte values 0x00-0xFF
local function all_bytes()
  local t = {}
  for i = 0, 255 do t[i + 1] = char(i) end
  return table.concat(t)
end

-- A multi-kilobyte lorem ipsum paragraph repeated 5 times
local lorem = rep(
  "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " ..
  "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. " ..
  "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris " ..
  "nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in " ..
  "reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla " ..
  "pariatur. Excepteur sint occaecat cupidatat non proident, sunt in " ..
  "culpa qui officia deserunt mollit anim id est laborum. ",
  5
)

-- ── Module metadata ───────────────────────────────────────────────────────────

T.describe("lz77 module", function()
  T.it("exports compress", function()
    T.ok(type(lz77.compress) == "function", "compress is a function")
  end)
  T.it("exports decompress", function()
    T.ok(type(lz77.decompress) == "function", "decompress is a function")
  end)
  T.it("exports compressor", function()
    T.ok(type(lz77.compressor) == "function", "compressor is a function")
  end)
  T.it("exports decompressor", function()
    T.ok(type(lz77.decompressor) == "function", "decompressor is a function")
  end)
  T.it("_tier is 'pure'", function()
    T.eq(lz77._tier, "pure")
  end)
  T.it("encode/decode aliases exist", function()
    T.ok(lz77.encode == lz77.compress, "encode aliases compress")
    T.ok(lz77.decode == lz77.decompress, "decode aliases decompress")
  end)
end)

-- ── Round-trip tests ──────────────────────────────────────────────────────────

T.describe("round-trip", function()
  T.it("empty string", function()
    local c, err = lz77.compress("")
    T.ok(c, "compress succeeded: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress succeeded: " .. tostring(derr))
    T.eq(d, "")
  end)

  T.it("single byte", function()
    local input = "X"
    local c, err = lz77.compress(input)
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, input)
  end)

  T.it("highly compressible: 1000 'a's", function()
    local input = rep("a", 1000)
    local c, err = lz77.compress(input)
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, input)
  end)

  T.it("short random-like string", function()
    local input = "randomdata12345"
    local c, err = lz77.compress(input)
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, input)
  end)

  T.it("all 256 byte values", function()
    local input = all_bytes()
    T.eq(#input, 256)
    local c, err = lz77.compress(input)
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, input)
  end)

  T.it("multi-kilobyte lorem ipsum x5", function()
    T.ok(#lorem > 2048, "lorem is large enough: " .. #lorem .. " bytes")
    local c, err = lz77.compress(lorem)
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, lorem)
  end)

  T.it("overlapping match (run-length like: 'ababab...')", function()
    local input = rep("ab", 500)  -- 1000 bytes with 2-byte period
    local c, err = lz77.compress(input)
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, input)
  end)

  T.it("binary-ish data: sequential bytes 0-255 repeated", function()
    local input = rep(all_bytes(), 4)  -- 1024 bytes
    local c, err = lz77.compress(input)
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, input)
  end)

  T.it("null bytes", function()
    local input = rep("\0", 200)
    local c, err = lz77.compress(input)
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, input)
  end)

  T.it("bytes 0x80-0xFF run", function()
    local t = {}
    for i = 128, 255 do t[#t + 1] = char(i) end
    local input = rep(table.concat(t), 3)
    local c, err = lz77.compress(input)
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, input)
  end)
end)

-- ── Compression ratio ────────────────────────────────────────────────────────

T.describe("compression ratio", function()
  T.it("1000 'a's compress to < 20 bytes", function()
    local input = rep("a", 1000)
    local c = lz77.compress(input)
    T.ok(c ~= nil, "compress returned nil")
    T.ok(#c < 20, "compressed size is " .. #c .. ", expected < 20")
  end)

  T.it("lorem ipsum x5 compresses better than 50% of original", function()
    local c = lz77.compress(lorem)
    T.ok(c ~= nil)
    local ratio = #c / #lorem
    T.ok(ratio < 0.5, "ratio = " .. string.format("%.3f", ratio) .. " (expected < 0.50)")
  end)

  T.it("random-like short string is not larger than 3x original + header overhead", function()
    local input = "randomdata12345"
    local c = lz77.compress(input)
    T.ok(c ~= nil)
    -- header = 9 bytes, each literal = 2 bytes, so worst case = 9 + 2*15 + 1 = 40
    T.ok(#c <= 50, "compressed size " .. #c .. " is unexpectedly large")
  end)
end)

-- ── Streaming API ────────────────────────────────────────────────────────────

T.describe("streaming compressor", function()
  T.it("single write matches compress()", function()
    local input = rep("hello world! ", 50)
    local direct = lz77.compress(input)
    local comp = lz77.compressor()
    comp:write(input)
    local streamed = comp:finish()
    T.ok(streamed ~= nil, "streamed compress returned nil")
    T.eq(streamed, direct)
  end)

  T.it("multiple writes matches compress()", function()
    local input = rep("chunk test data ", 30)
    local direct = lz77.compress(input)
    local comp = lz77.compressor()
    -- Split into 3 chunks
    local third = math.floor(#input / 3)
    comp:write(input:sub(1, third))
    comp:write(input:sub(third + 1, 2 * third))
    comp:write(input:sub(2 * third + 1))
    local streamed = comp:finish()
    T.ok(streamed ~= nil, "streamed compress returned nil")
    T.eq(streamed, direct)
  end)

  T.it("empty write then finish round-trips", function()
    local comp = lz77.compressor()
    comp:write("")
    local c = comp:finish()
    T.ok(c ~= nil)
    local d = lz77.decompress(c)
    T.eq(d, "")
  end)
end)

T.describe("streaming decompressor", function()
  T.it("single write matches decompress()", function()
    local input = rep("hello world! ", 50)
    local c = lz77.compress(input)
    local direct = lz77.decompress(c)
    local decomp = lz77.decompressor()
    decomp:write(c)
    local streamed = decomp:finish()
    T.ok(streamed ~= nil, "streamed decompress returned nil")
    T.eq(streamed, direct)
  end)

  T.it("multiple writes matches decompress()", function()
    local input = rep("decompress chunk test ", 20)
    local c = lz77.compress(input)
    local direct = lz77.decompress(c)
    local decomp = lz77.decompressor()
    -- Split compressed stream in half
    local half = math.floor(#c / 2)
    decomp:write(c:sub(1, half))
    decomp:write(c:sub(half + 1))
    local streamed = decomp:finish()
    T.ok(streamed ~= nil, "streamed decompress returned nil")
    T.eq(streamed, direct)
  end)

  T.it("decompress streaming round-trip matches original", function()
    local input = lorem
    local c = lz77.compress(input)
    local decomp = lz77.decompressor()
    decomp:write(c)
    local d = decomp:finish()
    T.eq(d, input)
  end)
end)

-- ── Error handling ────────────────────────────────────────────────────────────

T.describe("error handling", function()
  T.it("bad magic bytes returns nil+err", function()
    local bad = "BAD!" .. string.rep("\0", 10)
    local d, err = lz77.decompress(bad)
    T.ok(d == nil, "expected nil result")
    T.ok(type(err) == "string", "expected error string, got: " .. tostring(err))
    T.ok(err:find("magic") ~= nil, "error mentions magic: " .. err)
  end)

  T.it("truncated input (only magic) returns nil+err", function()
    local bad = "LZ77"
    local d, err = lz77.decompress(bad)
    T.ok(d == nil, "expected nil result")
    T.ok(type(err) == "string", "expected error string")
  end)

  T.it("truncated after header returns nil+err", function()
    -- Valid header but no tokens and no end byte
    local bad = "LZ77" .. char(15) .. char(1) .. char(0) .. char(0) .. char(0)
    -- That's 9 bytes, minimum is 10
    local d, err = lz77.decompress(bad)
    T.ok(d == nil, "expected nil result")
    T.ok(type(err) == "string", "expected error string")
  end)

  T.it("truncated literal token (missing byte) returns nil+err", function()
    -- Header (9 bytes) + TOK_LITERAL=0x00 (no byte follows)
    -- orig_len=1 but we'll get a truncation error before length mismatch
    local bad = "LZ77" .. char(15) .. char(1) .. char(0) .. char(0) .. char(0) .. char(0x00)
    local d, err = lz77.decompress(bad)
    T.ok(d == nil, "expected nil")
    T.ok(type(err) == "string", "expected error string")
  end)

  T.it("truncated match token (missing distance/length) returns nil+err", function()
    -- Header + TOK_MATCH=0x01 + 1 byte (incomplete)
    local bad = "LZ77" .. char(15) .. char(5) .. char(0) .. char(0) .. char(0) ..
                char(0x01) .. char(1)
    local d, err = lz77.decompress(bad)
    T.ok(d == nil, "expected nil")
    T.ok(type(err) == "string", "expected error string")
  end)

  T.it("compress with non-string input returns nil+err", function()
    local c, err = lz77.compress(42)
    T.ok(c == nil, "expected nil")
    T.ok(type(err) == "string", "expected error string")
  end)

  T.it("decompress with non-string input returns nil+err", function()
    local d, err = lz77.decompress(42)
    T.ok(d == nil, "expected nil")
    T.ok(type(err) == "string", "expected error string")
  end)

  T.it("invalid window_bits returns nil+err", function()
    local c, err = lz77.compress("hello", { window_bits = 0 })
    T.ok(c == nil, "expected nil")
    T.ok(type(err) == "string", "expected error string")
  end)

  T.it("window_bits > 15 returns nil+err", function()
    local c, err = lz77.compress("hello", { window_bits = 16 })
    T.ok(c == nil, "expected nil")
    T.ok(type(err) == "string", "expected error string")
  end)
end)

-- ── Window bits option ────────────────────────────────────────────────────────

T.describe("window_bits option", function()
  T.it("window_bits=8 round-trips", function()
    local input = rep("test data for small window ", 20)
    local c, err = lz77.compress(input, { window_bits = 8 })
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, input)
  end)

  T.it("window_bits=1 round-trips", function()
    local input = "abcabc"
    local c, err = lz77.compress(input, { window_bits = 1 })
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, input)
  end)

  T.it("window_bits=15 (default) round-trips", function()
    local input = rep("default window test ", 40)
    local c, err = lz77.compress(input, { window_bits = 15 })
    T.ok(c, "compress: " .. tostring(err))
    local d, derr = lz77.decompress(c)
    T.ok(d ~= nil, "decompress: " .. tostring(derr))
    T.eq(d, input)
  end)
end)

-- ── Header format verification ────────────────────────────────────────────────

T.describe("header format", function()
  T.it("compressed output starts with LZ77 magic", function()
    local c = lz77.compress("hello")
    T.ok(c ~= nil)
    T.eq(c:sub(1, 4), "LZ77")
  end)

  T.it("window_bits byte in header matches option", function()
    local c = lz77.compress("hello", { window_bits = 10 })
    T.ok(c ~= nil)
    T.eq(string.byte(c, 5), 10)
  end)

  T.it("orig_len in header is correct (LE uint32)", function()
    local input = "hello world"
    local c = lz77.compress(input)
    T.ok(c ~= nil)
    local b0, b1, b2, b3 = string.byte(c, 6, 9)
    local orig_len = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
    T.eq(orig_len, #input)
  end)

  T.it("empty input has orig_len=0 in header", function()
    local c = lz77.compress("")
    T.ok(c ~= nil)
    local b0, b1, b2, b3 = string.byte(c, 6, 9)
    local orig_len = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
    T.eq(orig_len, 0)
  end)
end)
