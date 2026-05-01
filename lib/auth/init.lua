-- lib/auth/init.lua
-- Authentication primitives: JWT (HS256), session tokens, password hashing.
--
-- Public API:
--   M.jwt_encode(payload, secret)             -> string | (nil, errmsg)
--   M.jwt_decode(token, secret, opts)         -> table  | (nil, errmsg)
--   M.generate_token(n_bytes)                 -> string
--   M.hash_password(password, opts)           -> string
--   M.verify_password(password, hash_str)     -> boolean
--   M.hmac_sha256(key, message)               -> hex_string
--   M.constant_time_eq(a, b)                  -> boolean

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")
local base64 = require("lib.encode.base64")
local hmac = require("lib.hash.hmac")

local M = {}

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Convert standard base64 to base64url (RFC 4648 §5): + → -, / → _, strip =.
--: (string) -> string
local function base64url_encode(s)
	return (base64.encode(s, { pad = false }):gsub("+", "-"):gsub("/", "_"))
end

-- Convert base64url back to standard base64 and decode.
--: (string) -> string | (nil, string)
local function base64url_decode(s)
	-- Restore standard alphabet.
	s = s:gsub("-", "+"):gsub("_", "/")
	-- Restore padding.
	local rem = #s % 4
	if rem == 2 then
		s = s .. "=="
	elseif rem == 3 then
		s = s .. "="
	elseif rem == 1 then
		return nil, "invalid base64url: length mod 4 == 1"
	end
	return base64.decode(s)
end

