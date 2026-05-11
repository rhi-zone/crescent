-- lib/uuid/init.lua
-- UUID v4 (random) and UUID v7 (timestamp-based, monotonic, sortable).
-- Tier selection for random bytes:
--   ffi_getrandom  — Linux getrandom(2) via FFI (best)
--   ffi_arc4random — macOS/BSD arc4random_buf via FFI
--   ffi_devurandom — /dev/urandom via FFI open/read/close
--   pure           — math.random seeded from os.time()+os.clock() (weak fallback)
--
-- Public API:
--   M.v4()          -> string  (UUID v4, e.g. "f47ac10b-58cc-4372-a567-0e02b2c3d479")
--   M.v7()          -> string  (UUID v7, monotonically increasing, sortable)
--   M.parse(s)      -> string | nil  (16-byte binary string, or nil on invalid input)
--   M.fmt(b)        -> string  (16-byte binary -> UUID string)
--   M.is_valid(s)   -> boolean
--   M._tier         -> "ffi_getrandom" | "ffi_arc4random" | "ffi_devurandom" | "pure"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Hex table for formatting ─────────────────────────────────────────────────

local HEX = {}
for i = 0, 255 do
	HEX[i] = string.format("%02x", i)
end

-- ── Random bytes: tier selection ─────────────────────────────────────────────

--:: rand_bytes_fn = (len: integer) -> { [integer]: integer }
local rand_bytes --: rand_bytes_fn | nil

-- Tier 1: Linux getrandom(2) via FFI
local function try_ffi_getrandom()
	local ffi = require("ffi")
	ffi.cdef [[
		long getrandom(void *buf, size_t buflen, unsigned int flags);
	]]
	local buf = ffi.new("unsigned char[16]")
	-- Probe: try calling it (will throw on non-Linux)
	local n = ffi.C.getrandom(buf, 16, 0)
	if n ~= 16 then error("getrandom returned " .. tostring(n)) end
	local _buf = buf
	local ffi_new = (ffi.new --[[:! (unknown, unknown) -> unknown]])
	return function(len)
		local b = (ffi_new("unsigned char[?]", len) --[[:! cdata]])
		local got = ffi.C.getrandom(b, len, 0)
		if got ~= len then error("getrandom short read") end
		local t = {}
		for i = 0, len - 1 do t[i + 1] = b[i] end
		return t
	end
end

-- Tier 2: macOS/BSD arc4random_buf via FFI
local function try_ffi_arc4random()
	local ffi = require("ffi")
	ffi.cdef [[
		void arc4random_buf(void *buf, size_t nbytes);
	]]
	-- Probe: call it
	local buf = ffi.new("unsigned char[16]")
	ffi.C.arc4random_buf(buf, 16)
	local _buf = buf
	local ffi_new = (ffi.new --[[:! (unknown, unknown) -> unknown]])
	return function(len)
		local b = (ffi_new("unsigned char[?]", len) --[[:! cdata]])
		ffi.C.arc4random_buf(b, len)
		local t = {}
		for i = 0, len - 1 do t[i + 1] = b[i] end
		return t
	end
end

-- Tier 3: /dev/urandom via FFI open/read/close
local function try_ffi_devurandom()
	local ffi = require("ffi")
	ffi.cdef [[
		int open(const char *pathname, int flags);
		ssize_t read(int fd, void *buf, size_t count);
		int close(int fd);
	]]
	local O_RDONLY = 0
	local fd = ffi.C.open("/dev/urandom", O_RDONLY)
	if fd < 0 then error("cannot open /dev/urandom") end
	-- Probe read
	local probe = ffi.new("unsigned char[1]")
	local n = ffi.C.read(fd, probe, 1)
	if n ~= 1 then ffi.C.close(fd); error("cannot read /dev/urandom") end
	ffi.C.close(fd)
	local ffi_new = (ffi.new --[[:! (unknown, unknown) -> unknown]])
	return function(len)
		local lfd = ffi.C.open("/dev/urandom", O_RDONLY)
		if lfd < 0 then error("cannot open /dev/urandom") end
		local b = (ffi_new("unsigned char[?]", len) --[[:! cdata]])
		local got = ffi.C.read(lfd, b, len)
		ffi.C.close(lfd)
		if got ~= len then error("devurandom short read") end
		local t = {}
		for i = 0, len - 1 do t[i + 1] = b[i] end
		return t
	end
