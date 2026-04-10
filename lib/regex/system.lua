-- lib/regex/system.lua
-- PCRE2 FFI tier for regex library.
-- _tier = "system-pcre2"

local ffi = require("ffi")

-- Try loading PCRE2-8 under several names.
local lib
local names = { "pcre2-8", "libpcre2-8", "libpcre2-8.so.0", "pcre2" }
for i = 1, #names do
	local ok, l = pcall(ffi.load, names[i])
	if ok then lib = l; break end
end
if not lib then
	error("pcre2: could not load library")
end

ffi.cdef[[
typedef struct pcre2_real_code_8 pcre2_code_8;
typedef struct pcre2_real_match_data_8 pcre2_match_data_8;

pcre2_code_8 *pcre2_compile_8(
	const uint8_t *pattern, size_t length, uint32_t options,
	int *errorcode, size_t *erroroffset, void *ccontext);
void pcre2_code_free_8(pcre2_code_8 *code);

pcre2_match_data_8 *pcre2_match_data_create_from_pattern_8(
	const pcre2_code_8 *code, void *gcontext);
void pcre2_match_data_free_8(pcre2_match_data_8 *match_data);

int pcre2_match_8(
	const pcre2_code_8 *code, const uint8_t *subject, size_t length,
	size_t startoffset, uint32_t options,
	pcre2_match_data_8 *match_data, void *mcontext);

size_t *pcre2_get_ovector_pointer_8(pcre2_match_data_8 *match_data);
uint32_t pcre2_get_ovector_count_8(pcre2_match_data_8 *match_data);

int pcre2_get_error_message_8(int errorcode, uint8_t *buffer, size_t bufflen);
]]

-- PCRE2 option flags
local PCRE2_CASELESS       = 0x00000008
local PCRE2_DOTALL         = 0x00000020
local PCRE2_EXTENDED       = 0x00000080
local PCRE2_MULTILINE      = 0x00000400
local PCRE2_UTF            = 0x00080000
local PCRE2_NO_UTF_CHECK   = 0x40000000

local FLAG_MAP = {
	i = PCRE2_CASELESS,
	m = PCRE2_MULTILINE,
	s = PCRE2_DOTALL,
	x = PCRE2_EXTENDED,
}

local errbuf = ffi.new("uint8_t[256]")

local function pcre2_errmsg(code)
	lib.pcre2_get_error_message_8(code, errbuf, 256)
	return ffi.string(errbuf)
end

-- Regex object methods
local Regex = {}
Regex.__index = Regex

