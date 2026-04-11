-- lib/asn1/asn1_test.lua
-- Comprehensive tests for lib/asn1 DER parser and writer.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local asn1 = require("lib.asn1")

-- Helper: convert binary string to hex for readable assertions
local function to_hex(s)
  return (s:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

-- Test data constants
-- SEQUENCE { INTEGER(42), BOOLEAN(true) }
local SEQ_INT_BOOL = "\x30\x06\x02\x01\x2a\x01\x01\xff"
-- NULL
local NULL_BYTES   = "\x05\x00"
-- OID sha256WithRSAEncryption (1.2.840.113549.1.1.11)
local OID_SHA256_RSA = "\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0b"

T.describe("lib.asn1", function()

  T.describe("tier", function()
    T.it("M._tier is 'pure'", function()
      T.eq(asn1._tier, "pure")
    end)
  end)

  -- ── decode_tlv ────────────────────────────────────────────────────────────

  T.describe("decode_tlv", function()

    T.it("NULL: tag=5, class=universal, length=0", function()
      local node, err = asn1.decode_tlv(NULL_BYTES)
      T.ok(node, err)
      T.eq(node.tag, 5)
      T.eq(node.class, "universal")
      T.eq(node.constructed, false)
      T.eq(node.length, 0)
      T.eq(node.value, "")
      T.eq(node.next_pos, 3)
    end)

    T.it("INTEGER 42: tag=2, value=\\x2a", function()
      local node, err = asn1.decode_tlv("\x02\x01\x2a")
      T.ok(node, err)
      T.eq(node.tag, 2)
      T.eq(node.class, "universal")
      T.eq(node.constructed, false)
      T.eq(node.length, 1)
      T.eq(to_hex(node.value), "2a")
      T.eq(node.next_pos, 4)
    end)

    T.it("BOOLEAN true: tag=1, value=\\xff", function()
      local node, err = asn1.decode_tlv("\x01\x01\xff")
      T.ok(node, err)
      T.eq(node.tag, 1)
      T.eq(node.class, "universal")
      T.eq(node.length, 1)
      T.eq(to_hex(node.value), "ff")
    end)

    T.it("SEQUENCE is constructed", function()
      local node, err = asn1.decode_tlv(SEQ_INT_BOOL)
      T.ok(node, err)
      T.eq(node.tag, 16)
      T.eq(node.constructed, true)
      T.eq(node.class, "universal")
      T.eq(node.length, 6)
      -- SEQ_INT_BOOL is 8 bytes (1 tag + 1 len + 6 value), next_pos = 9
      T.eq(node.next_pos, 9)
    end)

    T.it("multi-byte length (>127 bytes)", function()
      -- Build: OCTET STRING with 128 zero bytes → length encoded as \x81\x80
      -- Tag(1) + LenPrefix(1) + LenVal(1) + Value(128) = 131 bytes total, next_pos=132
      local value = string.rep("\x00", 128)
      local encoded = "\x04\x81\x80" .. value
      local node, err = asn1.decode_tlv(encoded)
      T.ok(node, err)
      T.eq(node.tag, 4)
      T.eq(node.length, 128)
      T.eq(node.next_pos, 132)  -- tag(1) + len_prefix(1) + len_val(1) + value(128) → pos 1+3+128=132
    end)

    T.it("two-byte length field (\\x82 prefix)", function()
      -- OCTET STRING with 256 bytes → \x82\x01\x00
      -- tag(1) + len_prefix(1) + len_val(2) + value(256) = 260 bytes, next_pos=261
      local value = string.rep("\xab", 256)
      local encoded = "\x04\x82\x01\x00" .. value
      local node, err = asn1.decode_tlv(encoded)
      T.ok(node, err)
      T.eq(node.tag, 4)
      T.eq(node.length, 256)
      T.eq(node.next_pos, 261)
    end)

    T.it("pos parameter offsets into string", function()
      -- Prepend a NULL, then an INTEGER
      local data = NULL_BYTES .. "\x02\x01\x2a"
      local node, err = asn1.decode_tlv(data, 3)  -- skip past NULL
      T.ok(node, err)
      T.eq(node.tag, 2)
      T.eq(node.next_pos, 6)
    end)

    T.it("next_pos after SEQUENCE is correct", function()
      local node, err = asn1.decode_tlv(SEQ_INT_BOOL)
      T.ok(node, err)
      -- SEQ_INT_BOOL is 8 bytes (tag=1, len=1, value=6); starting at pos=1, next_pos=9
      T.eq(node.next_pos, 9)
    end)

    T.it("context-class tag", function()
      -- Context [0] primitive: tag byte = 0x80
      local data = "\x80\x03\x01\x02\x03"
      local node, err = asn1.decode_tlv(data)
      T.ok(node, err)
      T.eq(node.tag, 0)
      T.eq(node.class, "context")
      T.eq(node.constructed, false)
      T.eq(node.length, 3)
    end)

    T.it("returns nil,errmsg on truncated data", function()
      local node, err = asn1.decode_tlv("\x02\x04\x01\x02")  -- says 4 bytes, only 2
      T.eq(node, nil)
      T.ok(err)
    end)

    T.it("returns nil,errmsg on empty input", function()
      local node, err = asn1.decode_tlv("")
      T.eq(node, nil)
      T.ok(err)
    end)

  end)

  -- ── decode_sequence ───────────────────────────────────────────────────────

  T.describe("decode_sequence", function()

    T.it("parses SEQUENCE body into 2-element array", function()
      -- Skip the outer SEQUENCE TLV wrapper, parse the body
      local seq_node, err = asn1.decode_tlv(SEQ_INT_BOOL)
      T.ok(seq_node, err)
      local items, e2 = asn1.decode_sequence(seq_node.value)
      T.ok(items, e2)
      T.eq(#items, 2)
    end)

    T.it("first child is INTEGER 42", function()
      local seq_node = asn1.decode_tlv(SEQ_INT_BOOL)
      local items    = asn1.decode_sequence(seq_node.value)
      T.eq(items[1].tag, 2)
      T.eq(to_hex(items[1].value), "2a")
    end)

    T.it("second child is BOOLEAN", function()
      local seq_node = asn1.decode_tlv(SEQ_INT_BOOL)
      local items    = asn1.decode_sequence(seq_node.value)
      T.eq(items[2].tag, 1)
      T.eq(to_hex(items[2].value), "ff")
    end)

    T.it("empty body returns empty array", function()
      local items, err = asn1.decode_sequence("")
      T.ok(items, err)
      T.eq(#items, 0)
    end)

    T.it("pos/end_pos window works", function()
      -- Put two NULLs in a string, parse only the second
      local data = NULL_BYTES .. NULL_BYTES
      local items, err = asn1.decode_sequence(data, 3, 4)
      T.ok(items, err)
      T.eq(#items, 1)
      T.eq(items[1].tag, 5)
    end)

  end)

  -- ── Typed decoders ────────────────────────────────────────────────────────

  T.describe("typed decoders", function()

    T.it("decode_integer(\\x2a) → 42", function()
      local v, err = asn1.decode_integer("\x2a")
      T.ok(v ~= nil, err)
      T.eq(v, 42)
    end)

    T.it("decode_integer(\\x00\\x80) → 128 (needs leading zero)", function()
      local v, err = asn1.decode_integer("\x00\x80")
      T.ok(v ~= nil, err)
      T.eq(v, 128)
    end)

    T.it("decode_integer(\\xff) → -1", function()
      local v, err = asn1.decode_integer("\xff")
      T.ok(v ~= nil, err)
      T.eq(v, -1)
    end)

    T.it("decode_integer(\\x80) → -128", function()
      local v, err = asn1.decode_integer("\x80")
      T.ok(v ~= nil, err)
      T.eq(v, -128)
    end)

    T.it("decode_integer(\\x00) → 0", function()
      local v, err = asn1.decode_integer("\x00")
      T.ok(v ~= nil, err)
      T.eq(v, 0)
    end)

    T.it("decode_boolean(\\xff) → true", function()
      local v, err = asn1.decode_boolean("\xff")
      T.ok(v ~= nil, err)
      T.eq(v, true)
    end)

    T.it("decode_boolean(\\x00) → false", function()
      local v, err = asn1.decode_boolean("\x00")
      -- false is a valid return; use neq(v, nil) to check for error
      T.eq(v, false)
      T.eq(err, nil)
    end)

    T.it("decode_boolean errors on wrong length", function()
      local v, err = asn1.decode_boolean("\xff\x00")
      T.eq(v, nil)
      T.ok(err)
    end)

    T.it("decode_oid sha256WithRSAEncryption → 1.2.840.113549.1.1.11", function()
      -- Strip the tag (\x06) and length (\x09) bytes from OID_SHA256_RSA
      local value_bytes = string.sub(OID_SHA256_RSA, 3)
      local v, err = asn1.decode_oid(value_bytes)
      T.ok(v, err)
      T.eq(v, "1.2.840.113549.1.1.11")
    end)

    T.it("decode_oid simple 1.2.3 → '1.2.3'", function()
      -- 1.2.3: first byte = 1*40+2=42=0x2a, then 0x03
      local v, err = asn1.decode_oid("\x2a\x03")
      T.ok(v, err)
      T.eq(v, "1.2.3")
    end)

    T.it("decode_string returns raw bytes", function()
      local v, err = asn1.decode_string("hello")
      T.eq(v, "hello")
      T.eq(err, nil)
    end)

    T.it("decode_bit_string: first byte is unused_bits, rest is bits", function()
      -- \x00\xde\xad = 0 unused bits, data = \xde\xad
      local v, err = asn1.decode_bit_string("\x00\xde\xad")
      T.ok(v, err)
      T.eq(v.unused_bits, 0)
      T.eq(to_hex(v.bits), "dead")
    end)

    T.it("decode_bit_string: unused_bits=3", function()
      local v, err = asn1.decode_bit_string("\x03\xf0")
      T.ok(v, err)
      T.eq(v.unused_bits, 3)
      T.eq(to_hex(v.bits), "f0")
    end)

    T.it("decode_time UTCTime → ISO 8601", function()
      local v, err = asn1.decode_time("230101120000Z", asn1.TAG_UTCTIME)
      T.ok(v, err)
      T.eq(v, "2023-01-01T12:00:00Z")
    end)

    T.it("decode_time UTCTime YY>=50 → 19xx", function()
      local v, err = asn1.decode_time("991231235959Z", asn1.TAG_UTCTIME)
      T.ok(v, err)
      T.eq(v, "1999-12-31T23:59:59Z")
    end)

    T.it("decode_time GeneralizedTime → ISO 8601", function()
      local v, err = asn1.decode_time("20230101120000Z", asn1.TAG_GENERALIZEDTIME)
      T.ok(v, err)
      T.eq(v, "2023-01-01T12:00:00Z")
    end)

  end)

  -- ── High-level decode() ───────────────────────────────────────────────────

  T.describe("decode", function()

    T.it("NULL → type='null', value=nil", function()
      local node, err = asn1.decode(NULL_BYTES)
      T.ok(node, err)
      T.eq(node.type, "null")
      T.eq(node.value, nil)
    end)

    T.it("INTEGER 42 → type='integer', value=42", function()
      local node, err = asn1.decode("\x02\x01\x2a")
      T.ok(node, err)
      T.eq(node.type, "integer")
      T.eq(node.value, 42)
    end)

    T.it("BOOLEAN true → type='boolean', value=true", function()
      local node, err = asn1.decode("\x01\x01\xff")
      T.ok(node, err)
      T.eq(node.type, "boolean")
      T.eq(node.value, true)
    end)

    T.it("OID → type='oid', value=dotted string", function()
      local node, err = asn1.decode(OID_SHA256_RSA)
      T.ok(node, err)
      T.eq(node.type, "oid")
      T.eq(node.value, "1.2.840.113549.1.1.11")
    end)

    T.it("SEQUENCE → type='sequence', value=array of nodes", function()
      local node, err = asn1.decode(SEQ_INT_BOOL)
      T.ok(node, err)
      T.eq(node.type, "sequence")
      T.eq(type(node.value), "table")
      T.eq(#node.value, 2)
    end)

  end)

  -- ── Encoding ─────────────────────────────────────────────────────────────

  T.describe("encode", function()

    T.it("encode_null → \\x05\\x00", function()
      T.eq(to_hex(asn1.encode_null()), "0500")
    end)

    T.it("encode_boolean(true) → \\x01\\x01\\xff", function()
      T.eq(to_hex(asn1.encode_boolean(true)), "0101ff")
    end)

    T.it("encode_boolean(false) → \\x01\\x01\\x00", function()
      T.eq(to_hex(asn1.encode_boolean(false)), "010100")
    end)

    T.it("encode_integer(0) → \\x02\\x01\\x00", function()
      T.eq(to_hex(asn1.encode_integer(0)), "020100")
    end)

    T.it("encode_integer(42) → \\x02\\x01\\x2a", function()
      T.eq(to_hex(asn1.encode_integer(42)), "02012a")
    end)

    T.it("encode_integer(127) → \\x02\\x01\\x7f", function()
      T.eq(to_hex(asn1.encode_integer(127)), "02017f")
    end)

    T.it("encode_integer(128) → \\x02\\x02\\x00\\x80 (leading zero)", function()
      T.eq(to_hex(asn1.encode_integer(128)), "02020080")
    end)

    T.it("encode_integer(-1) → \\x02\\x01\\xff", function()
      T.eq(to_hex(asn1.encode_integer(-1)), "0201ff")
    end)

    T.it("encode_integer(-128) → \\x02\\x01\\x80", function()
      T.eq(to_hex(asn1.encode_integer(-128)), "020180")
    end)

    T.it("encode_integer(-129) → \\x02\\x02\\xff\\x7f", function()
      T.eq(to_hex(asn1.encode_integer(-129)), "0202ff7f")
    end)

    T.it("encode_integer(256) → \\x02\\x02\\x01\\x00", function()
      T.eq(to_hex(asn1.encode_integer(256)), "02020100")
    end)

    T.it("encode_octet_string encodes tag+length+bytes", function()
      local enc = asn1.encode_octet_string("\xde\xad\xbe\xef")
      T.eq(to_hex(enc), "0404deadbeef")
    end)

    T.it("encode_utf8_string", function()
      local enc = asn1.encode_utf8_string("hi")
      T.eq(to_hex(enc), "0c026869")
    end)

    T.it("encode_sequence wraps items", function()
      local enc = asn1.encode_sequence({
        asn1.encode_integer(42),
        asn1.encode_boolean(true),
      })
      T.eq(to_hex(enc), to_hex(SEQ_INT_BOOL))
    end)

    T.it("encode_oid sha256WithRSAEncryption → known bytes", function()
      local enc, err = asn1.encode_oid("1.2.840.113549.1.1.11")
      T.ok(enc, err)
      T.eq(to_hex(enc), to_hex(OID_SHA256_RSA))
    end)

    T.it("encode_oid 1.2.3", function()
      local enc, err = asn1.encode_oid("1.2.3")
      T.ok(enc, err)
      -- tag=0x06, len=0x02, first_byte=1*40+2=42=0x2a, 0x03
      T.eq(to_hex(enc), "06022a03")
    end)

    T.it("encode_tlv raw: CONTEXT [3] constructed", function()
      local enc = asn1.encode_tlv(3, asn1.CLASS_CONTEXT, true, "\x01\x02")
      -- class=2(context), constructed=1, tag=3 → 0b10_1_00011 = 0xa3
      T.eq(string.byte(enc, 1), 0xa3)
      T.eq(string.byte(enc, 2), 2)   -- length
      T.eq(string.byte(enc, 3), 1)
      T.eq(string.byte(enc, 4), 2)
    end)

  end)

  -- ── Round-trips ───────────────────────────────────────────────────────────

  T.describe("round-trips", function()

    T.it("decode then re-encode NULL gives same bytes", function()
      local node = asn1.decode_tlv(NULL_BYTES)
      local re = asn1.encode_tlv(node.tag, node.class_num, node.constructed, node.value)
      T.eq(to_hex(re), to_hex(NULL_BYTES))
    end)

    T.it("decode then re-encode SEQUENCE gives same bytes", function()
      local node = asn1.decode_tlv(SEQ_INT_BOOL)
      local re = asn1.encode_tlv(node.tag, node.class_num, node.constructed, node.value)
      T.eq(to_hex(re), to_hex(SEQ_INT_BOOL))
    end)

    T.it("encode_integer(42) decodes back to 42", function()
      local enc  = asn1.encode_integer(42)
      local node = asn1.decode_tlv(enc)
      local v    = asn1.decode_integer(node.value)
      T.eq(v, 42)
    end)

    T.it("encode_integer(128) decodes back to 128", function()
      local enc  = asn1.encode_integer(128)
      local node = asn1.decode_tlv(enc)
      local v    = asn1.decode_integer(node.value)
      T.eq(v, 128)
    end)

    T.it("encode_integer(-129) decodes back to -129", function()
      local enc  = asn1.encode_integer(-129)
      local node = asn1.decode_tlv(enc)
      local v    = asn1.decode_integer(node.value)
      T.eq(v, -129)
    end)

    T.it("encode_oid round-trip for sha256WithRSAEncryption", function()
      local oid_str = "1.2.840.113549.1.1.11"
      local enc, _  = asn1.encode_oid(oid_str)
      local node    = asn1.decode_tlv(enc)
      local v       = asn1.decode_oid(node.value)
      T.eq(v, oid_str)
    end)

    T.it("encode_boolean round-trips true", function()
      local enc  = asn1.encode_boolean(true)
      local node = asn1.decode_tlv(enc)
      local v    = asn1.decode_boolean(node.value)
      T.eq(v, true)
    end)

    T.it("encode_boolean round-trips false", function()
      local enc  = asn1.encode_boolean(false)
      local node = asn1.decode_tlv(enc)
      local v    = asn1.decode_boolean(node.value)
      T.eq(v, false)
    end)

    T.it("encode_octet_string round-trips", function()
      local data = "\xca\xfe\xba\xbe"
      local enc  = asn1.encode_octet_string(data)
      local node = asn1.decode_tlv(enc)
      T.eq(to_hex(node.value), to_hex(data))
    end)

    T.it("encode_sequence round-trips full SEQ_INT_BOOL", function()
      local enc = asn1.encode_sequence({
        asn1.encode_integer(42),
        asn1.encode_boolean(true),
      })
      -- Decode outer SEQUENCE
      local outer = asn1.decode_tlv(enc)
      T.eq(outer.tag, 16)
      T.eq(outer.constructed, true)
      -- Decode inner items
      local items = asn1.decode_sequence(outer.value)
      T.eq(#items, 2)
      T.eq(asn1.decode_integer(items[1].value), 42)
      T.eq(asn1.decode_boolean(items[2].value), true)
    end)

  end)

end)