end

-- Tier 4: pure Lua math.random (weak, functional)
-- Requires M.seed(n) to be called before use.
local pure_seeded = false
local function try_pure()
	return function(len)
		if not pure_seeded then error("uuid: pure tier requires M.seed(n) before use") end
		local t = {}
		for i = 1, len do t[i] = math.random(0, 255) end
		return t
	end
end

-- Try tiers in order, fall through gracefully.
do
	local ok, result

	ok, result = pcall(try_ffi_getrandom)
	if ok then rand_bytes = result; M._tier = "ffi_getrandom" end

	if not rand_bytes then
		ok, result = pcall(try_ffi_arc4random)
		if ok then rand_bytes = result; M._tier = "ffi_arc4random" end
	end

	if not rand_bytes then
		ok, result = pcall(try_ffi_devurandom)
		if ok then rand_bytes = result; M._tier = "ffi_devurandom" end
	end

	if not rand_bytes then
		ok, result = pcall(try_pure)
		if ok then rand_bytes = result; M._tier = "pure" end
	end
end

if not rand_bytes then
	error("lib/uuid: no random source available")
end

-- Seed the pure-Lua fallback tier's PRNG. Only needed when _tier == "pure".
-- On FFI tiers (getrandom, arc4random, devurandom), this is a no-op.
--: (integer) -> nil
M.seed = function(n)
	if not n then error("uuid.seed: seed is required") end
	math.randomseed(n)
	-- Discard initial values (some implementations have weak initial state)
	for _ = 1, 10 do math.random(255) end
	pure_seeded = true
end

-- ── Format: 16-byte table -> UUID string ─────────────────────────────────────

-- Internal: format from a table of 16 byte values (1-indexed)
local function fmt_bytes(b)
	return HEX[b[1]] .. HEX[b[2]] .. HEX[b[3]] .. HEX[b[4]]
		.. "-"
		.. HEX[b[5]] .. HEX[b[6]]
		.. "-"
		.. HEX[b[7]] .. HEX[b[8]]
		.. "-"
		.. HEX[b[9]] .. HEX[b[10]]
		.. "-"
		.. HEX[b[11]] .. HEX[b[12]] .. HEX[b[13]]
		.. HEX[b[14]] .. HEX[b[15]] .. HEX[b[16]]
end

-- ── M.fmt: 16-byte binary string -> UUID string ───────────────────────────────

--: (string) -> string
M.fmt = function(s)
	local b = { string.byte(s, 1, 16) }
	return fmt_bytes(b)
end

-- ── M.parse: UUID string -> 16-byte binary string | nil ──────────────────────

