if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local pb = require("lib.protocol_buffer")

-- ── Varint encode/decode ──────────────────────────────────────────────────────

T.describe("encode_varint / decode_varint", function()
  local function rt(n, desc)
    local encoded = pb.encode_varint(n)
    local decoded, _ = pb.decode_varint(encoded, 1)
    T.eq(decoded, n, desc or tostring(n))
  end

  T.it("encodes 0", function()
    T.eq(pb.encode_varint(0), "\0")
    local v = pb.decode_varint("\0", 1)
    T.eq(v, 0)
  end)

  T.it("encodes 1", function()
    T.eq(pb.encode_varint(1), "\1")
    rt(1)
  end)

  T.it("encodes 127 (single byte max)", function()
    T.eq(pb.encode_varint(127), "\127")
    rt(127)
  end)

  T.it("encodes 128 (two bytes)", function()
    -- 128 = 0x80 → bytes: 0x80 0x01
    T.eq(pb.encode_varint(128), "\128\1")
    rt(128)
  end)

  T.it("encodes 300", function()
    -- 300 = 0x12C → bytes: 0xAC 0x02
    T.eq(pb.encode_varint(300), "\172\2")
    rt(300)
  end)

  T.it("encodes 16384", function()
    -- 16384 = 0x4000 → bytes: 0x80 0x80 0x01
    T.eq(pb.encode_varint(16384), "\128\128\1")
    rt(16384)
  end)

  T.it("encodes max_uint32 (4294967295)", function()
    rt(4294967295, "max_uint32")
  end)

  T.it("decode returns correct next_offset", function()
    local bytes = pb.encode_varint(300) .. pb.encode_varint(1)
    local v1, off = pb.decode_varint(bytes, 1)
    T.eq(v1, 300)
    local v2 = pb.decode_varint(bytes, off)
    T.eq(v2, 1)
  end)
end)

-- ── ZigZag ────────────────────────────────────────────────────────────────────

T.describe("ZigZag encode/decode", function()
  local function rt(n)
    T.eq(pb.decode_zigzag(pb.encode_zigzag(n)), n, "zigzag roundtrip " .. tostring(n))
  end

  T.it("encodes 0 → 0", function()
    T.eq(pb.encode_zigzag(0), 0)
    rt(0)
  end)

  T.it("encodes -1 → 1", function()
    T.eq(pb.encode_zigzag(-1), 1)
    rt(-1)
  end)

  T.it("encodes 1 → 2", function()
    T.eq(pb.encode_zigzag(1), 2)
    rt(1)
  end)

  T.it("encodes -2 → 3", function()
    T.eq(pb.encode_zigzag(-2), 3)
    rt(-2)
  end)

  T.it("encodes 2147483647 → 4294967294", function()
    T.eq(pb.encode_zigzag(2147483647), 4294967294)
    rt(2147483647)
  end)

  T.it("encodes -2147483648 → 4294967295", function()
    T.eq(pb.encode_zigzag(-2147483648), 4294967295)
    rt(-2147483648)
  end)
end)

-- ── field_tag ─────────────────────────────────────────────────────────────────

T.describe("field_tag", function()
  T.it("field 1 varint = 0x08", function()
    T.eq(pb.field_tag(1, pb.WIRE_VARINT), "\8")
  end)

  T.it("field 2 len = 0x12", function()
    T.eq(pb.field_tag(2, pb.WIRE_LEN), "\18")
  end)

  T.it("field 3 32bit = 0x1D", function()
    T.eq(pb.field_tag(3, pb.WIRE_32BIT), "\29")
  end)
end)

-- ── Simple message encode/decode ──────────────────────────────────────────────

T.describe("simple message (int32 + string)", function()
  local Person = {
    name = {1, "string"},
    id   = {2, "int32"},
  }

  T.it("round-trips a simple message", function()
    local msg = {name = "Alice", id = 42}
    local bytes, err = pb.encode(Person, msg)
    T.ok(bytes, err)
    local decoded, derr = pb.decode(Person, bytes)
    T.ok(decoded, derr)
    T.eq(decoded.name, "Alice")
    T.eq(decoded.id, 42)
  end)

  T.it("omits absent optional fields", function()
    local msg = {id = 7}
    local bytes, err = pb.encode(Person, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Person, bytes)
    T.eq(decoded.id, 7)
    T.eq(decoded.name, nil)
  end)

  T.it("encodes zero id correctly", function()
    local msg = {name = "Bob", id = 0}
    local bytes, err = pb.encode(Person, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Person, bytes)
    T.eq(decoded.id, 0)
    T.eq(decoded.name, "Bob")
  end)
end)

-- ── Nested message ────────────────────────────────────────────────────────────

