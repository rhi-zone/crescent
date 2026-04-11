if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local mp = require("lib.msgpack")
local T = require("lib.test.assert")

local byte = string.byte

local function roundtrip(v)
	local enc = mp.encode(v)
	T.ok(enc, "encode should succeed")
	local dec = mp.decode(enc)
	return dec
end

-- ── nil ─────────────────────────────────────────────────────────────────────

T.describe("msgpack nil", function()
	T.it("encodes nil as 0xc0", function()
		local s = mp.encode(nil)
		T.eq(s, "\192")
	end)

	T.it("decodes 0xc0 as nil", function()
		local val, pos = mp.decode("\192")
		T.eq(val, nil)
		T.eq(pos, 2)
	end)
end)

-- ── booleans ────────────────────────────────────────────────────────────────

T.describe("msgpack booleans", function()
	T.it("encodes false as 0xc2", function()
		local s = mp.encode(false)
		T.eq(s, "\194")
	end)

	T.it("encodes true as 0xc3", function()
		local s = mp.encode(true)
		T.eq(s, "\195")
	end)

	T.it("decodes false", function()
		local val, pos = mp.decode("\194")
		T.eq(val, false)
		T.eq(pos, 2)
	end)

	T.it("decodes true", function()
		local val, pos = mp.decode("\195")
		T.eq(val, true)
		T.eq(pos, 2)
	end)

	T.it("roundtrips false", function()
		T.eq(roundtrip(false), false)
	end)

	T.it("roundtrips true", function()
		T.eq(roundtrip(true), true)
	end)
end)

-- ── positive fixint ─────────────────────────────────────────────────────────

T.describe("msgpack positive fixint", function()
	T.it("encodes 0", function()
		T.eq(mp.encode(0), "\0")
	end)

	T.it("encodes 1", function()
		T.eq(mp.encode(1), "\1")
	end)

	T.it("encodes 127", function()
		T.eq(mp.encode(127), "\127")
	end)

	T.it("roundtrips 0", function()
		T.eq(roundtrip(0), 0)
	end)

	T.it("roundtrips 42", function()
		T.eq(roundtrip(42), 42)
	end)

	T.it("roundtrips 127", function()
		T.eq(roundtrip(127), 127)
	end)
end)

-- ── negative fixint ─────────────────────────────────────────────────────────

T.describe("msgpack negative fixint", function()
	T.it("encodes -1", function()
		T.eq(byte(mp.encode(-1), 1), 0xff)
	end)

	T.it("encodes -32", function()
		T.eq(byte(mp.encode(-32), 1), 0xe0)
	end)

	T.it("roundtrips -1", function()
		T.eq(roundtrip(-1), -1)
	end)

	T.it("roundtrips -32", function()
		T.eq(roundtrip(-32), -32)
	end)

	T.it("roundtrips -17", function()
		T.eq(roundtrip(-17), -17)
	end)
end)

-- ── uint8 ───────────────────────────────────────────────────────────────────

T.describe("msgpack uint8", function()
	T.it("encodes 128 as uint8", function()
		local s = mp.encode(128)
		T.eq(byte(s, 1), 0xcc)
		T.eq(byte(s, 2), 128)
	end)

	T.it("encodes 255 as uint8", function()
		local s = mp.encode(255)
		T.eq(byte(s, 1), 0xcc)
		T.eq(byte(s, 2), 255)
	end)

	T.it("roundtrips 128", function()
		T.eq(roundtrip(128), 128)
	end)

	T.it("roundtrips 200", function()
		T.eq(roundtrip(200), 200)
	end)

	T.it("roundtrips 255", function()
		T.eq(roundtrip(255), 255)
	end)
end)

-- ── uint16 ──────────────────────────────────────────────────────────────────

T.describe("msgpack uint16", function()
	T.it("encodes 256 as uint16", function()
		local s = mp.encode(256)
		T.eq(byte(s, 1), 0xcd)
		T.eq(byte(s, 2), 1)
		T.eq(byte(s, 3), 0)
	end)

	T.it("encodes 65535 as uint16", function()
		local s = mp.encode(65535)
		T.eq(byte(s, 1), 0xcd)
	end)

	T.it("roundtrips 256", function()
		T.eq(roundtrip(256), 256)
	end)

	T.it("roundtrips 1000", function()
		T.eq(roundtrip(1000), 1000)
	end)

	T.it("roundtrips 65535", function()
		T.eq(roundtrip(65535), 65535)
	end)
end)

-- ── uint32 ──────────────────────────────────────────────────────────────────

