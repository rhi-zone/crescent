local T = require("lib.test.assert")
local hmac = require("lib.hash.hmac")

-- Helper: build a binary string from repeated byte value.
local function rep_byte(byte_val, count)
	return string.rep(string.char(byte_val), count)
end

-- Helper: hex string to binary string.
local function hex(s)
	return (s:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

-- ── RFC 4231 HMAC-SHA256 test vectors ───────────────────────────────────────

T.describe("HMAC-SHA256 (RFC 4231)", function()
	-- Test Case 1
	T.it("key=0x0b*20, data='Hi There'", function()
		local key = rep_byte(0x0b, 20)
		local data = "Hi There"
		T.eq(hmac.sha256(key, data),
			"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
	end)

	-- Test Case 2: "Jefe" / "what do ya want for nothing?"
	T.it("key='Jefe', data='what do ya want for nothing?'", function()
		T.eq(hmac.sha256("Jefe", "what do ya want for nothing?"),
			"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
	end)

	-- Test Case 3: key=0xaa*20, data=0xdd*50
	T.it("key=0xaa*20, data=0xdd*50", function()
		local key = rep_byte(0xaa, 20)
		local data = rep_byte(0xdd, 50)
		T.eq(hmac.sha256(key, data),
			"773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
	end)

	-- Test Case 4: key=0x01..0x19, data=0xcd*50
	T.it("key=0x01..0x19, data=0xcd*50", function()
		local key_parts = {}
		for i = 1, 25 do key_parts[i] = string.char(i) end
		local key = table.concat(key_parts)
		local data = rep_byte(0xcd, 50)
		T.eq(hmac.sha256(key, data),
			"82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b")
	end)

	-- Test Case 6: key larger than block size (131 bytes of 0xaa)
	T.it("key=0xaa*131 (longer than block size), data='Test Using Larger Than Block-Size Key - Hash Key First'", function()
		local key = rep_byte(0xaa, 131)
		local data = "Test Using Larger Than Block-Size Key - Hash Key First"
		T.eq(hmac.sha256(key, data),
			"60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
	end)

	-- Test Case 7: key larger than block size, longer data
	T.it("key=0xaa*131, data='This is a test using a larger than block-size key and a larger than block-size data...'", function()
		local key = rep_byte(0xaa, 131)
		local data = "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
		T.eq(hmac.sha256(key, data),
			"9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")
	end)
end)

-- ── RFC 2202 HMAC-SHA1 test vectors ─────────────────────────────────────────

T.describe("HMAC-SHA1 (RFC 2202)", function()
	-- Test Case 1
	T.it("key=0x0b*20, data='Hi There'", function()
		local key = rep_byte(0x0b, 20)
		T.eq(hmac.sha1(key, "Hi There"),
			"b617318655057264e28bc0b6fb378c8ef146be00")
	end)

	-- Test Case 2
	T.it("key='Jefe', data='what do ya want for nothing?'", function()
		T.eq(hmac.sha1("Jefe", "what do ya want for nothing?"),
			"effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
	end)

	-- Test Case 3: key=0xaa*20, data=0xdd*50
	T.it("key=0xaa*20, data=0xdd*50", function()
		local key = rep_byte(0xaa, 20)
		local data = rep_byte(0xdd, 50)
		T.eq(hmac.sha1(key, data),
			"125d7342b9ac11cd91a39af48aa17b4f63f175d3")
	end)

	-- Test Case 4: key=0x01..0x19, data=0xcd*50
	T.it("key=0x01..0x19, data=0xcd*50", function()
		local key_parts = {}
		for i = 1, 25 do key_parts[i] = string.char(i) end
		local key = table.concat(key_parts)
		local data = rep_byte(0xcd, 50)
		T.eq(hmac.sha1(key, data),
			"4c9007f4026250c6bc8414f9bf50c86c2d7235da")
	end)

	-- Test Case 6: key longer than block size (80 bytes of 0xaa)
	T.it("key=0xaa*80 (longer than block size), data='Test Using Larger Than Block-Size Key - Hash Key First'", function()
		local key = rep_byte(0xaa, 80)
		local data = "Test Using Larger Than Block-Size Key - Hash Key First"
		T.eq(hmac.sha1(key, data),
			"aa4ae5e15272d00e95705637ce8a3b55ed402112")
	end)
end)

-- ── Edge cases ──────────────────────────────────────────────────────────────

T.describe("HMAC edge cases", function()
	T.it("empty message", function()
		-- HMAC-SHA256 with key "key" and empty message.
		T.eq(hmac.sha256("key", ""),
			"5d5d139563c95b5967b9bd9a8c9b233a9dedb45072794cd232dc1b74832607d0")
	end)

	T.it("empty key", function()
		-- Empty key is padded to block_size with zeros.
		T.eq(hmac.sha256("", "message"),
			"eb08c1f56d5ddee07f7bdf80468083da06b64cf4fac64fe3a90883df5feacae4")
	end)

	T.it("binary output length is correct", function()
		local bin256 = hmac.sha256_binary("key", "msg")
		T.eq(#bin256, 32)
		local bin1 = hmac.sha1_binary("key", "msg")
		T.eq(#bin1, 20)
	end)

	T.it("hex and binary are consistent", function()
		local key, msg = "secret", "hello"
		local hex256 = hmac.sha256(key, msg)
		local bin256 = hmac.sha256_binary(key, msg)
		-- Convert binary back to hex and compare.
		local rebuilt = {}
		for i = 1, #bin256 do
			rebuilt[i] = string.format("%02x", string.byte(bin256, i))
		end
		T.eq(table.concat(rebuilt), hex256)
	end)
end)