T.describe("nested message", function()
  local PhoneNumber = {
    number = {1, "string"},
    kind   = {2, "int32"},
  }

  local Person = {
    name  = {1, "string"},
    phone = {2, "message", schema = PhoneNumber},
  }

  T.it("round-trips nested message", function()
    local msg = {
      name  = "Carol",
      phone = {number = "555-1234", kind = 1},
    }
    local bytes, err = pb.encode(Person, msg)
    T.ok(bytes, err)
    local decoded, derr = pb.decode(Person, bytes)
    T.ok(decoded, derr)
    T.eq(decoded.name, "Carol")
    T.eq(decoded.phone.number, "555-1234")
    T.eq(decoded.phone.kind, 1)
  end)

  T.it("handles absent nested message", function()
    local msg = {name = "Dave"}
    local bytes, err = pb.encode(Person, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Person, bytes)
    T.eq(decoded.name, "Dave")
    T.eq(decoded.phone, nil)
  end)
end)

-- ── Repeated field ────────────────────────────────────────────────────────────

T.describe("repeated field", function()
  local Schema = {
    tags = {1, "string", repeated = true},
    nums = {2, "int32", repeated = true},
  }

  T.it("round-trips repeated strings", function()
    local msg = {tags = {"foo", "bar", "baz"}}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded, derr = pb.decode(Schema, bytes)
    T.ok(decoded, derr)
    T.eq(#decoded.tags, 3)
    T.eq(decoded.tags[1], "foo")
    T.eq(decoded.tags[2], "bar")
    T.eq(decoded.tags[3], "baz")
  end)

  T.it("round-trips repeated int32", function()
    local msg = {nums = {1, 2, 300, 16384}}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded, derr = pb.decode(Schema, bytes)
    T.ok(decoded, derr)
    T.eq(#decoded.nums, 4)
    T.eq(decoded.nums[1], 1)
    T.eq(decoded.nums[2], 2)
    T.eq(decoded.nums[3], 300)
    T.eq(decoded.nums[4], 16384)
  end)

  T.it("empty repeated field decodes to empty table", function()
    local msg = {tags = {}}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(type(decoded.tags), "table")
    T.eq(#decoded.tags, 0)
  end)
end)

-- ── string/bytes binary round-trip ───────────────────────────────────────────

T.describe("string and bytes fields", function()
  local Schema = {
    data = {1, "bytes"},
    text = {2, "string"},
  }

  T.it("round-trips binary bytes", function()
    local binary = "\0\1\2\255\254\253\128\127"
    local msg = {data = binary}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded, derr = pb.decode(Schema, bytes)
    T.ok(decoded, derr)
    T.eq(decoded.data, binary)
  end)

  T.it("round-trips empty string", function()
    local msg = {text = ""}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.text, "")
  end)

  T.it("round-trips unicode string", function()
    local msg = {text = "héllo wörld"}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.text, "héllo wörld")
  end)
end)

-- ── bool field ────────────────────────────────────────────────────────────────

T.describe("bool field", function()
  local Schema = {
    flag = {1, "bool"},
  }

  T.it("encodes true", function()
    local bytes, err = pb.encode(Schema, {flag = true})
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.flag, true)
  end)

  T.it("encodes false", function()
    local bytes, err = pb.encode(Schema, {flag = false})
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.flag, false)
  end)
end)

-- ── sint32/sint64 (ZigZag) round-trip ────────────────────────────────────────

T.describe("sint32 / sint64 fields", function()
  local Schema = {
    s32 = {1, "sint32"},
    s64 = {2, "sint64"},
  }

  T.it("round-trips positive sint32", function()
    local msg = {s32 = 1000}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.s32, 1000)
  end)

  T.it("round-trips negative sint32", function()
    local msg = {s32 = -1}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.s32, -1)
  end)

  T.it("round-trips -2147483648 (min int32)", function()
    local msg = {s32 = -2147483648}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.s32, -2147483648)
  end)
end)

-- ── float / double ────────────────────────────────────────────────────────────

T.describe("float and double fields", function()
  local Schema = {
    f   = {1, "float"},
    d   = {2, "double"},
  }

  T.it("round-trips a double exactly", function()
    local msg = {d = 3.14159265358979}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.d, 3.14159265358979)
  end)

  T.it("round-trips a float within float precision", function()
    local msg = {f = 3.14}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    -- float has ~7 decimal digits of precision
    T.ok(math.abs(decoded.f - 3.14) < 0.0001, "float precision")
  end)

  T.it("round-trips 0.0", function()
    local msg = {d = 0.0}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.d, 0.0)
  end)
end)

-- ── fixed32 / fixed64 ─────────────────────────────────────────────────────────

T.describe("fixed32 / fixed64 / sfixed32", function()
  local Schema = {
    u32 = {1, "fixed32"},
    i32 = {2, "sfixed32"},
    u64 = {3, "fixed64"},
  }

  T.it("round-trips fixed32", function()
    local msg = {u32 = 4294967295}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.u32, 4294967295)
  end)

  T.it("round-trips sfixed32 negative", function()
    local msg = {i32 = -1}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.i32, -1)
  end)

  T.it("round-trips fixed64", function()
    local msg = {u64 = 1099511627776}  -- 2^40
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.u64, 1099511627776)
  end)