-- Accepts canonical form: 8-4-4-4-12 lowercase or uppercase hex.
--: (string) -> string | nil
M.parse = function(s)
	if type(s) ~= "string" or #s ~= 36 then return nil end
	if s:sub(9, 9) ~= "-" or s:sub(14, 14) ~= "-"
		or s:sub(19, 19) ~= "-" or s:sub(24, 24) ~= "-" then
		return nil
	end
	-- Strip dashes and parse hex pairs
	local hex = s:sub(1, 8) .. s:sub(10, 13) .. s:sub(15, 18)
		.. s:sub(20, 23) .. s:sub(25, 36)
	if #hex ~= 32 then return nil end
	local bytes = {}
	for i = 1, 32, 2 do
		local h = hex:sub(i, i + 1)
		local n = tonumber(h, 16)
		if not n then return nil end
		bytes[#bytes + 1] = n
	end
	return string.char(unpack(bytes))
end

-- ── M.is_valid ────────────────────────────────────────────────────────────────

--: (string) -> boolean
M.is_valid = function(s)
	return M.parse(s) ~= nil
end

-- ── M.v4: UUID v4 (random) ────────────────────────────────────────────────────

--: () -> string
M.v4 = function()
	local b = (rand_bytes --[[:! rand_bytes_fn]])(16)
	-- Set version: high nibble of byte 7 = 0x4
	b[7] = (b[7] % 16) + 0x40  -- clear high nibble, set to 4
	-- Set variant: high 2 bits of byte 9 = 10
	b[9] = (b[9] % 64) + 0x80  -- clear top 2 bits, set to 10
	return M.fmt(string.char(unpack(b, 1, 16)))
end

-- ── M.v7: UUID v7 (timestamp-based, monotonic) ───────────────────────────────
--
-- Layout (RFC 9562):
--   bits  0-47  : Unix ms timestamp (big-endian, 6 bytes)
--   bits 48-51  : version = 7 (high nibble of byte 6)
--   bits 52-63  : sequence counter (12 bits, bytes 6 low nibble + byte 7)
--   bits 64-65  : variant = 10 (high 2 bits of byte 8)
--   bits 66-127 : random (62 bits, bytes 8 low 6 bits + bytes 9-15)

local v7_last_ms = 0
local v7_seq = 0

-- v7(time_fn) -> string
-- time_fn: () -> integer — returns unix timestamp in seconds (e.g. os.time).
--: ((() -> integer)) -> string
M.v7 = function(time_fn)
	if not time_fn then error("uuid.v7: requires time_fn (function returning unix timestamp)") end
	local now_ms = math.floor(time_fn() * 1000)

	if now_ms > v7_last_ms then
		v7_last_ms = now_ms
		v7_seq = 0
	elseif now_ms == v7_last_ms then
		v7_seq = v7_seq + 1
		if v7_seq >= 4096 then
			-- Sequence exhausted: advance timestamp by 1ms (monotonic guarantee)
			v7_last_ms = v7_last_ms + 1
			v7_seq = 0
		end
	else
		-- Clock went backwards: keep last_ms, increment sequence
		v7_seq = v7_seq + 1
		if v7_seq >= 4096 then
			v7_last_ms = v7_last_ms + 1
			v7_seq = 0
		end
	end

	local ms = v7_last_ms
	local seq = v7_seq
	local rand = (rand_bytes --[[:! rand_bytes_fn]])(8)  -- random bytes for bits 64-127

	-- Encode timestamp: 48 bits big-endian across bytes 0-5
	-- ms fits in 48 bits (until year 10889)
	-- LuaJIT: numbers are doubles, 48-bit integers are exact.
	local ms_hi = math.floor(ms / 0x10000)  -- top 32 bits
	local ms_lo = ms % 0x10000              -- low 16 bits

	-- bytes 0-3: top 32 bits of ms
	local ms_hi_hi = math.floor(ms_hi / 0x10000)
	local ms_hi_lo = ms_hi % 0x10000
	-- byte 6: version (4 bits) | seq high nibble (4 bits)
	local seq_hi = math.floor(seq / 0x100) % 0x10  -- top 4 bits of 12-bit seq

	-- Build as binary string then format.
	-- Use separate string.char calls to avoid typechecker tuple confusion.
	local b1 = string.char(math.floor(ms_hi_hi / 0x100) % 0x100)
	local b2 = string.char(ms_hi_hi % 0x100)
	local b3 = string.char(math.floor(ms_hi_lo / 0x100) % 0x100)
	local b4 = string.char(ms_hi_lo % 0x100)
	local b5 = string.char(math.floor(ms_lo / 0x100) % 0x100)
	local b6 = string.char(ms_lo % 0x100)
	local b7 = string.char(0x70 + seq_hi)
	local b8 = string.char(seq % 0x100)
	local r1 = rand[1]
	local b9 = string.char(0x80 + (r1 % 64))
	local r2 = rand[2]; local r3 = rand[3]; local r4 = rand[4]
	local r5 = rand[5]; local r6 = rand[6]; local r7 = rand[7]; local r8 = rand[8]
	local bin = b1 .. b2 .. b3 .. b4 .. b5 .. b6 .. b7 .. b8 .. b9
		.. string.char(r2) .. string.char(r3) .. string.char(r4)
		.. string.char(r5) .. string.char(r6) .. string.char(r7) .. string.char(r8)
	return M.fmt(bin)
end

return M
