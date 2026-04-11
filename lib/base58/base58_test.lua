if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local base58 = require("lib.base58")

T.describe("lib.base58", function()

	T.describe("tier", function()
		T.it("_tier is 'pure'", function()
			T.eq(base58._tier, "pure")
		end)
	end)

	T.describe("encode", function()
		T.it("empty string → empty string", function()
			T.eq(base58.encode(""), "")
		end)

		T.it("single zero byte → '1'", function()
			T.eq(base58.encode("\x00"), "1")
		end)

		T.it("two zero bytes → '11'", function()
			T.eq(base58.encode("\x00\x00"), "11")
		end)

		T.it("0x61 → '2g'", function()
			T.eq(base58.encode("\x61"), "2g")
		end)

		T.it("0x01 → '2'", function()
			-- 1 in base-58: ALPHABET[1]='1'(0), ALPHABET[2]='2'(1). So 1→index 1→'2'.
			T.eq(base58.encode("\x01"), "2")
		end)

		T.it("0x39 (57) → 'z'", function()
			-- Last character of alphabet, index 57.
			T.eq(base58.encode("\x39"), "z")
		end)

		T.it("0x3a (58) → '21'", function()
			-- 58 = 1*58 + 0: digits [0,1] reversed → ALPHABET[1],ALPHABET[2] = '1','2' → "21"
			T.eq(base58.encode("\x3a"), "21")
		end)

		T.it("0xff → '5Q'", function()
			T.eq(base58.encode("\xff"), "5Q")
		end)

		T.it("leading zero preserved: 0x00 0x61 → '12g'", function()
			T.eq(base58.encode("\x00\x61"), "12g")
		end)

		T.it("'hello' → 'Cn8eVZg'", function()
			T.eq(base58.encode("hello"), "Cn8eVZg")
		end)

		T.it("'Hello World!' → '2NEpo7TZRRrLZSi2U'", function()
			T.eq(base58.encode("Hello World!"), "2NEpo7TZRRrLZSi2U")
		end)
	end)

	T.describe("decode", function()
		T.it("empty string → empty string", function()
			T.eq(base58.decode(""), "")
		end)

		T.it("'1' → zero byte", function()
			T.eq(base58.decode("1"), "\x00")
		end)

		T.it("'11' → two zero bytes", function()
			T.eq(base58.decode("11"), "\x00\x00")
		end)

		T.it("'2g' → 0x61", function()
			T.eq(base58.decode("2g"), "\x61")
		end)

		T.it("'2' → 0x01", function()
			T.eq(base58.decode("2"), "\x01")
		end)

		T.it("'z' → 0x39", function()
			T.eq(base58.decode("z"), "\x39")
		end)

		T.it("'21' → 0x3a", function()
			T.eq(base58.decode("21"), "\x3a")
		end)

		T.it("'5Q' → 0xff", function()
			T.eq(base58.decode("5Q"), "\xff")
		end)

		T.it("'12g' → 0x00 0x61", function()
			T.eq(base58.decode("12g"), "\x00\x61")
		end)

		T.it("'Cn8eVZg' → 'hello'", function()
			T.eq(base58.decode("Cn8eVZg"), "hello")
		end)

		T.it("'2NEpo7TZRRrLZSi2U' → 'Hello World!'", function()
			T.eq(base58.decode("2NEpo7TZRRrLZSi2U"), "Hello World!")
		end)

		T.it("invalid character '0' returns nil + errmsg", function()
			local result, err = base58.decode("10")
			T.eq(result, nil)
			T.ok(type(err) == "string")
		end)

		T.it("invalid character 'O' returns nil + errmsg", function()
			local result, err = base58.decode("O1")
			T.eq(result, nil)
			T.ok(type(err) == "string")
		end)

		T.it("invalid character 'I' returns nil + errmsg", function()
			local result, err = base58.decode("I")
			T.eq(result, nil)
			T.ok(type(err) == "string")
		end)

		T.it("invalid character 'l' returns nil + errmsg", function()
			local result, err = base58.decode("l")
			T.eq(result, nil)
			T.ok(type(err) == "string")
		end)
	end)

	T.describe("round-trips", function()
		local cases = {
			"",
			"\x00",
			"\x00\x00\x00",
			"\xff",
			"\x00\xff",
			"\xff\x00",
			"hello",
			"Hello World!",
			"The quick brown fox jumps over the lazy dog",
			"\x00\x01\x02\x03\x04\x05\x06\x07",
			string.rep("\x00", 10) .. "abc",
		}
		for _, input in ipairs(cases) do
			local label = input == "" and "(empty)" or (#input <= 20 and ("%q"):format(input) or ("(%d bytes)"):format(#input))
			T.it("round-trip: " .. label, function()
				local encoded = base58.encode(input)
				local decoded, err = base58.decode(encoded)
				T.eq(err, nil)
				T.eq(decoded, input)
			end)
		end
	end)

	T.describe("encode_check / decode_check", function()
		T.it("encode_check + decode_check round-trip on empty string", function()
			local enc = base58.encode_check("")
			local dec, err = base58.decode_check(enc)
			T.eq(err, nil)
			T.eq(dec, "")
		end)

		T.it("encode_check + decode_check round-trip on 'hello'", function()
			local enc = base58.encode_check("hello")
			local dec, err = base58.decode_check(enc)
			T.eq(err, nil)
			T.eq(dec, "hello")
		end)

		T.it("encode_check + decode_check round-trip on binary data", function()
			local data = "\x00\x01\x02\x03\xfe\xff"
			local enc = base58.encode_check(data)
			local dec, err = base58.decode_check(enc)
			T.eq(err, nil)
			T.eq(dec, data)
		end)

		T.it("corrupted checksum returns nil + errmsg", function()
			local enc = base58.encode_check("hello")
			-- Flip the last character to corrupt the checksum.
			-- Find a valid alphabet character that differs from last char.
			local last = enc:sub(-1)
			local replacement = last == "z" and "a" or "z"
			local corrupted = enc:sub(1, -2) .. replacement
			local result, err = base58.decode_check(corrupted)
			T.eq(result, nil)
			T.ok(type(err) == "string")
		end)

		T.it("known Bitcoin address vector", function()
			-- Input: version byte (0x00) + 20-byte hash160 from bitcoin wiki example.
			-- Payload (hex): 00010966776006953d5567439e5e39f86a0d273beed61967f6
			-- That 25-byte string already includes checksum; the 21-byte payload is the first 21 bytes.
			-- Verified: encode_check of 21-byte payload → "16UwLL9Risc3QfPqBUvKofHmBQ7wMtjvM"
			local hex = "00010966776006953d5567439e5e39f86a0d273beed61967f6"
			local full = hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end)
			-- The 21-byte versioned payload (version + hash160)
			local payload = full:sub(1, 21)
			local enc = base58.encode_check(payload)
			T.eq(enc, "16UwLL9Risc3QfPqBUvKofHmBQ7wMtjvM")
			-- Also verify decode_check round-trips back to the payload
			local dec, err = base58.decode_check(enc)
			T.eq(err, nil)
			T.eq(dec, payload)
		end)

		T.it("too-short decoded data returns nil + errmsg", function()
			-- Encode 3 bytes (less than checksum size) without going through encode_check,
			-- then try to decode_check it — should fail on 'too short'.
			local raw = base58.encode("\x01\x02\x03")
			local result, err = base58.decode_check(raw)
			T.eq(result, nil)
			T.ok(type(err) == "string")
		end)
	end)

	T.describe("codec aliases", function()
		T.it("encode_to_string == encode", function()
			T.eq(base58.encode_to_string("hello"), base58.encode("hello"))
		end)

		T.it("decode_from_string == decode", function()
			T.eq(base58.decode_from_string("Cn8eVZg"), base58.decode("Cn8eVZg"))
		end)

		T.it("string_to_base58 == encode", function()
			T.eq(base58.string_to_base58("hello"), base58.encode("hello"))
		end)

		T.it("base58_to_string == decode", function()
			T.eq(base58.base58_to_string("Cn8eVZg"), base58.decode("Cn8eVZg"))
		end)
	end)

end)