T.describe("msgpack uint32", function()
	T.it("encodes 65536 as uint32", function()
		local s = mp.encode(65536)
		T.eq(byte(s, 1), 0xce)
	end)

	T.it("roundtrips 65536", function()
		T.eq(roundtrip(65536), 65536)
	end)

	T.it("roundtrips 100000", function()
		T.eq(roundtrip(100000), 100000)
	end)

	T.it("roundtrips 4294967295", function()
		T.eq(roundtrip(4294967295), 4294967295)
	end)
end)

-- ── int8 ────────────────────────────────────────────────────────────────────

T.describe("msgpack int8", function()
	T.it("encodes -33 as int8", function()
		local s = mp.encode(-33)
		T.eq(byte(s, 1), 0xd0)
	end)

	T.it("roundtrips -33", function()
		T.eq(roundtrip(-33), -33)
	end)

	T.it("roundtrips -128", function()
		T.eq(roundtrip(-128), -128)
	end)

	T.it("roundtrips -100", function()
		T.eq(roundtrip(-100), -100)
	end)
end)

-- ── int16 ───────────────────────────────────────────────────────────────────

T.describe("msgpack int16", function()
	T.it("encodes -129 as int16", function()
		local s = mp.encode(-129)
		T.eq(byte(s, 1), 0xd1)
	end)

	T.it("roundtrips -129", function()
		T.eq(roundtrip(-129), -129)
	end)

	T.it("roundtrips -32768", function()
		T.eq(roundtrip(-32768), -32768)
	end)

	T.it("roundtrips -1000", function()
		T.eq(roundtrip(-1000), -1000)
	end)
end)

-- ── int32 ───────────────────────────────────────────────────────────────────

T.describe("msgpack int32", function()
	T.it("encodes -32769 as int32", function()
		local s = mp.encode(-32769)
		T.eq(byte(s, 1), 0xd2)
	end)

	T.it("roundtrips -32769", function()
		T.eq(roundtrip(-32769), -32769)
	end)

	T.it("roundtrips -2147483648", function()
		T.eq(roundtrip(-2147483648), -2147483648)
	end)

	T.it("roundtrips -100000", function()
		T.eq(roundtrip(-100000), -100000)
	end)
end)

-- ── float64 ─────────────────────────────────────────────────────────────────