end)

-- ── encode_raw / decode_raw ───────────────────────────────────────────────────

T.describe("encode_raw / decode_raw", function()
  T.it("encodes and decodes raw fields", function()
    local fields = {
      {1, pb.WIRE_VARINT, 42},
      {2, pb.WIRE_LEN, "hello"},
    }
    local bytes = pb.encode_raw(fields)
    T.ok(type(bytes) == "string" and #bytes > 0, "got bytes")

    local decoded, err = pb.decode_raw(bytes)
    T.ok(decoded, err)
    T.eq(#decoded, 2)
    T.eq(decoded[1][1], 1)              -- field number
    T.eq(decoded[1][2], pb.WIRE_VARINT) -- wire type
    T.eq(decoded[1][3], 42)             -- value
    T.eq(decoded[2][1], 2)
    T.eq(decoded[2][2], pb.WIRE_LEN)
    T.eq(decoded[2][3], "hello")
  end)

  T.it("handles empty bytes", function()
    local decoded, err = pb.decode_raw("")
    T.ok(decoded, err)
    T.eq(#decoded, 0)
  end)

  T.it("returns error on unknown wire type in raw bytes", function()
    -- Wire type 3 is undefined in protobuf
    -- Construct a byte with field 1, wire type 3: tag = (1<<3)|3 = 11 = 0x0B
    local bad = string.char(0x0B)
    local result, err = pb.decode_raw(bad)
    T.eq(result, nil)
    T.ok(err:find("unknown wire type"), "error mentions unknown wire type")
  end)
end)

-- ── Required field validation ─────────────────────────────────────────────────

T.describe("required field validation", function()
  local Schema = {
    name = {1, "string", required = true},
    id   = {2, "int32"},
  }

  T.it("encode returns error when required field missing", function()
    local result, err = pb.encode(Schema, {id = 5})
    T.eq(result, nil)
    T.ok(err ~= nil, "should have error")
    T.ok(err:find("required"), "error mentions required")
  end)

  T.it("validate returns error list for missing required field", function()
    local ok, errors = pb.validate(Schema, {id = 5})
    T.eq(ok, false)
    T.ok(errors ~= nil)
    T.ok(#errors > 0)
    T.ok(errors[1]:find("name"), "error names the field")
  end)

  T.it("validate passes when required field present", function()
    local ok, errors = pb.validate(Schema, {name = "Eve", id = 1})
    T.eq(ok, true)
    T.eq(errors, nil)
  end)
end)

-- ── Unknown fields preserved ──────────────────────────────────────────────────

T.describe("unknown fields", function()
  local SchemaFull = {
    name  = {1, "string"},
    extra = {2, "int32"},
  }
  local SchemaPart = {
    name = {1, "string"},
    -- field 2 not present in partial schema
  }

  T.it("preserves unknown fields in _unknown", function()
    -- Encode with full schema
    local bytes, err = pb.encode(SchemaFull, {name = "Frank", extra = 99})
    T.ok(bytes, err)
    -- Decode with partial schema
    local decoded, derr = pb.decode(SchemaPart, bytes)
    T.ok(decoded, derr)
    T.eq(decoded.name, "Frank")
    T.ok(decoded._unknown ~= nil, "should have _unknown")
    T.eq(#decoded._unknown, 1)
    T.eq(decoded._unknown[1][1], 2)             -- field number
    T.eq(decoded._unknown[1][2], pb.WIRE_VARINT) -- wire type
    T.eq(decoded._unknown[1][3], 99)            -- value
  end)
end)

-- ── Packed repeated ───────────────────────────────────────────────────────────

T.describe("packed repeated field", function()
  local Schema = {
    scores = {1, "int32", repeated = true, packed = true},
  }

  T.it("round-trips packed repeated int32", function()
    local msg = {scores = {1, 10, 100, 1000}}
    local bytes, err = pb.encode(Schema, msg)
    T.ok(bytes, err)
    local decoded, derr = pb.decode(Schema, bytes)
    T.ok(decoded, derr)
    T.eq(#decoded.scores, 4)
    T.eq(decoded.scores[1], 1)
    T.eq(decoded.scores[2], 10)
    T.eq(decoded.scores[3], 100)
    T.eq(decoded.scores[4], 1000)
  end)
end)

-- ── Negative int32 encoding ───────────────────────────────────────────────────

T.describe("negative int32 encoding", function()
  local Schema = {
    val = {1, "int32"},
  }

  T.it("round-trips -1", function()
    local bytes, err = pb.encode(Schema, {val = -1})
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.val, -1)
  end)

  T.it("round-trips -2147483648", function()
    local bytes, err = pb.encode(Schema, {val = -2147483648})
    T.ok(bytes, err)
    local decoded = pb.decode(Schema, bytes)
    T.eq(decoded.val, -2147483648)
  end)
end)
