if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local W = require("lib.wire_protocol")

-- ---------------------------------------------------------------------------
-- length_prefixed
-- ---------------------------------------------------------------------------

T.describe("length_prefixed", function()

  T.it("encodes 4-byte big-endian length prefix by default", function()
    local codec = W.length_prefixed()
    local frame = codec:encode("hello world")
    T.eq(frame, "\x00\x00\x00\x0bhello world")
  end)

  T.it("encodes 1-byte length prefix", function()
    local codec = W.length_prefixed({ length_size = 1 })
    local frame = codec:encode("hi")
    T.eq(frame, "\x02hi")
  end)

  T.it("encodes 2-byte big-endian length prefix", function()
    local codec = W.length_prefixed({ length_size = 2, endian = "big" })
    local frame = codec:encode("hello")
    T.eq(frame, "\x00\x05hello")
  end)

  T.it("encodes 2-byte little-endian length prefix", function()
    local codec = W.length_prefixed({ length_size = 2, endian = "little" })
    local frame = codec:encode("hello")
    T.eq(frame, "\x05\x00hello")
  end)

  T.it("encodes 4-byte little-endian length prefix", function()
    local codec = W.length_prefixed({ length_size = 4, endian = "little" })
    local frame = codec:encode("hello")
    T.eq(frame, "\x05\x00\x00\x00hello")
  end)

  T.it("round-trips encode/decode", function()
    local codec = W.length_prefixed()
    local frame = codec:encode("hello world")
    local payload, rest = codec:decode(frame)
    T.eq(payload, "hello world")
    T.eq(rest, "")
  end)

  T.it("decode returns remainder", function()
    local codec = W.length_prefixed()
    local frame = codec:encode("hello") .. codec:encode("world")
    local payload, rest = codec:decode(frame)
    T.eq(payload, "hello")
    local payload2, rest2 = codec:decode(rest)
    T.eq(payload2, "world")
    T.eq(rest2, "")
  end)

  T.it("encode rejects payload exceeding max_frame_size", function()
    local codec = W.length_prefixed({ max_frame_size = 4 })
    local result, err = codec:encode("hello")
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("decode rejects frame exceeding max_frame_size", function()
    local encoder = W.length_prefixed()
    local frame = encoder:encode("hello world")
    local decoder_codec = W.length_prefixed({ max_frame_size = 4 })
    local result, err = decoder_codec:decode(frame)
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("include_length: length counts header+payload", function()
    local codec = W.length_prefixed({ include_length = true })
    local frame = codec:encode("hi")
    -- length = 4 (header) + 2 (payload) = 6
    T.eq(frame, "\x00\x00\x00\x06hi")
    local payload, rest = codec:decode(frame)
    T.eq(payload, "hi")
    T.eq(rest, "")
  end)

end)

-- ---------------------------------------------------------------------------
-- length_prefixed decoder (streaming)
-- ---------------------------------------------------------------------------

T.describe("length_prefixed decoder", function()

  T.it("returns empty when data is partial (header only)", function()
    local codec = W.length_prefixed()
    local dec = codec:decoder()
    dec:feed("\x00\x00\x00\x0b")  -- header only
    local msgs = dec:messages()
    T.eq(#msgs, 0)
  end)

  T.it("returns message after complete frame is fed", function()
    local codec = W.length_prefixed()
    local dec = codec:decoder()
    dec:feed("\x00\x00\x00\x0b")
    dec:feed("hello world")
    local msgs = dec:messages()
    T.eq(#msgs, 1)
    T.eq(msgs[1], "hello world")
  end)

  T.it("handles byte-by-byte feeding", function()
    local codec = W.length_prefixed({ length_size = 1 })
    local frame = codec:encode("abc")
    local dec = codec:decoder()
    for i = 1, #frame do
      dec:feed(frame:sub(i, i))
    end
    local msgs = dec:messages()
    T.eq(#msgs, 1)
    T.eq(msgs[1], "abc")
  end)

  T.it("handles multiple frames in one feed", function()
    local codec = W.length_prefixed()
    local dec = codec:decoder()
    local batch = codec:encode("foo") .. codec:encode("bar") .. codec:encode("baz")
    dec:feed(batch)
    local msgs = dec:messages()
    T.eq(#msgs, 3)
    T.eq(msgs[1], "foo")
    T.eq(msgs[2], "bar")
    T.eq(msgs[3], "baz")
  end)

  T.it("handles split across two feeds", function()
    local codec = W.length_prefixed()
    local frame = codec:encode("hello world")
    local dec = codec:decoder()
    dec:feed(frame:sub(1, 7))
    T.eq(#dec:messages(), 0)
    dec:feed(frame:sub(8))
    local msgs = dec:messages()
    T.eq(#msgs, 1)
    T.eq(msgs[1], "hello world")
  end)

  T.it("returns error when frame too large", function()
    local codec = W.length_prefixed({ max_frame_size = 4 })
    local dec = codec:decoder()
    -- manually craft a frame with length = 100
    dec:feed("\x00\x00\x00\x64" .. ("x"):rep(100))
    local msgs, err = dec:messages()
    T.eq(msgs, nil)
    T.ok(err ~= nil)
  end)

  T.it("little-endian decoder works", function()
    local codec = W.length_prefixed({ endian = "little" })
    local dec = codec:decoder()
    dec:feed(codec:encode("test"))
    local msgs = dec:messages()
    T.eq(#msgs, 1)
    T.eq(msgs[1], "test")
  end)

end)

-- ---------------------------------------------------------------------------
-- delimited
-- ---------------------------------------------------------------------------

T.describe("delimited", function()

  T.it("encodes with newline delimiter by default", function()
    local codec = W.delimited()
    T.eq(codec:encode("hello"), "hello\n")
  end)

  T.it("encodes with custom delimiter", function()
    local codec = W.delimited({ delimiter = "\r\n" })
    T.eq(codec:encode("hello"), "hello\r\n")
  end)

  T.it("encodes with null-byte delimiter", function()
    local codec = W.delimited({ delimiter = "\0" })
    T.eq(codec:encode("hello"), "hello\0")
  end)

  T.it("decode strips delimiter by default", function()
    local codec = W.delimited()
    local payload, rest = codec:decode("hello\nworld\n")
    T.eq(payload, "hello")
    T.eq(rest, "world\n")
  end)

  T.it("decode keeps delimiter when strip_delimiter=false", function()
    local codec = W.delimited({ strip_delimiter = false })
    local payload, rest = codec:decode("hello\nworld\n")
    T.eq(payload, "hello\n")
    T.eq(rest, "world\n")
  end)

  T.it("decode returns error when delimiter not found", function()
    local codec = W.delimited()
    local result, err = codec:decode("hello")
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("encode rejects payload exceeding max_frame_size", function()
    local codec = W.delimited({ max_frame_size = 3 })
    local result, err = codec:encode("hello")
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

end)

-- ---------------------------------------------------------------------------
-- delimited decoder (streaming)
-- ---------------------------------------------------------------------------

T.describe("delimited decoder", function()

  T.it("returns multiple messages from one feed", function()
    local codec = W.delimited()
    local dec = codec:decoder()
    dec:feed("hello\nworld\n")
    local msgs = dec:messages()
    T.eq(#msgs, 2)
    T.eq(msgs[1], "hello")
    T.eq(msgs[2], "world")
  end)

  T.it("returns empty on partial message", function()
    local codec = W.delimited()
    local dec = codec:decoder()
    dec:feed("hello")
    local msgs = dec:messages()
    T.eq(#msgs, 0)
  end)

  T.it("handles message split across two feeds", function()
    local codec = W.delimited()
    local dec = codec:decoder()
    dec:feed("hel")
    dec:feed("lo\n")
    local msgs = dec:messages()
    T.eq(#msgs, 1)
    T.eq(msgs[1], "hello")
  end)

  T.it("custom delimiter", function()
    local codec = W.delimited({ delimiter = "|" })
    local dec = codec:decoder()
    dec:feed("alpha|beta|gamma|")
    local msgs = dec:messages()
    T.eq(#msgs, 3)
    T.eq(msgs[1], "alpha")
    T.eq(msgs[2], "beta")
    T.eq(msgs[3], "gamma")
  end)

end)

-- ---------------------------------------------------------------------------
-- fixed
-- ---------------------------------------------------------------------------

T.describe("fixed", function()

  T.it("returns payload unchanged when exact size", function()
    local codec = W.fixed({ size = 15 })
    T.eq(codec:encode("Hello, World!!!"), "Hello, World!!!")
  end)

  T.it("pads short payload with null bytes", function()
    local codec = W.fixed({ size = 8 })
    T.eq(codec:encode("hi"), "hi\x00\x00\x00\x00\x00\x00")
  end)

  T.it("truncates long payload", function()
    local codec = W.fixed({ size = 4 })
    T.eq(codec:encode("hello world"), "hell")
  end)

  T.it("pads with custom byte", function()
    local codec = W.fixed({ size = 5, pad = 0x20 })
    T.eq(codec:encode("hi"), "hi   ")
  end)

  T.it("decode returns frame and remainder", function()
    local codec = W.fixed({ size = 4 })
    local payload, rest = codec:decode("helloworld")
    T.eq(payload, "hell")
    T.eq(rest, "oworld")
  end)

  T.it("decode errors on insufficient data", function()
    local codec = W.fixed({ size = 8 })
    local result, err = codec:decode("hi")
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("decode_all splits into frames", function()
    local codec = W.fixed({ size = 8 })
    -- two 8-byte frames: "Hello!!!" and "World!!!"
    local frames = codec:decode_all("Hello!!!World!!!")
    T.eq(#frames, 2)
    T.eq(frames[1], "Hello!!!")
    T.eq(frames[2], "World!!!")
  end)

  T.it("decode_all ignores trailing incomplete frame", function()
    local codec = W.fixed({ size = 4 })
    local frames = codec:decode_all("abcdefghij")  -- 10 bytes = 2 full + 2 leftover
    T.eq(#frames, 2)
    T.eq(frames[1], "abcd")
    T.eq(frames[2], "efgh")
  end)

  T.it("streaming decoder works", function()
    local codec = W.fixed({ size = 4 })
    local dec = codec:decoder()
    dec:feed("ab")
    T.eq(#dec:messages(), 0)
    dec:feed("cdefgh")
    -- "abcdefgh" = 8 bytes = 2 complete frames; messages() returns both at once
    local msgs = dec:messages()
    T.eq(#msgs, 2)
    T.eq(msgs[1], "abcd")
    T.eq(msgs[2], "efgh")
  end)

end)

-- ---------------------------------------------------------------------------
-- TLV
-- ---------------------------------------------------------------------------

T.describe("tlv", function()

  T.it("encodes and decodes a basic frame", function()
    local codec = W.tlv()
    local frame = codec:encode(0x01, "hello")
    T.ok(#frame == 1 + 2 + 5)  -- type(1) + length(2) + payload(5)
    local type_id, value = codec:decode(frame)
    T.eq(type_id, 1)
    T.eq(value, "hello")
  end)

  T.it("handles type_size=2", function()
    local codec = W.tlv({ type_size = 2, length_size = 2 })
    local frame = codec:encode(0x0102, "data")
    local type_id, value = codec:decode(frame)
    T.eq(type_id, 0x0102)
    T.eq(value, "data")
  end)

  T.it("handles little-endian", function()
    local codec = W.tlv({ endian = "little" })
    local frame = codec:encode(0x01, "test")
    local type_id, value = codec:decode(frame)
    T.eq(type_id, 1)
    T.eq(value, "test")
  end)

  T.it("handles empty value", function()
    local codec = W.tlv()
    local frame = codec:encode(0x05, "")
    local type_id, value = codec:decode(frame)
    T.eq(type_id, 5)
    T.eq(value, "")
  end)

  T.it("encode rejects value exceeding max_frame_size", function()
    local codec = W.tlv({ max_frame_size = 3 })
    local result, err = codec:encode(1, "hello")
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("decode errors on incomplete frame", function()
    local codec = W.tlv()
    local result, err = codec:decode("\x01\x00")  -- only type+partial length
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("multiple TLV types round-trip", function()
    local codec = W.tlv()
    for _, pair in ipairs({ {0x01, "ping"}, {0x02, "pong"}, {0xff, "data"} }) do
      local frame = codec:encode(pair[1], pair[2])
      local tid, val = codec:decode(frame)
      T.eq(tid, pair[1])
      T.eq(val, pair[2])
    end
  end)

end)

-- ---------------------------------------------------------------------------
-- varint
-- ---------------------------------------------------------------------------

T.describe("varint", function()

  local function rt(v)
    local enc = W.encode_varint(v)
    local dec, consumed = W.decode_varint(enc)
    T.eq(dec, v)
    T.eq(consumed, #enc)
  end

  T.it("encodes and decodes 0", function() rt(0) end)
  T.it("encodes and decodes 1", function() rt(1) end)
  T.it("encodes and decodes 127 (1 byte boundary)", function()
    local enc = W.encode_varint(127)
    T.eq(#enc, 1)
    rt(127)
  end)
  T.it("encodes and decodes 128 (2 byte boundary)", function()
    local enc = W.encode_varint(128)
    T.eq(#enc, 2)
    rt(128)
  end)
  T.it("encodes and decodes 300", function() rt(300) end)
  T.it("encodes and decodes 12345", function() rt(12345) end)
  T.it("encodes and decodes 2^21-1", function() rt(2^21 - 1) end)
  T.it("encodes and decodes large value 2^28", function() rt(2^28) end)

  T.it("decode at offset works", function()
    local enc = W.encode_varint(300)
    local val, consumed = W.decode_varint("XX" .. enc, 3)
    T.eq(val, 300)
    T.eq(consumed, #enc)
  end)

  T.it("decode returns error on incomplete varint", function()
    -- A byte with MSB set signals continuation; empty after that is incomplete
    local val, err = W.decode_varint("\x80")
    T.eq(val, nil)
    T.ok(err ~= nil)
  end)

  T.it("encode returns error for negative value", function()
    local result, err = W.encode_varint(-1)
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

end)

-- ---------------------------------------------------------------------------
-- pack / unpack
-- ---------------------------------------------------------------------------

T.describe("pack/unpack", function()

  T.it("packs and unpacks uint8", function()
    local s = W.pack(">B", 255)
    T.eq(#s, 1)
    local v = W.unpack(">B", s)
    T.eq(v, 255)
  end)

  T.it("packs and unpacks uint16 big-endian", function()
    local s = W.pack(">H", 0x0102)
    T.eq(s, "\x01\x02")
    local v = W.unpack(">H", s)
    T.eq(v, 0x0102)
  end)

  T.it("packs and unpacks uint16 little-endian", function()
    local s = W.pack("<H", 0x0102)
    T.eq(s, "\x02\x01")
    local v = W.unpack("<H", s)
    T.eq(v, 0x0102)
  end)

  T.it("packs and unpacks uint32 big-endian", function()
    local s = W.pack(">I", 100000)
    T.eq(#s, 4)
    local v = W.unpack(">I", s)
    T.eq(v, 100000)
  end)

  T.it("packs and unpacks uint32 little-endian", function()
    local s = W.pack("<I", 100000)
    T.eq(#s, 4)
    local v = W.unpack("<I", s)
    T.eq(v, 100000)
  end)

  T.it("packs and unpacks int8 negative", function()
    local s = W.pack(">b", -1)
    T.eq(#s, 1)
    local v = W.unpack(">b", s)
    T.eq(v, -1)
  end)

  T.it("packs and unpacks int16 negative", function()
    local s = W.pack(">h", -300)
    T.eq(#s, 2)
    local v = W.unpack(">h", s)
    T.eq(v, -300)
  end)

  T.it("packs and unpacks int32 negative", function()
    local s = W.pack(">i", -100000)
    T.eq(#s, 4)
    local v = W.unpack(">i", s)
    T.eq(v, -100000)
  end)

  T.it("packs and unpacks mixed format >BHI", function()
    local s = W.pack(">BHI", 1, 300, 100000)
    T.eq(#s, 7)
    local a, b, c = W.unpack(">BHI", s)
    T.eq(a, 1)
    T.eq(b, 300)
    T.eq(c, 100000)
  end)

  T.it("packs and unpacks string field", function()
    local s = W.pack(">Bs", 42, "hello")
    local a, b = W.unpack(">Bs", s)
    T.eq(a, 42)
    T.eq(b, "hello")
  end)

  T.it("packs and unpacks uint64 big-endian", function()
    local s = W.pack(">Q", 2^32 + 1)
    T.eq(#s, 8)
    local v = W.unpack(">Q", s)
    T.eq(v, 2^32 + 1)
  end)

  T.it("no endian prefix defaults to big-endian", function()
    local s_explicit = W.pack(">H", 0x0304)
    local s_default = W.pack("H", 0x0304)
    T.eq(s_default, s_explicit)
  end)

end)

-- ---------------------------------------------------------------------------
-- framer
-- ---------------------------------------------------------------------------

T.describe("framer", function()

  T.it("buffers encoded frames", function()
    local codec = W.length_prefixed()
    local fr = W.framer(codec)
    fr:write("hello")
    fr:write("world")
    local pending = fr:pending()
    T.eq(pending, codec:encode("hello") .. codec:encode("world"))
  end)

  T.it("flush returns and clears buffer", function()
    local codec = W.length_prefixed()
    local fr = W.framer(codec)
    fr:write("hello")
    local out = fr:flush()
    T.eq(out, codec:encode("hello"))
    T.eq(fr:flush(), "")
  end)

  T.it("pending does not clear buffer", function()
    local codec = W.length_prefixed()
    local fr = W.framer(codec)
    fr:write("hello")
    fr:pending()
    fr:pending()
    T.eq(fr:flush(), codec:encode("hello"))
  end)

  T.it("works with delimited codec", function()
    local codec = W.delimited()
    local fr = W.framer(codec)
    fr:write("foo")
    fr:write("bar")
    T.eq(fr:flush(), "foo\nbar\n")
  end)

end)

-- ---------------------------------------------------------------------------
-- receiver
-- ---------------------------------------------------------------------------

T.describe("receiver", function()

  T.it("has_message returns false initially", function()
    local codec = W.length_prefixed()
    local rv = W.receiver(codec)
    T.eq(rv:has_message(), false)
  end)

  T.it("has_message returns true after complete frame", function()
    local codec = W.length_prefixed()
    local rv = W.receiver(codec)
    rv:feed(codec:encode("hello"))
    T.ok(rv:has_message())
  end)

  T.it("next returns message and advances queue", function()
    local codec = W.length_prefixed()
    local rv = W.receiver(codec)
    rv:feed(codec:encode("hello"))
    rv:feed(codec:encode("world"))
    T.eq(rv:next(), "hello")
    T.eq(rv:next(), "world")
    T.eq(rv:has_message(), false)
    T.eq(rv:next(), nil)
  end)

  T.it("handles partial feed correctly", function()
    local codec = W.length_prefixed()
    local frame = codec:encode("test")
    local rv = W.receiver(codec)
    rv:feed(frame:sub(1, 3))
    T.eq(rv:has_message(), false)
    rv:feed(frame:sub(4))
    T.ok(rv:has_message())
    T.eq(rv:next(), "test")
  end)

  T.it("works with delimited codec", function()
    local codec = W.delimited()
    local rv = W.receiver(codec)
    rv:feed("line1\nline2\n")
    T.eq(rv:next(), "line1")
    T.eq(rv:next(), "line2")
    T.eq(rv:has_message(), false)
  end)

end)
