if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local md5 = require("lib.hash.md5")

T.describe("md5", function()
	T.describe("RFC 1321 test vectors", function()
		T.it("empty string", function()
			T.eq(md5.digest(""), "d41d8cd98f00b204e9800998ecf8427e")
		end)

		T.it("a", function()
			T.eq(md5.digest("a"), "0cc175b9c0f1b6a831c399e269772661")
		end)

		T.it("abc", function()
			T.eq(md5.digest("abc"), "900150983cd24fb0d6963f7d28e17f72")
		end)

		T.it("message digest", function()
			T.eq(md5.digest("message digest"), "f96b697d7cb7938d525a2f31aaf161d0")
		end)

		T.it("a-z", function()
			T.eq(md5.digest("abcdefghijklmnopqrstuvwxyz"), "c3fcd3d76192e4007dfb496cca67e13b")
		end)

		T.it("A-Za-z0-9", function()
			T.eq(
				md5.digest("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
				"d174ab98d277d9f5a5611c2c9f419d9f"
			)
		end)

		T.it("numeric repetition", function()
			T.eq(
				md5.digest("12345678901234567890123456789012345678901234567890123456789012345678901234567890"),
				"57edf4a22be3c955ac49da2e2107b67a"
			)
		end)
	end)

	T.describe("digest_raw", function()
		T.it("returns 16 bytes", function()
			local raw = md5.digest_raw("")
			T.ok(raw)
			T.eq(#raw, 16)
		end)

		T.it("raw matches hex for empty string", function()
			local raw = md5.digest_raw("")
			local hex = md5.digest("")
			-- Verify hex is the hex encoding of raw
			local rebuilt = {}
			for i = 1, 16 do
				rebuilt[#rebuilt + 1] = string.format("%02x", string.byte(raw, i))
			end
			T.eq(table.concat(rebuilt), hex)
		end)

		T.it("raw matches hex for abc", function()
			local raw = md5.digest_raw("abc")
			local hex = md5.digest("abc")
			local rebuilt = {}
			for i = 1, 16 do
				rebuilt[#rebuilt + 1] = string.format("%02x", string.byte(raw, i))
			end
			T.eq(table.concat(rebuilt), hex)
		end)
	end)

	T.describe("streaming", function()
		T.it("matches one-shot for empty", function()
			local h = md5.new()
			T.eq(h:digest(), md5.digest(""))
		end)

		T.it("matches one-shot for abc", function()
			local h = md5.new()
			h:update("abc")
			T.eq(h:digest(), md5.digest("abc"))
		end)

		T.it("multi-chunk matches one-shot", function()
			local h = md5.new()
			h:update("a")
			h:update("b")
			h:update("c")
			T.eq(h:digest(), md5.digest("abc"))
		end)

		T.it("multi-chunk message digest", function()
			local h = md5.new()
			h:update("message")
			h:update(" ")
			h:update("digest")
			T.eq(h:digest(), md5.digest("message digest"))
		end)

		T.it("single byte at a time", function()
			local input = "abcdefghijklmnopqrstuvwxyz"
			local h = md5.new()
			for i = 1, #input do
				h:update(input:sub(i, i))
			end
			T.eq(h:digest(), md5.digest(input))
		end)

		T.it("digest_raw streaming matches one-shot", function()
			local h = md5.new()
			h:update("abc")
			T.eq(h:digest_raw(), md5.digest_raw("abc"))
		end)

		T.it("digest does not consume state (can call twice)", function()
			local h = md5.new()
			h:update("abc")
			local d1 = h:digest()
			local d2 = h:digest()
			T.eq(d1, d2)
		end)

		T.it("update returns self for chaining", function()
			local h = md5.new()
			local ret = h:update("abc")
			T.eq(ret, h)
		end)
	end)

	T.describe("reset", function()
		T.it("reset produces empty hash", function()
			local h = md5.new()
			h:update("abc")
			h:reset()
			T.eq(h:digest(), md5.digest(""))
		end)

		T.it("reset then new data", function()
			local h = md5.new()
			h:update("abc")
			h:reset()
			h:update("message digest")
			T.eq(h:digest(), md5.digest("message digest"))
		end)

		T.it("reset returns self for chaining", function()
			local h = md5.new()
			local ret = h:reset()
			T.eq(ret, h)
		end)
	end)

	T.describe("binary data", function()
		T.it("null bytes", function()
			local data = "\0\0\0\0"
			local hex = md5.digest(data)
			T.ok(hex)
			T.eq(#hex, 32)
		end)

		T.it("all byte values", function()
			local parts = {}
			for i = 0, 255 do parts[#parts + 1] = string.char(i) end
			local data = table.concat(parts)
			local hex = md5.digest(data)
			T.ok(hex)
			T.eq(#hex, 32)
		end)

		T.it("null bytes produce consistent results", function()
			T.eq(md5.digest("\0"), md5.digest("\0"))
		end)

		T.it("different null-byte lengths differ", function()
			T.neq(md5.digest("\0"), md5.digest("\0\0"))
		end)
	end)

	T.describe("large input", function()
		T.it("1000 bytes", function()
			local data = ("a"):rep(1000)
			local hex = md5.digest(data)
			T.ok(hex)
			T.eq(#hex, 32)
		end)

		T.it("1000 bytes streaming matches one-shot", function()
			local data = ("a"):rep(1000)
			local h = md5.new()
			-- Feed in 100-byte chunks
			for i = 1, 1000, 100 do
				h:update(data:sub(i, i + 99))
			end
			T.eq(h:digest(), md5.digest(data))
		end)

		T.it("exact block boundary (64 bytes)", function()
			local data = ("x"):rep(64)
			local h = md5.new()
			h:update(data)
			T.eq(h:digest(), md5.digest(data))
		end)

		T.it("just over block boundary (65 bytes)", function()
			local data = ("x"):rep(65)
			local h = md5.new()
			h:update(data)
			T.eq(h:digest(), md5.digest(data))
		end)

		T.it("two full blocks (128 bytes)", function()
			local data = ("y"):rep(128)
			local h = md5.new()
			h:update(data)
			T.eq(h:digest(), md5.digest(data))
		end)

		T.it("55 bytes (pad boundary)", function()
			local data = ("z"):rep(55)
			T.eq(md5.digest(data), md5.digest(data))
			T.eq(#md5.digest(data), 32)
		end)

		T.it("56 bytes (pad boundary, needs extra block)", function()
			local data = ("z"):rep(56)
			T.eq(md5.digest(data), md5.digest(data))
			T.eq(#md5.digest(data), 32)
		end)

		T.it("10000 bytes streaming in odd chunks", function()
			local data = ("abcdefghij"):rep(1000)
			local h = md5.new()
			local pos = 1
			local chunk_sizes = { 7, 13, 31, 64, 65, 1, 100, 63 }
			local ci = 1
			while pos <= #data do
				local sz = chunk_sizes[ci]
				ci = ci % #chunk_sizes + 1
				h:update(data:sub(pos, pos + sz - 1))
				pos = pos + sz
			end
			T.eq(h:digest(), md5.digest(data))
		end)
	end)

	T.describe("consistency", function()
		T.it("same input always same output", function()
			for _ = 1, 10 do
				T.eq(md5.digest("test"), md5.digest("test"))
			end
		end)

		T.it("different inputs differ", function()
			T.neq(md5.digest("a"), md5.digest("b"))
			T.neq(md5.digest("abc"), md5.digest("abd"))
			T.neq(md5.digest(""), md5.digest("a"))
		end)

		T.it("encode is an alias for digest", function()
			T.eq(md5.encode, md5.digest)
		end)

		T.it("_tier is pure", function()
			T.eq(md5._tier, "pure")
		end)
	end)

	T.describe("error handling", function()
		T.it("digest returns nil, errmsg for non-string", function()
			local r, err = md5.digest(123)
			T.eq(r, nil)
			T.ok(err)
		end)

		T.it("digest_raw returns nil, errmsg for non-string", function()
			local r, err = md5.digest_raw(nil)
			T.eq(r, nil)
			T.ok(err)
		end)

		T.it("streaming update returns nil, errmsg for non-string", function()
			local h = md5.new()
			local r, err = h:update(42)
			T.eq(r, nil)
			T.ok(err)
		end)
	end)

	T.describe("known values (cross-check)", function()
		-- Additional known MD5 values for cross-validation
		T.it("The quick brown fox", function()
			T.eq(
				md5.digest("The quick brown fox jumps over the lazy dog"),
				"9e107d9d372bb6826bd81d3542a419d6"
			)
		end)

		T.it("The quick brown fox (with period)", function()
			T.eq(
				md5.digest("The quick brown fox jumps over the lazy dog."),
				"e4d909c290d0fb1ca068ffaddf22cbd0"
			)
		end)
	end)
end)