function Regex:match(subject, init)
	local offset = (init or 1) - 1
	local rc = lib.pcre2_match_8(
		self._code, subject, #subject, offset,
		PCRE2_NO_UTF_CHECK, self._md, nil)
	if rc < 0 then return nil end
	local ov = lib.pcre2_get_ovector_pointer_8(self._md)
	local count = tonumber(lib.pcre2_get_ovector_count_8(self._md))
	if count > 1 then
		-- Return capture groups
		local caps = {}
		for i = 1, count - 1 do
			local s = tonumber(ov[i * 2])
			local e = tonumber(ov[i * 2 + 1])
			if s >= 0 and e >= s then
				caps[#caps + 1] = subject:sub(s + 1, e)
			else
				caps[#caps + 1] = false
			end
		end
		return unpack(caps)
	end
	-- No capture groups — return full match
	local s = tonumber(ov[0])
	local e = tonumber(ov[1])
	return subject:sub(s + 1, e)
end

function Regex:find(subject, init)
	local offset = (init or 1) - 1
	local rc = lib.pcre2_match_8(
		self._code, subject, #subject, offset,
		PCRE2_NO_UTF_CHECK, self._md, nil)
	if rc < 0 then return nil end
	local ov = lib.pcre2_get_ovector_pointer_8(self._md)
	local s = tonumber(ov[0])
	local e = tonumber(ov[1])
	return s + 1, e
end

function Regex:gmatch(subject)
	local offset = 0
	local len = #subject
	return function()
		if offset > len then return nil end
		local rc = lib.pcre2_match_8(
			self._code, subject, len, offset,
			PCRE2_NO_UTF_CHECK, self._md, nil)
		if rc < 0 then return nil end
		local ov = lib.pcre2_get_ovector_pointer_8(self._md)
		local count = tonumber(lib.pcre2_get_ovector_count_8(self._md))
		local match_end = tonumber(ov[1])
		-- Advance past empty match to avoid infinite loop
		if match_end == offset then
			offset = offset + 1
		else
			offset = match_end
		end
		if count > 1 then
			local caps = {}
			for i = 1, count - 1 do
				local s = tonumber(ov[i * 2])
				local e = tonumber(ov[i * 2 + 1])
				if s >= 0 and e >= s then
					caps[#caps + 1] = subject:sub(s + 1, e)
				else
					caps[#caps + 1] = false
				end
			end
			return unpack(caps)
		end
		local s = tonumber(ov[0])
		local e = tonumber(ov[1])
		return subject:sub(s + 1, e)
	end
end

--: (self: Regex, subject: string, replacement: string | (match: string, ...captures: string) -> string, n?: number) -> string, number
function Regex:gsub(subject, replacement, n)
	local parts = {}
	local count = 0
	local offset = 0
	local len = #subject
	local is_fn = type(replacement) == "function"
	while offset <= len do
		if n and count >= n then break end
		local rc = lib.pcre2_match_8(
			self._code, subject, len, offset,
			PCRE2_NO_UTF_CHECK, self._md, nil)
		if rc < 0 then break end
		local ov = lib.pcre2_get_ovector_pointer_8(self._md)
		local ov_count = tonumber(lib.pcre2_get_ovector_count_8(self._md))
		local ms = tonumber(ov[0])
		local me = tonumber(ov[1])
		-- Append text before match
		if ms > offset then
			parts[#parts + 1] = subject:sub(offset + 1, ms)
		end
		-- Build captures list
		local caps = {}
		for i = 1, ov_count - 1 do
			local s = tonumber(ov[i * 2])
			local e = tonumber(ov[i * 2 + 1])
			if s >= 0 and e >= s then
				caps[i] = subject:sub(s + 1, e)
			else
				caps[i] = false
			end
		end
		local full_match = subject:sub(ms + 1, me)
		if is_fn then
			if #caps > 0 then
				parts[#parts + 1] = replacement(full_match, unpack(caps)) or full_match
			else
				parts[#parts + 1] = replacement(full_match) or full_match
			end
		else
			-- Process backreferences \0..\9 in replacement string
			local rep = replacement:gsub("\\(%d)", function(d)
				local idx = tonumber(d)
				if idx == 0 then return full_match end
				return caps[idx] or ""
			end)
			parts[#parts + 1] = rep
		end
		count = count + 1
		if me == offset then
			-- Empty match — advance one byte
			if offset < len then
				parts[#parts + 1] = subject:sub(offset + 1, offset + 1)
			end
			offset = offset + 1
		else
			offset = me
		end
	end
	-- Append remaining
	if offset <= len then
		parts[#parts + 1] = subject:sub(offset + 1)
	end
	return table.concat(parts), count
end

function Regex:split(subject)
	local result = {}
	local offset = 0
	local len = #subject
	while offset <= len do
		local rc = lib.pcre2_match_8(
			self._code, subject, len, offset,
			PCRE2_NO_UTF_CHECK, self._md, nil)
		if rc < 0 then
			result[#result + 1] = subject:sub(offset + 1)
			return result
		end
		local ov = lib.pcre2_get_ovector_pointer_8(self._md)
		local ms = tonumber(ov[0])
		local me = tonumber(ov[1])
		if me == ms and me == offset then
			-- Empty match at current position — skip one byte
			if offset < len then
				result[#result + 1] = subject:sub(offset + 1, offset + 1)
			end
			offset = offset + 1
		else
			result[#result + 1] = subject:sub(offset + 1, ms)
			offset = me
		end
	end
	-- Trailing empty string if subject ends at a delimiter
	if offset == len + 1 then
		-- already consumed everything
	end
	return result
end

-- Module table
local M = {}
M._tier = "system-pcre2"

function M.compile(pattern, flags)
	local opts = PCRE2_UTF
	if flags then
		for i = 1, #flags do
			local f = FLAG_MAP[flags:sub(i, i)]
			if not f then
				return nil, "regex: unknown flag '" .. flags:sub(i, i) .. "'"
			end
			opts = bit.bor(opts, f)
		end
	end
	local errcode = ffi.new("int[1]")
	local erroffset = ffi.new("size_t[1]")
	local code = lib.pcre2_compile_8(pattern, #pattern, opts, errcode, erroffset, nil)
	if code == nil then
		return nil, "regex: " .. pcre2_errmsg(errcode[0]) .. " at offset " .. tonumber(erroffset[0])
	end
	code = ffi.gc(code, lib.pcre2_code_free_8)
	local md = lib.pcre2_match_data_create_from_pattern_8(code, nil)
	if md == nil then
		return nil, "regex: could not create match data"
	end
	md = ffi.gc(md, lib.pcre2_match_data_free_8)
	local r = setmetatable({ _code = code, _md = md }, Regex)
	return r
end

function M.match(pattern, subject, init)
	local r, err = M.compile(pattern)
	if not r then return nil, err end
	return r:match(subject, init)
end

function M.find(pattern, subject, init)
	local r, err = M.compile(pattern)
	if not r then return nil, err end
	return r:find(subject, init)
end

function M.gmatch(pattern, subject)
	local r, err = M.compile(pattern)
	if not r then return function() return nil end end
	return r:gmatch(subject)
end

function M.gsub(pattern, subject, replacement, n)
	local r, err = M.compile(pattern)
	if not r then return nil, err end
	return r:gsub(subject, replacement, n)
end

function M.split(pattern, subject)
	local r, err = M.compile(pattern)
	if not r then return nil, err end
	return r:split(subject)
end

return M
