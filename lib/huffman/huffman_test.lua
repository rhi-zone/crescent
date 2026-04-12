if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local H = require("lib.huffman")

-- Helper: check prefix-free property
local function is_prefix_free(codes)
  local code_list = {}
  for _, code in pairs(codes) do
    code_list[#code_list + 1] = code
  end
  for i = 1, #code_list do
    for j = 1, #code_list do
      if i ~= j then
        local a, b = code_list[i], code_list[j]
        if #a <= #b then
          if b:sub(1, #a) == a then
            return false, a .. " is prefix of " .. b
          end
        end
      end
    end
  end
  return true
end

-- Helper: count symbols in a table
local function table_count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

T.describe("build_tree", function()
  T.it("returns a tree for simple freqs", function()
    local tree = H.build_tree({ a = 5, b = 3, c = 2 })
    T.ok(tree ~= nil, "tree is not nil")
    T.ok(tree.freq ~= nil, "tree has freq")
  end)

  T.it("single symbol returns leaf node", function()
    local tree = H.build_tree({ a = 10 })
    T.ok(tree ~= nil, "tree not nil")
    T.eq(tree.sym, "a")
    T.eq(tree.freq, 10)
  end)

  T.it("root freq equals sum of all freqs", function()
    local freqs = { a = 5, b = 3, c = 2, d = 8 }
    local tree = H.build_tree(freqs)
    T.eq(tree.freq, 18)
  end)

  T.it("returns nil, errmsg for empty table", function()
    local tree, err = H.build_tree({})
    T.eq(tree, nil)
    T.ok(err ~= nil, "error message returned")
  end)

  T.it("returns nil, errmsg for non-table", function()
    local tree, err = H.build_tree("not a table")
    T.eq(tree, nil)
    T.ok(err ~= nil, "error message returned")
  end)
end)

T.describe("build_codes", function()
  T.it("returns codes table for each symbol", function()
    local tree = H.build_tree({ a = 5, b = 3, c = 2 })
    local codes = H.build_codes(tree)
    T.ok(codes ~= nil, "codes not nil")
    T.ok(codes["a"] ~= nil, "code for a")
    T.ok(codes["b"] ~= nil, "code for b")
    T.ok(codes["c"] ~= nil, "code for c")
  end)

  T.it("codes are bit strings of 0s and 1s", function()
    local tree = H.build_tree({ a = 5, b = 3, c = 2 })
    local codes = H.build_codes(tree)
    for sym, code in pairs(codes) do
      T.ok(type(code) == "string", "code for " .. sym .. " is string")
      T.ok(code:match("^[01]+$") ~= nil, "code for " .. sym .. " is binary: " .. code)
    end
  end)

  T.it("prefix-free: no code is prefix of another (3 symbols)", function()
    local tree = H.build_tree({ a = 5, b = 3, c = 2 })
    local codes = H.build_codes(tree)
    local ok, msg = is_prefix_free(codes)
    T.ok(ok, "prefix-free: " .. tostring(msg))
  end)

  T.it("prefix-free: 5 symbols", function()
    local tree = H.build_tree({ a = 10, b = 8, c = 5, d = 3, e = 1 })
    local codes = H.build_codes(tree)
    local ok, msg = is_prefix_free(codes)
    T.ok(ok, "prefix-free: " .. tostring(msg))
  end)

  T.it("single symbol gets code '0'", function()
    local tree = H.build_tree({ x = 7 })
    local codes = H.build_codes(tree)
    T.eq(codes["x"], "0")
  end)

  T.it("returns nil, err for nil tree", function()
    local codes, err = H.build_codes(nil)
    T.eq(codes, nil)
    T.ok(err ~= nil, "error returned")
  end)

  T.it("more frequent symbol gets shorter code", function()
    local tree = H.build_tree({ a = 100, b = 1 })
    local codes = H.build_codes(tree)
    T.ok(#codes["a"] <= #codes["b"], "frequent symbol has shorter or equal code")
  end)
end)

T.describe("encode_symbols / decode_symbols round-trip", function()
  T.it("encodes and decodes single symbol", function()
    local freqs = { a = 5 }
    local tree = H.build_tree(freqs)
    local codes = H.build_codes(tree)
    local encoded, total_bits = H.encode_symbols({ "a", "a", "a" }, codes)
    T.ok(encoded ~= nil, "encoded not nil")
    T.eq(total_bits, 3)
    local decoded = H.decode_symbols(encoded, total_bits, tree)
    T.ok(decoded ~= nil, "decoded not nil")
    T.eq(#decoded, 3)
    T.eq(decoded[1], "a")
    T.eq(decoded[2], "a")
    T.eq(decoded[3], "a")
  end)

  T.it("encodes and decodes multiple symbols", function()
    local freqs = { a = 5, b = 3, c = 2 }
    local tree = H.build_tree(freqs)
    local codes = H.build_codes(tree)
    local input = { "a", "b", "c", "a", "a", "b", "c" }
    local encoded, total_bits = H.encode_symbols(input, codes)
    T.ok(encoded ~= nil, "encoded not nil")
    T.ok(total_bits > 0, "total_bits > 0")
    local decoded = H.decode_symbols(encoded, total_bits, tree)
    T.ok(decoded ~= nil, "decoded not nil")
    T.eq(#decoded, #input)
    for i = 1, #input do
      T.eq(decoded[i], input[i])
    end
  end)

  T.it("encode returns nil for unknown symbol", function()
    local codes = { a = "0" }
    local encoded, bits, err = H.encode_symbols({ "a", "z" }, codes)
    T.eq(encoded, nil)
    T.ok(err ~= nil, "error returned for unknown symbol")
  end)

  T.it("decode returns nil for nil tree", function()
    local result, err = H.decode_symbols("abc", 10, nil)
    T.eq(result, nil)
    T.ok(err ~= nil, "error returned")
  end)
end)

T.describe("compress / decompress", function()
  T.it("hello world round-trip", function()
    local orig = "hello world"
    local enc, meta = H.compress(orig)
    T.ok(enc ~= nil, "encoded not nil")
    T.ok(meta ~= nil, "metadata not nil")
    T.ok(meta.total_bits > 0, "total_bits > 0")
    local dec, err = H.decompress(enc, meta)
    T.eq(err, nil)
    T.eq(dec, orig)
  end)

  T.it("single repeated character: 'aaaaaaa'", function()
    local orig = "aaaaaaa"
    local enc, meta = H.compress(orig)
    T.ok(enc ~= nil, "encoded not nil")
    local dec = H.decompress(enc, meta)
    T.eq(dec, orig)
  end)

  T.it("all unique chars: 'abcde'", function()
    local orig = "abcde"
    local enc, meta = H.compress(orig)
    T.ok(enc ~= nil, "encoded not nil")
    local dec = H.decompress(enc, meta)
    T.eq(dec, orig)
  end)

  T.it("empty string compresses and decompresses", function()
    local enc, meta = H.compress("")
    T.ok(enc ~= nil, "encoded not nil")
    T.eq(enc, "")
    local dec = H.decompress(enc, meta)
    T.eq(dec, "")
  end)

  T.it("longer text round-trip", function()
    local orig = "the quick brown fox jumps over the lazy dog 1234567890"
    local enc, meta = H.compress(orig)
    T.ok(enc ~= nil, "encoded not nil")
    local dec = H.decompress(enc, meta)
    T.eq(dec, orig)
  end)

  T.it("compress returns error for non-string", function()
    local enc, meta, err = H.compress(42)
    T.eq(enc, nil)
    T.ok(err ~= nil, "error returned")
  end)

  T.it("single character string", function()
    local orig = "z"
    local enc, meta = H.compress(orig)
    T.ok(enc ~= nil)
    local dec = H.decompress(enc, meta)
    T.eq(dec, orig)
  end)

  T.it("binary-like string with all byte values", function()
    local chars = {}
    for i = 0, 127 do
      chars[i + 1] = string.char(i)
    end
    local orig = table.concat(chars)
    local enc, meta = H.compress(orig)
    T.ok(enc ~= nil, "encoded not nil")
    local dec = H.decompress(enc, meta)
    T.eq(dec, orig)
  end)
end)

T.describe("code_lengths", function()
  T.it("returns depths for each symbol", function()
    local tree = H.build_tree({ a = 8, b = 4, c = 2, d = 1 })
    local lengths = H.code_lengths(tree)
    T.ok(lengths ~= nil, "lengths not nil")
    T.ok(lengths["a"] ~= nil, "length for a")
    T.ok(lengths["b"] ~= nil, "length for b")
    T.ok(lengths["c"] ~= nil, "length for c")
    T.ok(lengths["d"] ~= nil, "length for d")
  end)

  T.it("more frequent symbol gets shorter length", function()
    local tree = H.build_tree({ a = 100, b = 1, c = 1 })
    local lengths = H.code_lengths(tree)
    T.ok(lengths["a"] <= lengths["b"], "frequent symbol shorter")
  end)

  T.it("single symbol has length 1", function()
    local tree = H.build_tree({ x = 5 })
    local lengths = H.code_lengths(tree)
    T.eq(lengths["x"], 1)
  end)

  T.it("correct number of symbols returned", function()
    local freqs = { a = 5, b = 3, c = 2, d = 8 }
    local tree = H.build_tree(freqs)
    local lengths = H.code_lengths(tree)
    T.eq(table_count(lengths), 4)
  end)
end)

T.describe("entropy", function()
  T.it("entropy of uniform distribution is max", function()
    local h_uniform = H.entropy({ a = 1, b = 1, c = 1, d = 1 })
    T.ok(math.abs(h_uniform - 2.0) < 1e-9, "uniform 4-symbol entropy = 2 bits: " .. tostring(h_uniform))
  end)

  T.it("repeated chars have lower entropy than unique chars", function()
    local h_rep = H.entropy({ a = 3, b = 1 })
    local h_uniq = H.entropy({ a = 1, b = 1 })
    T.ok(h_rep < h_uniq, "h(aab) < h(ab)")
  end)

  T.it("'aabb' lower entropy than 'abcd'", function()
    -- aabb: a=2,b=2 → entropy = 1 bit
    -- abcd: each=1 → entropy = 2 bits
    local h_aabb = H.entropy({ a = 2, b = 2 })
    local h_abcd = H.entropy({ a = 1, b = 1, c = 1, d = 1 })
    T.ok(h_aabb < h_abcd, "h(aabb) < h(abcd)")
  end)

  T.it("single symbol has 0 entropy", function()
    local h = H.entropy({ a = 10 })
    T.ok(math.abs(h) < 1e-9, "single symbol entropy = 0: " .. tostring(h))
  end)

  T.it("returns 0 for empty freq table", function()
    local h = H.entropy({})
    T.eq(h, 0)
  end)
end)

T.describe("expected_length", function()
  T.it("expected length >= entropy (Huffman optimality lower bound)", function()
    local freqs = { a = 10, b = 5, c = 3, d = 2 }
    local tree = H.build_tree(freqs)
    local codes = H.build_codes(tree)
    local h = H.entropy(freqs)
    local el = H.expected_length(freqs, codes)
    T.ok(el >= h - 1e-9, "expected_length >= entropy: el=" .. el .. " h=" .. h)
  end)

  T.it("expected length <= entropy + 1 (Huffman optimality upper bound)", function()
    local freqs = { a = 10, b = 5, c = 3, d = 2 }
    local tree = H.build_tree(freqs)
    local codes = H.build_codes(tree)
    local h = H.entropy(freqs)
    local el = H.expected_length(freqs, codes)
    T.ok(el <= h + 1 + 1e-9, "expected_length <= entropy+1: el=" .. el .. " h=" .. h)
  end)

  T.it("single symbol expected length = 1 (assigned code '0')", function()
    local freqs = { a = 5 }
    local tree = H.build_tree(freqs)
    local codes = H.build_codes(tree)
    local el = H.expected_length(freqs, codes)
    T.eq(el, 1.0)
  end)

  T.it("returns error for unknown symbol", function()
    local el, err = H.expected_length({ a = 5, b = 3 }, { a = "0" })
    T.eq(el, nil)
    T.ok(err ~= nil, "error returned for missing code")
  end)
end)

T.describe("canonical_codes", function()
  T.it("produces prefix-free codes", function()
    local lengths = { a = 1, b = 2, c = 3, d = 3 }
    local codes = H.canonical_codes(lengths)
    T.ok(codes ~= nil, "codes not nil")
    local ok, msg = is_prefix_free(codes)
    T.ok(ok, "canonical codes are prefix-free: " .. tostring(msg))
  end)

  T.it("code lengths match input lengths", function()
    local lengths = { a = 2, b = 2, c = 3, d = 3 }
    local codes = H.canonical_codes(lengths)
    for sym, len in pairs(lengths) do
      T.eq(#codes[sym], len)
    end
  end)

  T.it("first code (shortest) starts at 0", function()
    local lengths = { a = 1, b = 2, c = 3 }
    local codes = H.canonical_codes(lengths)
    -- 'a' has length 1: should be "0"
    T.eq(codes["a"], "0")
  end)

  T.it("same lengths as build_codes give same structure", function()
    local freqs = { a = 10, b = 5, c = 3 }
    local tree = H.build_tree(freqs)
    local orig_lengths = H.code_lengths(tree)
    local can_codes = H.canonical_codes(orig_lengths)
    T.ok(can_codes ~= nil, "canonical codes not nil")
    -- Canonical codes are prefix-free and have correct lengths
    local ok = is_prefix_free(can_codes)
    T.ok(ok, "canonical codes prefix-free")
    for sym, len in pairs(orig_lengths) do
      T.eq(#can_codes[sym], len)
    end
  end)

  T.it("two symbols with same length get different codes", function()
    local lengths = { a = 2, b = 2 }
    local codes = H.canonical_codes(lengths)
    T.ok(codes["a"] ~= codes["b"], "same-length symbols get different codes")
  end)
end)

T.describe("serialize_freqs / deserialize_freqs", function()
  T.it("round-trip with integer keys", function()
    local freqs = { [65] = 3, [66] = 5, [67] = 1 }
    local s = H.serialize_freqs(freqs)
    T.ok(type(s) == "string", "serialized to string")
    local out = H.deserialize_freqs(s)
    T.ok(out ~= nil, "deserialized not nil")
    T.eq(out[65], 3)
    T.eq(out[66], 5)
    T.eq(out[67], 1)
  end)

  T.it("round-trip with string keys", function()
    local freqs = { hello = 4, world = 2, foo = 7 }
    local s = H.serialize_freqs(freqs)
    local out = H.deserialize_freqs(s)
    T.ok(out ~= nil, "deserialized not nil")
    T.eq(out["hello"], 4)
    T.eq(out["world"], 2)
    T.eq(out["foo"], 7)
  end)

  T.it("round-trip with special chars in string key", function()
    local freqs = { ["a:b"] = 3, ["x\ny"] = 2 }
    local s = H.serialize_freqs(freqs)
    T.ok(type(s) == "string", "serialized ok")
    local out = H.deserialize_freqs(s)
    T.ok(out ~= nil, "deserialized not nil")
    T.eq(out["a:b"], 3)
    T.eq(out["x\ny"], 2)
  end)

  T.it("empty freqs serializes to empty string", function()
    local s = H.serialize_freqs({})
    T.eq(s, "")
    local out = H.deserialize_freqs(s)
    T.ok(out ~= nil, "deserialized not nil")
    T.eq(table_count(out), 0)
  end)

  T.it("returns error for non-table", function()
    local s, err = H.serialize_freqs("not a table")
    T.eq(s, nil)
    T.ok(err ~= nil, "error returned")
  end)

  T.it("compress/decompress uses serialize/deserialize correctly", function()
    local orig = "testing serialize round-trip"
    local enc, meta = H.compress(orig)
    T.ok(enc ~= nil, "encoded not nil")
    local s = H.serialize_freqs(meta.freqs)
    local freqs2 = H.deserialize_freqs(s)
    T.ok(freqs2 ~= nil, "deserialized freqs")
    -- Decompress using original encoded bytes but deserialized freqs
    local meta2 = { freqs = freqs2, total_bits = meta.total_bits }
    local dec = H.decompress(enc, meta2)
    T.eq(dec, orig)
  end)
end)

T.describe("integration: full pipeline", function()
  T.it("encode/decode preserves byte integrity", function()
    local orig = "abracadabra"
    local enc, meta = H.compress(orig)
    T.ok(enc ~= nil)
    T.ok(#enc <= #orig, "compressed is not larger for repetitive input")
    local dec = H.decompress(enc, meta)
    T.eq(dec, orig)
  end)

  T.it("repeated single char: large input", function()
    local orig = string.rep("x", 1000)
    local enc, meta = H.compress(orig)
    T.ok(enc ~= nil)
    -- Single char encodes to 1 bit each → 1000 bits = 125 bytes
    T.ok(#enc <= 200, "single-char string highly compressed")
    local dec = H.decompress(enc, meta)
    T.eq(dec, orig)
  end)

  T.it("build_codes count matches symbol count", function()
    local freqs = { a = 1, b = 2, c = 3, d = 4, e = 5 }
    local tree = H.build_tree(freqs)
    local codes = H.build_codes(tree)
    T.eq(table_count(codes), 5)
  end)
end)
