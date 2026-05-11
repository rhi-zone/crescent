-- lib/regex/system.lua
-- PCRE2 FFI tier for regex library.
-- _tier = "system-pcre2"

local ffi = require("ffi")

-- Try loading PCRE2-8 under several names.
local lib
local names = { "pcre2-8", "libpcre2-8", "libpcre2-8.so.0", "pcre2" } --: { [integer]: string }
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

local lib_a = lib --[[:! $FfiC]]

local function pcre2_errmsg(code)
	lib_a.pcre2_get_error_message_8(code, errbuf, 256)
	return ffi.string(errbuf --[[:! cdata]])
end

-- Regex object methods
--:: RegexObj = { _code: cdata, _md: cdata }
local Regex = {}
Regex.__index = Regex

function Regex:match(subject, init)
	local self_a = self --[[:! RegexObj]]
	local subject_s = subject --[[:! string]]
	local offset = (init or 1) - 1
	local rc = lib_a.pcre2_match_8(
		self_a._code, subject_s, #subject_s, offset,
		PCRE2_NO_UTF_CHECK, self_a._md, nil)
	if (rc --[[:! integer]]) < 0 then return nil end
	local ov = lib_a.pcre2_get_ovector_pointer_8(self_a._md)	local count = (tonumber(lib_a.pcre2_get_ovector_count_8(self_a._md)) or 0) --[[:! integer]]
	if count > 1 then
		-- Return capture groups
		local caps = {}
		for i = 1, count - 1 do
			local s = (tonumber(ov[i * 2]) or 0) --[[:! integer]]
			local e = (tonumber(ov[i * 2 + 1]) or 0) --[[:! integer]]
			if s >= 0 and e >= s then
				caps[#caps + 1] = subject_s:sub(s + 1, e)
			else
				caps[#caps + 1] = false
			end
		end
		return unpack(caps)
	end
	-- No capture groups — return full match
	local s = (tonumber(ov[0]) or 0) --[[:! integer]]
	local e = (tonumber(ov[1]) or 0) --[[:! integer]]
	return subject_s:sub(s + 1, e)
end

function Regex:find(subject, init)
	local self_a = self --[[:! RegexObj]]
	local subject_s = subject --[[:! string]]
	local offset = (init or 1) - 1
	local rc = lib_a.pcre2_match_8(
		self_a._code, subject_s, #subject_s, offset,
		PCRE2_NO_UTF_CHECK, self_a._md, nil)
	if (rc --[[:! integer]]) < 0 then return nil end
	local ov = lib_a.pcre2_get_ovector_pointer_8(self_a._md)	local s = (tonumber(ov[0]) or 0) --[[:! integer]]
	local e = (tonumber(ov[1]) or 0) --[[:! integer]]
	return s + 1, e
end

function Regex:gmatch(subject)
	local self_a = self --[[:! RegexObj]]
	local subject_s = subject --[[:! string]]
	local offset = 0
	local len = #subject_s
	return function()
		if offset > len then return nil end
		local rc = lib_a.pcre2_match_8(
			self_a._code, subject_s, len, offset,
			PCRE2_NO_UTF_CHECK, self_a._md, nil)
		if (rc --[[:! integer]]) < 0 then return nil end
		local ov = lib_a.pcre2_get_ovector_pointer_8(self_a._md)		local count = (tonumber(lib_a.pcre2_get_ovector_count_8(self_a._md)) or 0) --[[:! integer]]
		local match_end = (tonumber(ov[1]) or 0) --[[:! integer]]
		-- Advance past empty match to avoid infinite loop
		if match_end == offset then
			offset = offset + 1
		else
			offset = match_end
		end
		if count > 1 then
			local caps = {}
			for i = 1, count - 1 do
				local s = (tonumber(ov[i * 2]) or 0) --[[:! integer]]
				local e = (tonumber(ov[i * 2 + 1]) or 0) --[[:! integer]]
				if s >= 0 and e >= s then
					caps[#caps + 1] = subject_s:sub(s + 1, e)
				else
					caps[#caps + 1] = false
				end
			end
			return unpack(caps)
		end
		local s = (tonumber(ov[0]) or 0) --[[:! integer]]
		local e = (tonumber(ov[1]) or 0) --[[:! integer]]
		return subject_s:sub(s + 1, e)
	end
end

--: (self: Regex, subject: string, replacement: string | ((match: string, ...string) -> string), n: number | nil) -> (string, number)
function Regex:gsub(subject, replacement, n)
	local self_a = self --[[:! RegexObj]]
	local subject_s = subject --[[:! string]]
	local replacement_fn = replacement --[[:! (match: string, ...string) -> string]]
	local replacement_s = replacement --[[:! string]]
	local parts = {} --: { [integer]: string }
	local count = 0
	local offset = 0
	local len = #subject_s
	local is_fn = type(replacement) == "function"
	while offset <= len do
		if n and count >= n then break end
		local rc = lib_a.pcre2_match_8(
			self_a._code, subject_s, len, offset,
			PCRE2_NO_UTF_CHECK, self_a._md, nil)
		if (rc --[[:! integer]]) < 0 then break end
		local ov = lib_a.pcre2_get_ovector_pointer_8(self_a._md)		local ov_count = (tonumber(lib_a.pcre2_get_ovector_count_8(self_a._md)) or 0) --[[:! integer]]
		local ms = (tonumber(ov[0]) or 0) --[[:! integer]]
		local me = (tonumber(ov[1]) or 0) --[[:! integer]]
		-- Append text before match
		if ms > offset then
			local part1 = subject_s:sub(offset + 1, ms)
			parts[#parts + 1] = part1
		end
		-- Build captures list
		local caps = {}
		for i = 1, ov_count - 1 do
			local s = (tonumber(ov[i * 2]) or 0) --[[:! integer]]
			local e = (tonumber(ov[i * 2 + 1]) or 0) --[[:! integer]]
			if s >= 0 and e >= s then
				caps[i] = subject_s:sub(s + 1, e)
			else
				caps[i] = false
			end
		end
		local full_match = subject_s:sub(ms + 1, me)
		if is_fn then
			if #caps > 0 then
				parts[#parts + 1] = replacement_fn(full_match, unpack(caps)) or full_match
			else
				parts[#parts + 1] = replacement_fn(full_match) or full_match
			end
		else
			-- Process backreferences \0..\9 in replacement string
			local rep, _ = replacement_s:gsub("\\(%d)", function(d)
				local idx = (tonumber(d) or 0) --[[:! integer]]
				if idx == 0 then return full_match end
				return caps[idx] or ""
			end)
			parts[#parts + 1] = ((rep --[[: unknown]]) --[[:! string]])
		end
		count = count + 1
		if me == offset then
			-- Empty match — advance one byte
			if offset < len then
				parts[#parts + 1] = subject_s:sub(offset + 1, offset + 1)
			end
			offset = offset + 1
		else
			offset = me
		end
	end
	-- Append remaining
	if offset <= len then
		parts[#parts + 1] = subject_s:sub(offset + 1)
	end
	return table.concat(parts), count
end

function Regex:split(subject)
	local self_a = self --[[:! RegexObj]]
	local subject_s = subject --[[:! string]]
	local result = {}
	local offset = 0
	local len = #subject_s
	while offset <= len do
		local rc = lib_a.pcre2_match_8(
			self_a._code, subject_s, len, offset,
			PCRE2_NO_UTF_CHECK, self_a._md, nil)
		if (rc --[[:! integer]]) < 0 then
			result[#result + 1] = subject_s:sub(offset + 1)
			return result
		end
		local ov = lib_a.pcre2_get_ovector_pointer_8(self_a._md)		local ms = (tonumber(ov[0]) or 0) --[[:! integer]]
		local me = (tonumber(ov[1]) or 0) --[[:! integer]]
		if me == ms and me == offset then
			-- Empty match at current position — skip one byte
			if offset < len then
				result[#result + 1] = subject_s:sub(offset + 1, offset + 1)
			end
			offset = offset + 1
		else
			result[#result + 1] = subject_s:sub(offset + 1, ms)
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

--:: Regex = { ... }

function M.compile(pattern, flags)
	local pattern_s = pattern --[[:! string]]
	local flags_s = flags --[[:! string]]
	local opts = PCRE2_UTF
	if flags then
		for i = 1, #flags_s do
			local f = FLAG_MAP[flags_s:sub(i, i)]
			if not f then
				return nil, "regex: unknown flag '" .. flags_s:sub(i, i) .. "'"
			end
			opts = bit.bor(opts, f)
		end
	end
	local errcode = ffi.new("int[1]")
	local erroffset = ffi.new("size_t[1]")
	local code = lib_a.pcre2_compile_8(pattern_s, #pattern_s, opts, errcode, erroffset, nil)
	if code == nil then
		local errcode_a = errcode --[[:! cdata]]
		local erroffset_a = erroffset --[[:! cdata]]
		return nil, "regex: " .. pcre2_errmsg(errcode_a[0]) .. " at offset " .. tostring(tonumber(erroffset_a[0]))
	end
	code = ffi.gc(code, lib_a.pcre2_code_free_8)
	local md = lib_a.pcre2_match_data_create_from_pattern_8(code, nil)
	if md == nil then
		return nil, "regex: could not create match data"
	end
	md = ffi.gc(md, lib_a.pcre2_match_data_free_8)
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
