if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local auth = require("lib.auth")

-- ── JWT ──────────────────────────────────────────────────────────────────────

T.describe("jwt_encode", function()
	T.it("returns a string with 3 dot-separated parts", function()
		local token = auth.jwt_encode({ sub = "user123" }, "secret")
		T.ok(type(token) == "string")
		local parts = {}
		for part in token:gmatch("[^%.]+") do parts[#parts + 1] = part end
		T.eq(#parts, 3)
	end)

	T.it("round-trips various payload types", function()
		local payloads = {
			{ sub = "user123", name = "Alice" },
			{ count = 42, ratio = 3.14 },
			{ nested = { a = 1, b = { c = true } } },
			{ tags = { "admin", "user" } },
		}
		for _, p in ipairs(payloads) do
			local token = auth.jwt_encode(p, "secret")
			local decoded = auth.jwt_decode(token, "secret", { time_fn = os.time })
			T.ok(decoded ~= nil)
			-- Check known keys.
			for k, v in pairs(p) do
				if type(v) ~= "table" then
					T.eq(decoded[k], v)
				end
			end
		end
	end)
end)

T.describe("jwt_decode", function()
	T.it("recovers the payload", function()
		local token = auth.jwt_encode({ sub = "user123", role = "admin" }, "mysecret")
		local payload, err = auth.jwt_decode(token, "mysecret", { time_fn = os.time })
		T.ok(payload ~= nil, err)
		T.eq(payload.sub, "user123")
		T.eq(payload.role, "admin")
	end)

	T.it("returns error for wrong secret", function()
		local token = auth.jwt_encode({ sub = "user123" }, "secret1")
		local payload, err = auth.jwt_decode(token, "secret2", { time_fn = os.time })
		T.eq(payload, nil)
		T.eq(err, "invalid signature")
	end)

	T.it("returns error for expired token", function()
		local token = auth.jwt_encode({ sub = "user123", exp = os.time() - 10 }, "secret")
		local payload, err = auth.jwt_decode(token, "secret", { time_fn = os.time })
		T.eq(payload, nil)
		T.eq(err, "token expired")
	end)

	T.it("accepts expired token with verify_exp=false", function()
		local token = auth.jwt_encode({ sub = "user123", exp = os.time() - 10 }, "secret")
		local payload, err = auth.jwt_decode(token, "secret", { verify_exp = false, time_fn = os.time })
		T.ok(payload ~= nil, err)
		T.eq(payload.sub, "user123")
	end)

	T.it("returns error for nbf in future", function()
		local token = auth.jwt_encode({ sub = "user123", nbf = os.time() + 3600 }, "secret")
		local payload, err = auth.jwt_decode(token, "secret", { time_fn = os.time })
		T.eq(payload, nil)
		T.eq(err, "token not yet valid")
	end)

	T.it("rejects malformed JWT with too few parts", function()
		local payload, err = auth.jwt_decode("abc.def", "secret", { time_fn = os.time })
		T.eq(payload, nil)
		T.eq(err, "invalid token")
	end)

	T.it("rejects malformed JWT with invalid base64", function()
		local payload, err = auth.jwt_decode("!!!.@@@.###", "secret", { time_fn = os.time })
		T.eq(payload, nil)
		-- Should get either "invalid signature" or "invalid token".
		T.ok(err ~= nil)
	end)

	T.it("base64url parts contain only valid characters", function()
		local token = auth.jwt_encode({ sub = "user123", data = "\xff\x00\xfe" }, "secret")
		-- No +, /, or = in any part.
		T.ok(not token:find("+", 1, true), "no + in token")
		T.ok(not token:find("/", 1, true), "no / in token")
		T.ok(not token:find("=", 1, true), "no = in token")
	end)
end)

-- ── Session tokens ───────────────────────────────────────────────────────────

T.describe("generate_token", function()
	T.it("returns hex string of correct length", function()
		local token = auth.generate_token({ n_bytes = 32, time_fn = os.time })
		T.eq(#token, 64)
		T.ok(token:match("^[0-9a-f]+$") ~= nil, "should be hex")
	end)

	T.it("defaults to 32 bytes (64 hex chars)", function()
		local token = auth.generate_token({ time_fn = os.time })
		T.eq(#token, 64)
	end)

	T.it("respects custom byte count", function()
		local token = auth.generate_token({ n_bytes = 16, time_fn = os.time })
		T.eq(#token, 32)
	end)

	T.it("consecutive calls produce different tokens", function()
		local t1 = auth.generate_token({ time_fn = os.time })
		local t2 = auth.generate_token({ time_fn = os.time })
		T.neq(t1, t2)
	end)
end)

-- ── Password hashing ─────────────────────────────────────────────────────────

T.describe("hash_password", function()
	T.it("returns PHC-format string", function()
		local hash = auth.hash_password("mypassword", { time_fn = os.time })
		T.ok(hash:match("^pbkdf2:sha256:%d+%$[0-9a-f]+%$[0-9a-f]+$") ~= nil,
			"should match PHC format: " .. hash)
	end)

	T.it("uses configurable iterations", function()
		local hash = auth.hash_password("mypassword", { iterations = 1000, time_fn = os.time })
		local iter_s = hash:match("^pbkdf2:sha256:(%d+)%$")
		T.eq(iter_s, "1000")
	end)
end)

T.describe("verify_password", function()
	T.it("returns true for correct password", function()
		-- Use low iterations for speed.
		local hash = auth.hash_password("mypassword", { iterations = 1000, time_fn = os.time })
		T.ok(auth.verify_password("mypassword", hash))
	end)

	T.it("returns false for wrong password", function()
		local hash = auth.hash_password("mypassword", { iterations = 1000, time_fn = os.time })
		T.ok(not auth.verify_password("wrongpassword", hash))
	end)

	T.it("works across different hash calls (different salts)", function()
		local h1 = auth.hash_password("samepass", { iterations = 1000, time_fn = os.time })
		local h2 = auth.hash_password("samepass", { iterations = 1000, time_fn = os.time })
		-- Hashes differ (different salts).
		T.neq(h1, h2)
		-- Both verify.
		T.ok(auth.verify_password("samepass", h1))
		T.ok(auth.verify_password("samepass", h2))
	end)
end)

-- ── HMAC-SHA256 ──────────────────────────────────────────────────────────────

T.describe("hmac_sha256", function()
	-- RFC 4231 Test Case 2.
	T.it("RFC 4231 test vector: key='Jefe'", function()
		T.eq(auth.hmac_sha256("Jefe", "what do ya want for nothing?"),
			"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
	end)
end)

-- ── Constant-time comparison ─────────────────────────────────────────────────

T.describe("constant_time_eq", function()
	T.it("equal strings return true", function()
		T.ok(auth.constant_time_eq("hello", "hello"))
	end)

	T.it("different strings return false", function()
		T.ok(not auth.constant_time_eq("hello", "world"))
	end)

	T.it("different lengths return false", function()
		T.ok(not auth.constant_time_eq("short", "longer string"))
	end)
end)
