if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local bson = require("lib.bson")

-- ── helpers ──────────────────────────────────────────────────────────────────

local function round_trip(value)
	local enc, err = bson.encode(value)
	if not enc then return nil, err end
	local dec, _, derr = bson.decode(enc)
	if not dec then return nil, derr end
	return dec
end

-- ── null ─────────────────────────────────────────────────────────────────────

T.describe("null", function()
	T.it("encodes/decodes null sentinel", function()
		local t = { x = bson.null }
		local enc = bson.encode(t)
		T.ok(type(enc) == "string", "encodes to string")
		T.ok(#enc > 4, "has content")
		local dec = round_trip(t)
		T.ok(dec ~= nil, "decoded ok")
		T.ok(dec.x ~= nil, "key present")
		T.ok(bson.is_datetime(dec.x) == false, "not datetime")
		T.ok(bson.is_binary(dec.x) == false, "not binary")
		-- null round-trips as bson.null sentinel
		T.ok(dec.x == bson.null, "null round-trips as bson.null")
	end)
end)

-- ── boolean ──────────────────────────────────────────────────────────────────

T.describe("boolean", function()
	T.it("encodes/decodes true", function()
		local dec = round_trip({ v = true })
		T.eq(dec.v, true)
	end)
	T.it("encodes/decodes false", function()
		local dec = round_trip({ v = false })
		T.eq(dec.v, false)
	end)
end)

-- ── numbers ───────────────────────────────────────────────────────────────────

T.describe("int32", function()
	T.it("encodes/decodes zero", function()
		local dec = round_trip({ n = 0 })
		T.eq(dec.n, 0)
	end)
	T.it("encodes/decodes positive int32", function()
		local dec = round_trip({ n = 12345 })
		T.eq(dec.n, 12345)
	end)
	T.it("encodes/decodes negative int32", function()
		local dec = round_trip({ n = -99 })
		T.eq(dec.n, -99)
	end)
	T.it("encodes/decodes max int32", function()
		local dec = round_trip({ n = 2147483647 })
		T.eq(dec.n, 2147483647)
	end)
	T.it("encodes/decodes min int32", function()
		local dec = round_trip({ n = -2147483648 })
		T.eq(dec.n, -2147483648)
	end)
end)

T.describe("int64", function()
	T.it("encodes/decodes large positive int64", function()
		local n = 2147483648  -- just above int32 max
		local dec = round_trip({ n = n })
		T.eq(dec.n, n)
	end)
	T.it("encodes/decodes negative int64", function()
		local n = -2147483649  -- just below int32 min
		local dec = round_trip({ n = n })
		T.eq(dec.n, n)
	end)
	T.it("encodes/decodes large magnitude", function()
		local n = 9007199254740992  -- 2^53, max safe integer
		local dec = round_trip({ n = n })
		T.eq(dec.n, n)
	end)
end)

T.describe("double", function()
	T.it("encodes/decodes 3.14", function()
		local dec = round_trip({ n = 3.14 })
		T.ok(math.abs(dec.n - 3.14) < 1e-10, "3.14 round-trips")
	end)
	T.it("encodes/decodes negative float", function()
		local dec = round_trip({ n = -2.718 })
		T.ok(math.abs(dec.n - (-2.718)) < 1e-10, "-2.718 round-trips")
	end)
	T.it("encodes/decodes positive infinity", function()
		local dec = round_trip({ n = math.huge })
		T.eq(dec.n, math.huge)
	end)
	T.it("encodes/decodes negative infinity", function()
		local dec = round_trip({ n = -math.huge })
		T.eq(dec.n, -math.huge)
	end)
	T.it("encodes/decodes NaN", function()
		local dec = round_trip({ n = 0/0 })
		T.ok(dec.n ~= dec.n, "NaN round-trips as NaN")
	end)
	T.it("encodes/decodes 0.0", function()
		local dec = round_trip({ n = 0.0 })
		T.eq(dec.n, 0.0)
	end)
end)

-- ── string ───────────────────────────────────────────────────────────────────

T.describe("string", function()
	T.it("encodes/decodes empty string", function()
		local dec = round_trip({ s = "" })
		T.eq(dec.s, "")
	end)
	T.it("encodes/decodes ascii string", function()
		local dec = round_trip({ s = "hello world" })
		T.eq(dec.s, "hello world")
	end)
	T.it("encodes/decodes unicode string", function()
		local dec = round_trip({ s = "こんにちは" })
		T.eq(dec.s, "こんにちは")
	end)
	T.it("encodes/decodes string with nulls/special chars", function()
		local dec = round_trip({ s = "foo\tbar\n" })
		T.eq(dec.s, "foo\tbar\n")
	end)
end)

-- ── nested document ───────────────────────────────────────────────────────────

T.describe("nested document", function()
	T.it("encodes/decodes nested table", function()
		local t = {
			name = "Alice",
			address = {
				street = "123 Main St",
				zip = 12345,
			},
		}
		local dec = round_trip(t)
		T.ok(dec ~= nil)
		T.eq(dec.name, "Alice")
		T.ok(type(dec.address) == "table", "nested table present")
		T.eq(dec.address.street, "123 Main St")
		T.eq(dec.address.zip, 12345)
	end)
	T.it("encodes/decodes deeply nested", function()
		local t = { a = { b = { c = { d = 42 } } } }
		local dec = round_trip(t)
		T.eq(dec.a.b.c.d, 42)
	end)
end)

-- ── array ─────────────────────────────────────────────────────────────────────

T.describe("array", function()
	T.it("encodes/decodes simple array", function()
		local t = { items = { 1, 2, 3, 4, 5 } }
		local dec = round_trip(t)
		T.ok(type(dec.items) == "table")
		T.eq(dec.items[1], 1)
		T.eq(dec.items[2], 2)
		T.eq(dec.items[5], 5)
	end)
	T.it("encodes/decodes array of strings", function()
		local t = { tags = { "lua", "bson", "mongodb" } }
		local dec = round_trip(t)
		T.eq(dec.tags[1], "lua")
		T.eq(dec.tags[2], "bson")
		T.eq(dec.tags[3], "mongodb")
	end)
	T.it("encodes/decodes mixed array", function()
		local t = { vals = { 1, "two", true, bson.null } }
		local dec = round_trip(t)
		T.eq(dec.vals[1], 1)
		T.eq(dec.vals[2], "two")
		T.eq(dec.vals[3], true)
		T.ok(dec.vals[4] == bson.null)
	end)
	T.it("top-level array encodes/decodes", function()
		local t = { 10, 20, 30 }
		local enc, err = bson.encode(t)
		T.ok(enc ~= nil, "encoded: " .. tostring(err))
		local dec = round_trip(t)
		T.eq(dec[1], 10)
		T.eq(dec[2], 20)
		T.eq(dec[3], 30)
	end)
end)

-- ── binary ───────────────────────────────────────────────────────────────────

T.describe("binary", function()
	T.it("encodes/decodes binary data (subtype 0)", function()
		local data = "\x00\x01\x02\x03\xff\xfe"
		local t = { blob = bson.binary(data, 0) }
		local enc = bson.encode(t)
		T.ok(enc ~= nil)
		local dec = round_trip(t)
		T.ok(bson.is_binary(dec.blob), "decoded as binary")
		T.eq(dec.blob.data, data)
		T.eq(dec.blob.subtype, 0)
	end)
	T.it("preserves subtype", function()
		local t = { blob = bson.binary("abc", 4) }
		local dec = round_trip(t)
		T.ok(bson.is_binary(dec.blob))
		T.eq(dec.blob.subtype, 4)
		T.eq(dec.blob.data, "abc")
	end)
	T.it("handles empty binary", function()
		local t = { blob = bson.binary("", 0) }
		local dec = round_trip(t)
		T.ok(bson.is_binary(dec.blob))
		T.eq(dec.blob.data, "")
	end)
end)

-- ── datetime ─────────────────────────────────────────────────────────────────

T.describe("datetime", function()
	T.it("encodes/decodes epoch 0", function()
		local t = { ts = bson.datetime(0) }
		local dec = round_trip(t)
		T.ok(bson.is_datetime(dec.ts), "decoded as datetime")
		T.eq(dec.ts.ms, 0)
	end)
	T.it("encodes/decodes positive timestamp", function()
		local ms = 1713000000000  -- approx 2024
		local t = { ts = bson.datetime(ms) }
		local dec = round_trip(t)
		T.ok(bson.is_datetime(dec.ts))
		T.eq(dec.ts.ms, ms)
	end)
	T.it("encodes/decodes negative timestamp (pre-epoch)", function()
		local ms = -86400000  -- one day before epoch
		local t = { ts = bson.datetime(ms) }
		local dec = round_trip(t)
		T.ok(bson.is_datetime(dec.ts))
		T.eq(dec.ts.ms, ms)
	end)
end)

-- ── decode_all ────────────────────────────────────────────────────────────────

T.describe("decode_all", function()
	T.it("decodes two concatenated BSON docs", function()
		local enc1 = bson.encode({ name = "Alice", age = 30 })
		local enc2 = bson.encode({ name = "Bob",   age = 25 })
		T.ok(enc1 ~= nil and enc2 ~= nil)
		local both = enc1 .. enc2
		local results, err = bson.decode_all(both)
		T.ok(results ~= nil, tostring(err))
		T.eq(#results, 2)
		T.eq(results[1].name, "Alice")
		T.eq(results[1].age, 30)
		T.eq(results[2].name, "Bob")
		T.eq(results[2].age, 25)
	end)
	T.it("decodes single document via decode_all", function()
		local enc = bson.encode({ x = 99 })
		local results = bson.decode_all(enc)
		T.eq(#results, 1)
		T.eq(results[1].x, 99)
	end)
	T.it("decodes three concatenated documents", function()
		local enc = bson.encode({ i = 1 }) .. bson.encode({ i = 2 }) .. bson.encode({ i = 3 })
		local results = bson.decode_all(enc)
		T.eq(#results, 3)
		T.eq(results[1].i, 1)
		T.eq(results[2].i, 2)
		T.eq(results[3].i, 3)
	end)
end)

-- ── error handling ───────────────────────────────────────────────────────────

T.describe("error handling", function()
	T.it("returns error on non-table top-level encode", function()
		local enc, err = bson.encode("not a table")
		T.ok(enc == nil, "should fail")
		T.ok(type(err) == "string", "error message present")
	end)
	T.it("returns error on truncated input (too short)", function()
		local val, _, err = bson.decode("\x05\x00\x00\x00")  -- size=5 but only 4 bytes
		T.ok(val == nil, "should fail on truncated")
		T.ok(type(err) == "string", "error message present")
	end)
	T.it("returns error on empty string", function()
		local val, _, err = bson.decode("")
		T.ok(val == nil, "empty input fails")
		T.ok(type(err) == "string")
	end)
	T.it("returns error on non-string input to decode", function()
		local val, _, err = bson.decode(42)
		T.ok(val == nil)
		T.ok(type(err) == "string")
	end)
	T.it("returns error on non-string input to decode_all", function()
		local val, err = bson.decode_all(42)
		T.ok(val == nil)
		T.ok(type(err) == "string")
	end)
	T.it("returns error on garbage bytes", function()
		local val, _, err = bson.decode("\xff\xff\xff\xff\x00")
		T.ok(val == nil, "garbage fails")
		T.ok(type(err) == "string")
	end)
end)

-- ── wire format spot-checks ───────────────────────────────────────────────────

T.describe("wire format", function()
	T.it("empty document is 5 bytes", function()
		-- { } encodes as 5 bytes: \x05\x00\x00\x00\x00
		-- But our is_array({}) returns false, so {} encodes as empty doc
		-- Actually empty table: no keys, not an array — encode as doc
		local enc = bson.encode({})
		T.eq(#enc, 5)
		T.eq(enc, "\x05\x00\x00\x00\x00")
	end)
	T.it("int32 type byte is 0x10", function()
		local enc = bson.encode({ n = 1 })
		-- structure: size(4) + type(1) + key("n\0"=2) + value(4) + term(1) = 12
		T.eq(#enc, 12)
		-- byte 5 is the type byte (1-indexed)
		T.eq(string.byte(enc, 5), 0x10)
	end)
	T.it("string type byte is 0x02", function()
		local enc = bson.encode({ s = "hi" })
		-- size(4) + type(1) + key("s\0"=2) + strsize(4) + "hi\0"(3) + term(1) = 15
		T.eq(#enc, 15)
		T.eq(string.byte(enc, 5), 0x02)
	end)
	T.it("boolean type byte is 0x08", function()
		local enc = bson.encode({ b = true })
		T.eq(string.byte(enc, 5), 0x08)
	end)
	T.it("double type byte is 0x01", function()
		local enc = bson.encode({ d = 1.5 })
		T.eq(string.byte(enc, 5), 0x01)
	end)
	T.it("null type byte is 0x0a", function()
		local enc = bson.encode({ n = bson.null })
		T.eq(string.byte(enc, 5), 0x0a)
	end)
	T.it("datetime type byte is 0x09", function()
		local enc = bson.encode({ t = bson.datetime(0) })
		T.eq(string.byte(enc, 5), 0x09)
	end)
	T.it("binary type byte is 0x05", function()
		local enc = bson.encode({ b = bson.binary("x", 0) })
		T.eq(string.byte(enc, 5), 0x05)
	end)
end)

-- ── round-trip comprehensive ─────────────────────────────────────────────────

T.describe("comprehensive round-trip", function()
	T.it("all types in one document", function()
		local t = {
			null_val  = bson.null,
			bool_true  = true,
			bool_false = false,
			int_small  = 42,
			int_neg    = -7,
			int_big    = 2147483648,
			float_val  = 1.23456789,
			str_val    = "hello",
			bin_val    = bson.binary("\x01\x02\x03", 0),
			dt_val     = bson.datetime(1000000),
			arr_val    = { 1, 2, 3 },
			doc_val    = { x = 1, y = 2 },
		}
		local enc, err = bson.encode(t)
		T.ok(enc ~= nil, tostring(err))
		local dec, _, derr = bson.decode(enc)
		T.ok(dec ~= nil, tostring(derr))

		T.ok(dec.null_val == bson.null)
		T.eq(dec.bool_true, true)
		T.eq(dec.bool_false, false)
		T.eq(dec.int_small, 42)
		T.eq(dec.int_neg, -7)
		T.eq(dec.int_big, 2147483648)
		T.ok(math.abs(dec.float_val - 1.23456789) < 1e-10)
		T.eq(dec.str_val, "hello")
		T.ok(bson.is_binary(dec.bin_val))
		T.eq(dec.bin_val.data, "\x01\x02\x03")
		T.ok(bson.is_datetime(dec.dt_val))
		T.eq(dec.dt_val.ms, 1000000)
		T.eq(dec.arr_val[1], 1)
		T.eq(dec.arr_val[3], 3)
		T.eq(dec.doc_val.x, 1)
		T.eq(dec.doc_val.y, 2)
	end)
end)