T.describe("msgpack float64", function()
	T.it("encodes 1.5 as float64", function()
		local s = mp.encode(1.5)
		T.eq(byte(s, 1), 0xcb)
		T.eq(#s, 9)
	end)

	T.it("roundtrips 1.5", function()
		T.eq(roundtrip(1.5), 1.5)
	end)

	T.it("roundtrips -1.5", function()
		T.eq(roundtrip(-1.5), -1.5)
	end)

	T.it("roundtrips 3.14159", function()
		T.eq(roundtrip(3.14159), 3.14159)
	end)

	T.it("roundtrips very small float", function()
		T.eq(roundtrip(1e-10), 1e-10)
	end)

	T.it("roundtrips very large float", function()
		T.eq(roundtrip(1e100), 1e100)
	end)

	T.it("roundtrips negative zero", function()
		local val = roundtrip(-0.0)
		T.eq(val, 0)
		T.eq(1 / val, -math.huge) -- negative zero
	end)

	T.it("roundtrips infinity", function()
		T.eq(roundtrip(math.huge), math.huge)
	end)

	T.it("roundtrips negative infinity", function()
		T.eq(roundtrip(-math.huge), -math.huge)
	end)

	T.it("roundtrips NaN", function()
		local val = roundtrip(0/0)
		T.ok(val ~= val, "NaN ~= NaN")
	end)
end)

-- ── fixstr ──────────────────────────────────────────────────────────────────

T.describe("msgpack fixstr", function()
	T.it("encodes empty string", function()
		local s = mp.encode("")
		T.eq(byte(s, 1), 0xa0)
		T.eq(#s, 1)
	end)

	T.it("encodes short string", function()
		local s = mp.encode("hello")
		T.eq(byte(s, 1), 0xa0 + 5)
		T.eq(#s, 6)
	end)

	T.it("roundtrips empty string", function()
		T.eq(roundtrip(""), "")
	end)

	T.it("roundtrips hello", function()
		T.eq(roundtrip("hello"), "hello")
	end)

	T.it("roundtrips 31 byte string", function()
		local s = string.rep("x", 31)
		T.eq(roundtrip(s), s)
	end)
end)

-- ── str8 ────────────────────────────────────────────────────────────────────

T.describe("msgpack str8", function()
	T.it("encodes 32 byte string as str8", function()
		local s = string.rep("a", 32)
		local enc = mp.encode(s)
		T.eq(byte(enc, 1), 0xd9)
		T.eq(byte(enc, 2), 32)
	end)

	T.it("roundtrips 32 byte string", function()
		local s = string.rep("a", 32)
		T.eq(roundtrip(s), s)
	end)

	T.it("roundtrips 200 byte string", function()
		local s = string.rep("b", 200)
		T.eq(roundtrip(s), s)
	end)

	T.it("roundtrips 255 byte string", function()
		local s = string.rep("c", 255)
		T.eq(roundtrip(s), s)
	end)
end)

-- ── str16 ───────────────────────────────────────────────────────────────────

T.describe("msgpack str16", function()
	T.it("encodes 256 byte string as str16", function()
		local s = string.rep("d", 256)
		local enc = mp.encode(s)
		T.eq(byte(enc, 1), 0xda)
	end)

	T.it("roundtrips 256 byte string", function()
		local s = string.rep("d", 256)
		T.eq(roundtrip(s), s)
	end)

	T.it("roundtrips 1000 byte string", function()
		local s = string.rep("e", 1000)
		T.eq(roundtrip(s), s)
	end)
end)

-- ── fixarray ────────────────────────────────────────────────────────────────

T.describe("msgpack fixarray", function()
	T.it("encodes empty array", function()
		local s = mp.encode({})
		T.eq(byte(s, 1), 0x90)
	end)

	T.it("roundtrips empty array", function()
		local dec = roundtrip({})
		T.eq(type(dec), "table")
		T.eq(#dec, 0)
	end)

	T.it("roundtrips single element array", function()
		local dec = roundtrip({42})
		T.eq(dec[1], 42)
		T.eq(#dec, 1)
	end)

	T.it("roundtrips multi element array", function()
		local dec = roundtrip({1, 2, 3})
		T.eq(dec[1], 1)
		T.eq(dec[2], 2)
		T.eq(dec[3], 3)
	end)

	T.it("roundtrips 15 element array", function()
		local t = {}
		for i = 1, 15 do t[i] = i end
		local dec = roundtrip(t)
		T.eq(#dec, 15)
		T.eq(dec[15], 15)
	end)

	T.it("roundtrips mixed type array", function()
		local dec = roundtrip({1, "two", true, false})
		T.eq(dec[1], 1)
		T.eq(dec[2], "two")
		T.eq(dec[3], true)
		T.eq(dec[4], false)
	end)
end)

-- ── array16 ─────────────────────────────────────────────────────────────────

T.describe("msgpack array16", function()
	T.it("encodes 16-element array as array16", function()
		local t = {}
		for i = 1, 16 do t[i] = i end
		local enc = mp.encode(t)
		T.eq(byte(enc, 1), 0xdc)
	end)

	T.it("roundtrips 16-element array", function()
		local t = {}
		for i = 1, 16 do t[i] = i end
		local dec = roundtrip(t)
		T.eq(#dec, 16)
		T.eq(dec[1], 1)
		T.eq(dec[16], 16)
	end)

	T.it("roundtrips 100-element array", function()
		local t = {}
		for i = 1, 100 do t[i] = i * 2 end
		local dec = roundtrip(t)
		T.eq(#dec, 100)
		T.eq(dec[50], 100)
	end)
end)

-- ── fixmap ──────────────────────────────────────────────────────────────────

T.describe("msgpack fixmap", function()
	T.it("roundtrips single key map", function()
		local dec = roundtrip({a = 1})
		T.eq(dec.a, 1)
	end)

	T.it("roundtrips multi key map", function()
		local dec = roundtrip({a = 1, b = "hello", c = true})
		T.eq(dec.a, 1)
		T.eq(dec.b, "hello")
		T.eq(dec.c, true)
	end)

	T.it("roundtrips integer keyed non-array map", function()
		-- sparse table: not an array
		local dec = roundtrip({[1] = "a", [3] = "c"})
		T.eq(dec[1], "a")
		T.eq(dec[3], "c")
	end)
end)

-- ── nested structures ───────────────────────────────────────────────────────

T.describe("msgpack nested structures", function()
	T.it("roundtrips nested array", function()
		local dec = roundtrip({{1, 2}, {3, 4}})
		T.eq(dec[1][1], 1)
		T.eq(dec[1][2], 2)
		T.eq(dec[2][1], 3)
		T.eq(dec[2][2], 4)
	end)

	T.it("roundtrips nested map", function()
		local dec = roundtrip({a = {b = {c = 42}}})
		T.eq(dec.a.b.c, 42)
	end)

	T.it("roundtrips array of maps", function()
		local dec = roundtrip({{name = "alice"}, {name = "bob"}})
		T.eq(dec[1].name, "alice")
		T.eq(dec[2].name, "bob")
	end)

	T.it("roundtrips map of arrays", function()
		local dec = roundtrip({x = {1, 2, 3}, y = {4, 5, 6}})
		T.eq(dec.x[1], 1)
		T.eq(dec.y[3], 6)
	end)

	T.it("roundtrips deeply nested", function()
		local dec = roundtrip({{{{{42}}}}})
		T.eq(dec[1][1][1][1][1], 42)
	end)
end)

-- ── complex roundtrip ───────────────────────────────────────────────────────

T.describe("msgpack complex roundtrip", function()
	T.it("roundtrips complex structure", function()
		local data = {
			name = "test",
			version = 1,
			active = true,
			tags = {"lua", "msgpack", "pure"},
			config = {
				timeout = 30,
				retries = 3,
				verbose = false,
			},
		}
		local dec = roundtrip(data)
		T.eq(dec.name, "test")
		T.eq(dec.version, 1)
		T.eq(dec.active, true)
		T.eq(dec.tags[1], "lua")
		T.eq(dec.tags[2], "msgpack")
		T.eq(dec.tags[3], "pure")
		T.eq(dec.config.timeout, 30)
		T.eq(dec.config.retries, 3)
		T.eq(dec.config.verbose, false)
	end)
end)

-- ── binary ──────────────────────────────────────────────────────────────────

T.describe("msgpack binary", function()
	T.it("encodes binary with bin8", function()
		local b = mp.bin("\0\1\2\3")
		local enc = mp.encode(b)
		T.eq(byte(enc, 1), 0xc4)
		T.eq(byte(enc, 2), 4)
	end)

	T.it("roundtrips binary data", function()
		local data = "\0\1\2\3\xff\xfe"
		local b = mp.bin(data)
		local enc = mp.encode(b)
		local dec = mp.decode(enc)
		T.eq(dec, data)
	end)

	T.it("roundtrips empty binary", function()
		local b = mp.bin("")
		local enc = mp.encode(b)
		local dec = mp.decode(enc)
		T.eq(dec, "")
	end)
end)

-- ── empty containers ────────────────────────────────────────────────────────

T.describe("msgpack empty containers", function()
	T.it("empty array roundtrips", function()
		local dec = roundtrip({})
		T.eq(type(dec), "table")
		T.eq(next(dec), nil)
	end)
end)

-- ── edge cases ──────────────────────────────────────────────────────────────

T.describe("msgpack edge cases", function()
	T.it("returns error on empty input", function()
		local val, err = mp.decode("")
		T.eq(val, nil)
		T.ok(err, "should return error message")
	end)

	T.it("returns error on non-string input", function()
		local val, err = mp.decode(123)
		T.eq(val, nil)
		T.ok(err, "should return error message")
	end)

	T.it("integer boundary: 127 is fixint", function()
		local s = mp.encode(127)
		T.eq(#s, 1)
	end)

	T.it("integer boundary: 128 is uint8", function()
		local s = mp.encode(128)
		T.eq(#s, 2)
		T.eq(byte(s, 1), 0xcc)
	end)

	T.it("integer boundary: 255 to 256", function()
		T.eq(#mp.encode(255), 2)  -- uint8
		T.eq(byte(mp.encode(256), 1), 0xcd) -- uint16
	end)

	T.it("integer boundary: -32 is fixint", function()
		T.eq(#mp.encode(-32), 1)
	end)

	T.it("integer boundary: -33 is int8", function()
		T.eq(byte(mp.encode(-33), 1), 0xd0)
	end)

	T.it("roundtrips all fixint values", function()
		for i = 0, 127 do
			T.eq(roundtrip(i), i)
		end
	end)

	T.it("roundtrips all negative fixint values", function()
		for i = -32, -1 do
			T.eq(roundtrip(i), i)
		end
	end)
end)

-- ── aliases ─────────────────────────────────────────────────────────────────

T.describe("msgpack aliases", function()
	T.it("encode is value_to_string", function()
		T.eq(mp.encode, mp.value_to_string)
	end)

	T.it("decode is string_to_value", function()
		T.eq(mp.decode, mp.string_to_value)
	end)
end)

-- ── tier ────────────────────────────────────────────────────────────────────

T.describe("msgpack tier", function()
	T.it("reports pure tier", function()
		T.eq(mp._tier, "pure")
	end)
end)
