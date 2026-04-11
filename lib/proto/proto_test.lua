if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local P = require("lib.proto")

-- Helper: byte string from hex
local function from_hex(h)
	return (h:gsub("%s+", ""):gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end))
end

-- Helper: hex from byte string
local function to_hex(s)
	return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- ── Tier ──────────────────────────────────────────────────────────────────────

T.describe("lib.proto", function()

	T.it("M._tier is 'pure'", function()
		T.eq(P._tier, "pure")
	end)

	-- ── Schema construction ───────────────────────────────────────────────────

	T.it("M.message produces a schema with by_number index", function()
		local schema = P.message {
			{ 1, "name", P.STRING },
			{ 2, "age",  P.INT32  },
		}
		T.eq(schema.kind, "message")
		T.ok(schema.by_number[1])
		T.eq(schema.by_number[1].name, "name")
		T.ok(schema.by_number[2])
		T.eq(schema.by_number[2].name, "age")
	end)

	-- ── Empty message ──────────────────────────────────────────────────────────

	T.it("empty message encodes to empty string", function()
		local schema = P.message { { 1, "name", P.STRING } }
		local encoded, err = P.encode(schema, {})
		T.ok(not err, err)
		T.eq(encoded, "")
	end)

	T.it("empty message decodes to empty table", function()
		local schema = P.message { { 1, "name", P.STRING } }
		local decoded, err = P.decode(schema, "")
		T.ok(not err, err)
		T.eq(type(decoded), "table")
	end)

	-- ── Known wire vector: {name="Alice", age=30} ─────────────────────────────
	-- Field 1 string "Alice": tag=0x0a, len=5, "Alice"
	-- Field 2 int32 30:       tag=0x10, varint=0x1e

	T.it("encodes {name=Alice, age=30} to known bytes", function()
		local schema = P.message {
			{ 1, "name", P.STRING },
			{ 2, "age",  P.INT32  },
		}
		local encoded, err = P.encode(schema, { name = "Alice", age = 30 })
		T.ok(not err, err)
		T.eq(to_hex(encoded), "0a05416c696365101e")
	end)

	T.it("decodes known bytes to {name=Alice, age=30}", function()
		local schema = P.message {
			{ 1, "name", P.STRING },
			{ 2, "age",  P.INT32  },
		}
		local decoded, err = P.decode(schema, from_hex("0a05416c696365101e"))
		T.ok(not err, err)
		T.eq(decoded.name, "Alice")
		T.eq(decoded.age, 30)
	end)

	-- ── Round-trip: INT32 ─────────────────────────────────────────────────────

	T.it("INT32 round-trip positive", function()
		local schema = P.message { { 1, "v", P.INT32 } }
		local enc = P.encode(schema, { v = 12345 })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, 12345)
	end)

	T.it("INT32 round-trip negative", function()
		local schema = P.message { { 1, "v", P.INT32 } }
		local enc = P.encode(schema, { v = -1 })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, -1)
	end)

	T.it("INT32 round-trip zero", function()
		local schema = P.message { { 1, "v", P.INT32 } }
		local enc = P.encode(schema, { v = 0 })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, 0)
	end)

	-- ── Round-trip: UINT32 ────────────────────────────────────────────────────

	T.it("UINT32 round-trip", function()
		local schema = P.message { { 1, "v", P.UINT32 } }
		local enc = P.encode(schema, { v = 0xDEADBEEF % 0x100000000 })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, 0xDEADBEEF % 0x100000000)
	end)

	-- ── Round-trip: INT64 ─────────────────────────────────────────────────────

	T.it("INT64 round-trip large positive", function()
		local schema = P.message { { 1, "v", P.INT64 } }
		local enc = P.encode(schema, { v = 2^40 })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, 2^40)
	end)

	T.it("INT64 round-trip negative", function()
		local schema = P.message { { 1, "v", P.INT64 } }
		local enc = P.encode(schema, { v = -100 })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, -100)
	end)

	-- ── Round-trip: SINT32 / zigzag ───────────────────────────────────────────

	T.it("SINT32 zigzag: -1 encodes to varint 1", function()
		local schema = P.message { { 1, "v", P.SINT32 } }
		local enc = P.encode(schema, { v = -1 })
		-- tag 0x08 (field 1, wire 0), then varint 1 = 0x01
		T.eq(to_hex(enc), "0801")
	end)

	T.it("SINT32 zigzag: 1 encodes to varint 2", function()
		local schema = P.message { { 1, "v", P.SINT32 } }
		local enc = P.encode(schema, { v = 1 })
		T.eq(to_hex(enc), "0802")
	end)

	T.it("SINT32 zigzag: -2 encodes to varint 3", function()
		local schema = P.message { { 1, "v", P.SINT32 } }
		local enc = P.encode(schema, { v = -2 })
		T.eq(to_hex(enc), "0803")
	end)

	T.it("SINT32 round-trip large negative", function()
		local schema = P.message { { 1, "v", P.SINT32 } }
		local enc = P.encode(schema, { v = -1000000 })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, -1000000)
	end)

	T.it("SINT64 round-trip", function()
		local schema = P.message { { 1, "v", P.SINT64 } }
		local enc = P.encode(schema, { v = -9999999 })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, -9999999)
	end)

	-- ── Round-trip: BOOL ──────────────────────────────────────────────────────

	T.it("BOOL true encodes to varint 1", function()
		local schema = P.message { { 1, "v", P.BOOL } }
		local enc = P.encode(schema, { v = true })
		T.eq(to_hex(enc), "0801")
	end)

	T.it("BOOL false encodes to varint 0", function()
		local schema = P.message { { 1, "v", P.BOOL } }
		local enc = P.encode(schema, { v = false })
		T.eq(to_hex(enc), "0800")
	end)

	T.it("BOOL round-trip true", function()
		local schema = P.message { { 1, "v", P.BOOL } }
		local enc = P.encode(schema, { v = true })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, true)
	end)

	T.it("BOOL round-trip false", function()
		local schema = P.message { { 1, "v", P.BOOL } }
		local enc = P.encode(schema, { v = false })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, false)
	end)

	-- ── Round-trip: FLOAT / DOUBLE ────────────────────────────────────────────

	T.it("FLOAT round-trip", function()
		local schema = P.message { { 1, "v", P.FLOAT } }
		local enc = P.encode(schema, { v = 3.14 })
		local dec = P.decode(schema, enc)
		-- float has ~7 decimal digits precision
		T.ok(math.abs(dec.v - 3.14) < 0.001, "float round-trip")
	end)

	T.it("DOUBLE round-trip exact", function()
		local schema = P.message { { 1, "v", P.DOUBLE } }
		local enc = P.encode(schema, { v = 1.23456789012345 })
		local dec = P.decode(schema, enc)
		T.ok(math.abs(dec.v - 1.23456789012345) < 1e-14, "double round-trip")
	end)

	T.it("DOUBLE negative round-trip", function()
		local schema = P.message { { 1, "v", P.DOUBLE } }
		local enc = P.encode(schema, { v = -2.718281828 })
		local dec = P.decode(schema, enc)
		T.ok(math.abs(dec.v - (-2.718281828)) < 1e-9, "double neg round-trip")
	end)

	-- ── Round-trip: STRING ────────────────────────────────────────────────────

	T.it("STRING round-trip", function()
		local schema = P.message { { 1, "v", P.STRING } }
		local enc = P.encode(schema, { v = "hello, world" })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, "hello, world")
	end)

	T.it("STRING empty round-trip", function()
		local schema = P.message { { 1, "v", P.STRING } }
		local enc = P.encode(schema, { v = "" })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, "")
	end)

	T.it("BYTES round-trip", function()
		local schema = P.message { { 1, "v", P.BYTES } }
		local enc = P.encode(schema, { v = "\x00\x01\x02\xff" })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, "\x00\x01\x02\xff")
	end)

	-- ── Nested message ────────────────────────────────────────────────────────

	T.it("nested message round-trip", function()
		local addr_schema = P.message {
			{ 1, "street", P.STRING },
			{ 2, "city",   P.STRING },
		}
		local schema = P.message {
			{ 1, "name", P.STRING  },
			{ 4, "addr", addr_schema },
		}
		local msg = {
			name = "Bob",
			addr = { street = "123 Main St", city = "Springfield" },
		}
		local enc = P.encode(schema, msg)
		local dec = P.decode(schema, enc)
		T.eq(dec.name, "Bob")
		T.eq(dec.addr.street, "123 Main St")
		T.eq(dec.addr.city, "Springfield")
	end)

	T.it("nested message with empty inner", function()
		local inner = P.message { { 1, "x", P.INT32 } }
		local schema = P.message { { 1, "sub", inner } }
		local enc = P.encode(schema, { sub = {} })
		local dec = P.decode(schema, enc)
		T.eq(type(dec.sub), "table")
	end)

	-- ── Repeated fields ───────────────────────────────────────────────────────

	T.it("repeated INT32 packed round-trip", function()
		local schema = P.message { { 1, "scores", P.repeated(P.INT32) } }
		local enc = P.encode(schema, { scores = { 1, 2, 3, 100, -1 } })
		local dec = P.decode(schema, enc)
		T.eq(#dec.scores, 5)
		T.eq(dec.scores[1], 1)
		T.eq(dec.scores[3], 3)
		T.eq(dec.scores[5], -1)
	end)

	T.it("repeated DOUBLE packed round-trip", function()
		local schema = P.message { { 1, "vals", P.repeated(P.DOUBLE) } }
		local enc = P.encode(schema, { vals = { 1.1, 2.2, 3.3 } })
		local dec = P.decode(schema, enc)
		T.eq(#dec.vals, 3)
		T.ok(math.abs(dec.vals[1] - 1.1) < 1e-12)
		T.ok(math.abs(dec.vals[2] - 2.2) < 1e-12)
		T.ok(math.abs(dec.vals[3] - 3.3) < 1e-12)
	end)

	T.it("repeated STRING round-trip", function()
		local schema = P.message { { 1, "tags", P.repeated(P.STRING) } }
		local enc = P.encode(schema, { tags = { "foo", "bar", "baz" } })
		local dec = P.decode(schema, enc)
		T.eq(#dec.tags, 3)
		T.eq(dec.tags[1], "foo")
		T.eq(dec.tags[2], "bar")
		T.eq(dec.tags[3], "baz")
	end)

	T.it("repeated message round-trip", function()
		local point = P.message { { 1, "x", P.INT32 }, { 2, "y", P.INT32 } }
		local schema = P.message { { 1, "pts", P.repeated(point) } }
		local enc = P.encode(schema, { pts = { { x = 1, y = 2 }, { x = 3, y = 4 } } })
		local dec = P.decode(schema, enc)
		T.eq(#dec.pts, 2)
		T.eq(dec.pts[1].x, 1)
		T.eq(dec.pts[1].y, 2)
		T.eq(dec.pts[2].x, 3)
		T.eq(dec.pts[2].y, 4)
	end)

	T.it("empty repeated encodes nothing", function()
		local schema = P.message { { 1, "vals", P.repeated(P.INT32) } }
		local enc = P.encode(schema, { vals = {} })
		T.eq(enc, "")
	end)

	-- ── Unknown field skip ────────────────────────────────────────────────────

	T.it("unknown varint field is skipped on decode", function()
		-- Manually craft a message with field 99 (varint wire) then field 1 (string)
		-- Field 99, wire 0: tag = (99*8)+0 = 792 = varint [0x98, 0x06], value varint 42 = 0x2a
		-- Field 1, wire 2:  tag = 0x0a, len 3, "abc"
		local raw = from_hex("9806" .. "2a" .. "0a03616263")
		local schema = P.message { { 1, "name", P.STRING } }
		local dec, err = P.decode(schema, raw)
		T.ok(not err, err)
		T.eq(dec.name, "abc")
	end)

	T.it("unknown LEN field is skipped on decode", function()
		-- Field 50, wire 2: tag = (50*8)+2 = 402, varint [0x92, 0x03], length 4, "junk"
		-- Field 1, wire 0 (INT32): tag 0x08, value 77
		local raw = from_hex("9203" .. "04" .. "6a756e6b" .. "084d")
		local schema = P.message { { 1, "v", P.INT32 } }
		local dec, err = P.decode(schema, raw)
		T.ok(not err, err)
		T.eq(dec.v, 77)
	end)

	-- ── Large varint (multi-byte) ─────────────────────────────────────────────

	T.it("large UINT32 round-trip (>127)", function()
		local schema = P.message { { 1, "v", P.UINT32 } }
		local enc = P.encode(schema, { v = 300 })
		local dec = P.decode(schema, enc)
		T.eq(dec.v, 300)
	end)

	T.it("large UINT32 round-trip (>16383)", function()
		local schema = P.message { { 1, "v", P.UINT32 } }
		local enc = P.encode(schema, { v = 100000 } )
		local dec = P.decode(schema, enc)
		T.eq(dec.v, 100000)
	end)

	-- ── Full schema round-trip ────────────────────────────────────────────────

	T.it("full schema round-trip", function()
		local addr = P.message {
			{ 1, "street", P.STRING },
			{ 2, "city",   P.STRING },
		}
		local schema = P.message {
			{ 1, "name",   P.STRING           },
			{ 2, "age",    P.INT32            },
			{ 3, "scores", P.repeated(P.DOUBLE) },
			{ 4, "addr",   addr               },
			{ 5, "active", P.BOOL             },
		}
		local msg = {
			name   = "Alice",
			age    = 30,
			scores = { 9.5, 8.0, 7.25 },
			addr   = { street = "1 Infinite Loop", city = "Cupertino" },
			active = true,
		}
		local enc = P.encode(schema, msg)
		local dec = P.decode(schema, enc)
		T.eq(dec.name, "Alice")
		T.eq(dec.age, 30)
		T.eq(#dec.scores, 3)
		T.ok(math.abs(dec.scores[1] - 9.5) < 1e-12)
		T.eq(dec.addr.street, "1 Infinite Loop")
		T.eq(dec.addr.city, "Cupertino")
		T.eq(dec.active, true)
	end)

	-- ── aliases ───────────────────────────────────────────────────────────────

	T.it("encode alias msg_to_string works", function()
		local schema = P.message { { 1, "v", P.INT32 } }
		local enc1 = P.encode(schema, { v = 5 })
		local enc2 = P.msg_to_string(schema, { v = 5 })
		T.eq(enc1, enc2)
	end)

	T.it("decode alias string_to_msg works", function()
		local schema = P.message { { 1, "v", P.INT32 } }
		local enc = P.encode(schema, { v = 7 })
		local dec1 = P.decode(schema, enc)
		local dec2 = P.string_to_msg(schema, enc)
		T.eq(dec1.v, dec2.v)
	end)

	-- ── Error handling ────────────────────────────────────────────────────────

	T.it("encode non-message schema returns error", function()
		local _, err = P.encode(P.INT32, { v = 1 })
		T.ok(err and err:find("message"))
	end)

	T.it("decode non-message schema returns error", function()
		local _, err = P.decode(P.STRING, "")
		T.ok(err and err:find("message"))
	end)

end)