-- Convert a hex string to raw binary bytes.
--: (string) -> string
local function hex_to_bytes(hex)
	return (hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

-- Convert raw binary bytes to lowercase hex string.
--: (string) -> string
local function bytes_to_hex(bin)
	local parts = {}
	for i = 1, #bin do
		parts[i] = string.format("%02x", string.byte(bin, i))
	end
	return table.concat(parts)
end

-- ── Timing-safe comparison ───────────────────────────────────────────────────

--- Compare two strings in constant time. Returns false for different lengths
--- (length itself leaks, but content does not).
--: (string, string) -> boolean
function M.constant_time_eq(a, b)
	if type(a) ~= "string" or type(b) ~= "string" then return false end
	if #a ~= #b then return false end
	local diff = 0
	for i = 1, #a do
		diff = bit.bor(diff, bit.bxor(string.byte(a, i), string.byte(b, i)))
	end
	return diff == 0
end

-- ── HMAC-SHA256 ──────────────────────────────────────────────────────────────

--- HMAC-SHA256 returning hex string.
--: (string, string) -> string
function M.hmac_sha256(key, message)
	return hmac.sha256(key, message)
end

-- Internal: HMAC-SHA256 returning raw binary.
--: (string, string) -> string
local function hmac_sha256_binary(key, message)
	return hmac.sha256_binary(key, message)
end

-- ── JWT (HS256) ──────────────────────────────────────────────────────────────

local JWT_HEADER = base64url_encode('{"alg":"HS256","typ":"JWT"}')

--- Encode a JWT with HS256.
--: ({ [string]: unknown }, string) -> string | (nil, string)
function M.jwt_encode(payload, secret)
	if type(payload) ~= "table" then
		return nil, "payload must be a table"
	end
	if type(secret) ~= "string" then
		return nil, "secret must be a string"
	end
	local payload_json = json.encode(payload)
	if not payload_json then
		return nil, "failed to encode payload as JSON"
	end
	local payload_b64 = base64url_encode(payload_json)
	local signing_input = JWT_HEADER .. "." .. payload_b64
	local sig = hmac_sha256_binary(secret, signing_input)
	local sig_b64 = base64url_encode(sig)
	return signing_input .. "." .. sig_b64
end

--- Decode and verify a JWT with HS256.
--- opts.verify_exp: set false to skip expiration check (default true).
--- opts.time_fn: required — function returning unix timestamp.
--: (string, string, { verify_exp: boolean | nil, time_fn: () -> number } | nil) -> table | (nil, string)
function M.jwt_decode(token, secret, opts)
	assert(opts and opts.time_fn, "jwt_decode requires opts.time_fn")
	if type(token) ~= "string" then
		return nil, "invalid token"
	end
	-- Split into 3 parts.
	local parts = {}
	for part in token:gmatch("[^%.]+") do
		parts[#parts + 1] = part
	end
	if #parts ~= 3 then
		return nil, "invalid token"
	end
	local header_b64, payload_b64, sig_b64 = parts[1], parts[2], parts[3]

	-- Verify signature.
	local signing_input = header_b64 .. "." .. payload_b64
	local expected_sig = hmac_sha256_binary(secret, signing_input)
	local expected_sig_b64 = base64url_encode(expected_sig)
	if not M.constant_time_eq(sig_b64, expected_sig_b64) then
		return nil, "invalid signature"
	end

	-- Decode payload.
	local payload_json, decode_err = base64url_decode(payload_b64)
	if not payload_json then
		return nil, "invalid token"
	end
	local payload, json_err = json.decode(payload_json)
	if not payload then
		return nil, "invalid token"
	end
	if type(payload) ~= "table" then
		return nil, "invalid token"
	end

	-- Time validation.
	local now = opts.time_fn()
	local verify_exp = true
	if opts.verify_exp == false then
		verify_exp = false
	end
	if verify_exp and payload.exp and type(payload.exp) == "number" then
		if now >= payload.exp then
			return nil, "token expired"
		end
	end
	if payload.nbf and type(payload.nbf) == "number" then
		if now < payload.nbf then
			return nil, "token not yet valid"
		end
	end

	return payload
end

-- ── Session tokens ───────────────────────────────────────────────────────────

-- Read random bytes from the best available source.
--: (number, () -> number) -> string
local function random_bytes(n, time_fn)
	-- Try LuaJIT FFI getrandom / /dev/urandom.
	local ok, ffi = pcall(require, "ffi")
	if ok then
		local buf = ffi.new("uint8_t[?]", n)
		-- Try getrandom(2) on Linux.
		local has_gr = pcall(function()
			ffi.cdef("int getrandom(void *buf, size_t buflen, unsigned int flags);")
		end)
		if has_gr then
			local ret = ffi.C.getrandom(buf, n, 0)
			if ret == n then
				local parts = {}
				for i = 0, n - 1 do parts[i + 1] = string.char(buf[i]) end
				return table.concat(parts)
			end
		end
		-- Try /dev/urandom via C open/read/close.
		pcall(function()
			ffi.cdef([[
				int open(const char *path, int flags);
				long read(int fd, void *buf, unsigned long count);
				int close(int fd);
			]])
		end)
		local fd = ffi.C.open("/dev/urandom", 0) -- O_RDONLY = 0
		if fd >= 0 then
			local got = ffi.C.read(fd, buf, n)
			ffi.C.close(fd)
			if got == n then
				local parts = {}
				for i = 0, n - 1 do parts[i + 1] = string.char(buf[i]) end
				return table.concat(parts)
			end
		end
	end
	-- Fallback: Lua io /dev/urandom (host only, not available in sandbox).
	if io and io.open then
		local f = io.open("/dev/urandom", "rb")
		if f then
			local data = f:read(n)
			f:close()
			if data and #data == n then return data end
		end
	end
	-- Last resort: math.random (NOT cryptographically secure).
	math.randomseed(time_fn())
	local parts = {}
	for i = 1, n do parts[i] = string.char(math.random(0, 255)) end
	return table.concat(parts)
end

--- Generate a random token as a hex string.
--: (opts: { time_fn: () -> number, n_bytes: number | nil }) -> string
function M.generate_token(opts)
	assert(opts and opts.time_fn, "generate_token requires opts.time_fn")
	local n_bytes = opts.n_bytes or 32
	return bytes_to_hex(random_bytes(n_bytes, opts.time_fn))
end

-- ── PBKDF2-SHA256 ────────────────────────────────────────────────────────────

-- XOR two equal-length binary strings.
--: (string, string) -> string
local function xor_strings(a, b)
	local bxor = bit.bxor
	local sbyte = string.byte
	local schar = string.char
	local out = {}
	for i = 1, #a do
		out[i] = schar(bxor(sbyte(a, i), sbyte(b, i)))
	end
	return table.concat(out)
end

-- PBKDF2 with HMAC-SHA256.
--: (string, string, number, number) -> string
local function pbkdf2_sha256(password, salt, iterations, dk_len)
	local n_blocks = math.ceil(dk_len / 32)
	local dk_parts = {}
	for i = 1, n_blocks do
		-- INT32_BE(i)
		local int_i = string.char(
			bit.band(bit.rshift(i, 24), 0xFF),
			bit.band(bit.rshift(i, 16), 0xFF),
			bit.band(bit.rshift(i, 8), 0xFF),
			bit.band(i, 0xFF)
		)
		local u = hmac_sha256_binary(password, salt .. int_i)
		local result = u
		for _ = 2, iterations do
			u = hmac_sha256_binary(password, u)
			result = xor_strings(result, u)
		end
		dk_parts[#dk_parts + 1] = result
	end
	local dk = table.concat(dk_parts)
	if #dk > dk_len then
		dk = dk:sub(1, dk_len)
	end
	return dk
end

-- ── Password hashing ─────────────────────────────────────────────────────────

local DEFAULT_ITERATIONS = 100000
local SALT_BYTES = 16
local DK_LEN = 32

--- Hash a password using PBKDF2-SHA256.
--- Returns PHC-style string: "pbkdf2:sha256:<iterations>$<salt_hex>$<hash_hex>"
--: (string, { iterations: number | nil, time_fn: () -> number }) -> string
function M.hash_password(password, opts)
	assert(opts and opts.time_fn, "hash_password requires opts.time_fn")
	local iterations = opts.iterations or DEFAULT_ITERATIONS
	local salt = random_bytes(SALT_BYTES, opts.time_fn)
	local salt_hex = bytes_to_hex(salt)
	local dk = pbkdf2_sha256(password, salt, iterations, DK_LEN)
	local hash_hex = bytes_to_hex(dk)
	return "pbkdf2:sha256:" .. iterations .. "$" .. salt_hex .. "$" .. hash_hex
end

--- Verify a password against a PHC-style hash string.
--: (string, string) -> boolean
function M.verify_password(password, hash_str)
	-- Parse "pbkdf2:sha256:<iterations>$<salt_hex>$<hash_hex>"
	local iterations_s, salt_hex, hash_hex = hash_str:match(
		"^pbkdf2:sha256:(%d+)%$([0-9a-f]+)%$([0-9a-f]+)$"
	)
	if not iterations_s then return false end
	local iterations = tonumber(iterations_s)
	if not iterations then return false end
	local salt = hex_to_bytes(salt_hex)
	local dk = pbkdf2_sha256(password, salt, iterations, DK_LEN)
	local computed_hex = bytes_to_hex(dk)
	return M.constant_time_eq(computed_hex, hash_hex)
end

return M
