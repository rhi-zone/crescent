if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local sha1 = require("lib.hash.sha1")
local T = require("lib.test.assert")

T.describe("sha1", function()

	-- RFC 3174 section 7.3 test vectors (verified against POSIX sha1sum).
	T.describe("RFC 3174 test vectors", function()
		T.it("test 1: 'abc'", function()
			T.eq(sha1.sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
		end)

		-- RFC 3174 test 2: 448-bit input.
		T.it("test 2: 448-bit 'abcdbcde...' string", function()
			local s = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnomnopnopq"
			T.eq(sha1.sha1(s), "e0e8b455e838f433338cdf41a540a98fbc5d5142")
		end)

		-- RFC 3174 test 3: one million repetitions of "a".
		T.it("test 3: 'a' × 1,000,000", function()
			T.eq(sha1.sha1(string.rep("a", 1000000)), "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
		end)

		-- RFC 3174 test 4: "01234567" repeated 10 times (80 bytes).
		T.it("test 4: '01234567' × 10 (80 bytes)", function()
			T.eq(sha1.sha1(string.rep("01234567", 10)), "3eb04424b20997bcda17c283ba015772a816d3b9")
		end)
	end)

	T.describe("empty string", function()
		T.it("sha1('') = da39a3ee...", function()
			T.eq(sha1.sha1(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
		end)
	end)

	T.describe("binary output", function()
		T.it("binary() returns a 20-byte string", function()
			T.eq(#sha1.binary("abc"), 20)
		end)

		T.it("binary() round-trips to hex", function()
			local bin = sha1.binary("abc")
			local hex = ""
			for i = 1, #bin do
				hex = hex .. string.format("%02x", string.byte(bin, i))
			end
			T.eq(hex, sha1.sha1("abc"))
		end)

		T.it("binary('') returns 20 bytes and round-trips", function()
			local bin = sha1.binary("")
			T.eq(#bin, 20)
			local hex = ""
			for i = 1, #bin do
				hex = hex .. string.format("%02x", string.byte(bin, i))
			end
			T.eq(hex, sha1.sha1(""))
		end)
	end)

	-- Boundary lengths exercise the padding logic: SHA-1 pads to a multiple of
	-- 512 bits (64 bytes), appending 0x80, zero bytes, and an 8-byte length.
	-- Messages of 55, 56, 64, 119, 120, and 128 bytes hit the critical points
	-- where the length field fits in the same block vs spills to a new block.
	T.describe("block-boundary padding", function()
		-- 55 bytes: fits in first block with padding.
		T.it("55-byte input", function()
			T.eq(sha1.sha1(string.rep("x", 55)), "cef734ba81a024479e09eb5a75b6ddae62e6abf1")
		end)

		-- 56 bytes: first byte that requires a second padding block
		-- (55 data + 1 start-bit = 56, leaving only 8 bytes for length which
		-- exactly fills the block -- but 56 data bytes push padding to block 2).
		T.it("56-byte input", function()
			T.eq(sha1.sha1(string.rep("x", 56)), "901305367c259952f4e7af8323f480d59f81335b")
		end)

		-- 64 bytes: exactly one full block of data, padding spills to second block.
		T.it("64-byte input (one full block)", function()
			T.eq(sha1.sha1(string.rep("x", 64)), "bb2fa3ee7afb9f54c6dfb5d021f14b1ffe40c163")
		end)

		-- 119 bytes: two blocks; 119 + 1 + 8 = 128, length fits exactly.
		T.it("119-byte input", function()
			T.eq(sha1.sha1(string.rep("x", 119)), "4300320394f7ee239bcdce7d3b8bcee173a0cd5c")
		end)

		-- 120 bytes: two blocks; requires third padding block for length field.
		T.it("120-byte input", function()
			T.eq(sha1.sha1(string.rep("x", 120)), "ceb2821639c4b6dcb10bce0e522ca2e608ce056d")
		end)

		-- 128 bytes: exactly two full blocks, padding spills to third block.
		T.it("128-byte input (two full blocks)", function()
			T.eq(sha1.sha1(string.rep("x", 128)), "150fa3fbdc899bd0b8f95a9fb6027f564d953762")
		end)
	end)

	-- HMAC-SHA1 vectors from RFC 2202.
	if sha1.hmac then
		T.describe("HMAC-SHA1 (RFC 2202)", function()
			-- Test case 1: key = 0x0b × 20, data = "Hi There"
			T.it("key=0x0b×20, data='Hi There'", function()
				local key = string.rep(string.char(0x0b), 20)
				T.eq(sha1.hmac(key, "Hi There"), "b617318655057264e28bc0b6fb378c8ef146be00")
			end)

			-- Test case 2: key = "Jefe", data = "what do ya want for nothing?"
			T.it("key='Jefe', data='what do ya want for nothing?'", function()
				T.eq(sha1.hmac("Jefe", "what do ya want for nothing?"), "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
			end)
		end)
	end

end)
