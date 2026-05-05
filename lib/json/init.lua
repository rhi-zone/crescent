-- lib/json/init.lua
-- JSON parser and serializer (pure Lua, RFC 8259).
-- Works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, char, sub, find, format, rep = string.byte, string.char, string.sub, string.find, string.format, string.rep
--: (string, integer) -> integer
local function byte1(s, i) return (string.byte(s, i, i) or 0) --[[:! integer]] end
local concat, sort = table.concat, table.sort
local floor, huge = math.floor, math.huge
local type, tostring, pairs, ipairs, next = type, tostring, pairs, ipairs, next

-- Sentinel for explicit JSON null
M.null = setmetatable({}, { __tostring = function() return "json.null" end })

-- ── Decoder ──────────────────────────────────────────────────────────────────

-- Lookup table: byte → true for whitespace bytes
local WS = { [0x20] = true, [0x09] = true, [0x0A] = true, [0x0D] = true }

-- Lookup table for hex digit values
local HEX = {}
do
	for i = 0, 9 do HEX[0x30 + i] = i end          -- '0'-'9'
	for i = 0, 5 do HEX[0x41 + i] = 10 + i end     -- 'A'-'F'
	for i = 0, 5 do HEX[0x61 + i] = 10 + i end     -- 'a'-'f'
end

-- UTF-16 surrogate pair → UTF-8
local function utf16_to_utf8(codepoint)
	if codepoint <= 0x7F then
		return char(codepoint)
	elseif codepoint <= 0x7FF then
		return char(0xC0 + floor(codepoint / 64), 0x80 + (codepoint % 64))
	elseif codepoint <= 0xFFFF then
		return char(0xE0 + floor(codepoint / 4096),
		            0x80 + floor(codepoint / 64) % 64,
		            0x80 + (codepoint % 64))
	else
		return char(0xF0 + floor(codepoint / 262144),
		            0x80 + floor(codepoint / 4096) % 64,
		            0x80 + floor(codepoint / 64) % 64,
		            0x80 + (codepoint % 64))
	end
end

local decode_string, decode_number, decode_object, decode_array

--: (string, integer, integer) -> (unknown, integer | nil, string | nil)
local function decode_value(s, i, n)
	-- skip whitespace
	while i <= n and WS[byte(s, i)] do i = i + 1 end
	if i > n then return nil, nil, "unexpected end of input" end

	local b = byte(s, i) or 0

	-- string
	if b == 0x22 then -- '"'
		return decode_string(s, i + 1, n)
	end

	-- number
	if b == 0x2D or (b >= 0x30 and b <= 0x39) then -- '-' or '0'-'9'
		return decode_number(s, i, n)
	end

	-- object
	if b == 0x7B then -- '{'
		return decode_object(s, i + 1, n)
	end

	-- array
	if b == 0x5B then -- '['
		return decode_array(s, i + 1, n)
	end

	-- true
	if sub(s, i, i + 3) == "true" then
		return true, i + 4, nil
	end

	-- false
	if sub(s, i, i + 4) == "false" then
		return false, i + 5, nil
	end

	-- null
	if sub(s, i, i + 3) == "null" then
		return M.null, i + 4, nil
	end

	return nil, nil, "unexpected character '" .. sub(s, i, i) .. "' at position " .. i
end

--: (string, integer, integer) -> (string | nil, integer | nil, string | nil)
decode_string = function(s, i, n)
	local parts = {}
	local start = i
	while i <= n do
		local b = byte(s, i) or 0
		if b == 0x22 then -- closing '"'
			parts[#parts + 1] = sub(s, start, i - 1)
			return concat(parts), i + 1, nil
		elseif b == 0x5C then -- '\'
			parts[#parts + 1] = sub(s, start, i - 1)
			i = i + 1
			if i > n then return nil, nil, "unexpected end of string escape" end
			local e = byte(s, i) or 0
			if e == 0x22 then parts[#parts + 1] = "\""
			elseif e == 0x5C then parts[#parts + 1] = "\\"
			elseif e == 0x2F then parts[#parts + 1] = "/"
			elseif e == 0x62 then parts[#parts + 1] = "\b"
			elseif e == 0x66 then parts[#parts + 1] = "\f"
			elseif e == 0x6E then parts[#parts + 1] = "\n"
			elseif e == 0x72 then parts[#parts + 1] = "\r"
			elseif e == 0x74 then parts[#parts + 1] = "\t"
			elseif e == 0x75 then -- \uXXXX
				if i + 4 > n then return nil, nil, "incomplete \\uXXXX escape" end
				local h1 = HEX[byte(s, i+1)]
				local h2 = HEX[byte(s, i+2)]
				local h3 = HEX[byte(s, i+3)]
				local h4 = HEX[byte(s, i+4)]
				if not (h1 and h2 and h3 and h4) then
					return nil, nil, "invalid hex in \\uXXXX escape at position " .. i
				end
				local cp = h1 * 4096 + h2 * 256 + h3 * 16 + h4
				-- Handle surrogate pairs
				if cp >= 0xD800 and cp <= 0xDBFF then
					-- high surrogate: expect \uXXXX low surrogate next
					if i + 10 > n or sub(s, i+5, i+6) ~= "\\u" then
						return nil, nil, "missing low surrogate after high surrogate at position " .. i
					end
					local l1 = HEX[byte(s, i+7)]
					local l2 = HEX[byte(s, i+8)]
					local l3 = HEX[byte(s, i+9)]
					local l4 = HEX[byte(s, i+10)]
					if not (l1 and l2 and l3 and l4) then
						return nil, nil, "invalid low surrogate at position " .. (i+6)
					end
					local low = l1 * 4096 + l2 * 256 + l3 * 16 + l4
					if low < 0xDC00 or low > 0xDFFF then
						return nil, nil, "expected low surrogate, got U+" .. format("%04X", low)
					end
					cp = 0x10000 + (cp - 0xD800) * 1024 + (low - 0xDC00)
					i = i + 10  -- i now at last hex digit of low surrogate; outer i+1 skips past it
				else
					i = i + 4  -- i now at last hex digit; outer i+1 skips past it
				end
				parts[#parts + 1] = utf16_to_utf8(cp)
			else
				return nil, nil, "invalid escape sequence \\" .. char(e) .. " at position " .. i
			end
			i = i + 1
			start = i
		elseif b < 0x20 then
			return nil, nil, "unescaped control character (0x" .. format("%02X", b) .. ") at position " .. i
		else
			i = i + 1
		end
	end
	return nil, nil, "unterminated string"
end

--: (string, integer, integer) -> (number | nil, integer | nil, string | nil)
decode_number = function(s, i, n)
	local j = i --: integer
	-- optional minus
	if byte(s, j) == 0x2D then j = j + 1 end
	local j1 = j --[[:! integer]]
	if j1 > n then return nil, nil, "expected digit after '-'" end
	-- integer part
	local b = byte1(s, j1)
	if b == 0x30 then
		j = j1 + 1  -- leading zero: only one allowed
	elseif b >= 0x31 and b <= 0x39 then
		j = j1 + 1
		local j2 = j --[[:! integer]]
		while j2 <= n and byte1(s, j2) >= 0x30 and byte1(s, j2) <= 0x39 do j2 = j2 + 1 end
		j = j2
	else
		return nil, nil, "invalid number at position " .. i
	end
	-- fractional part
	local is_float = false
	local j3 = j --[[:! integer]]
	if j3 <= n and byte(s, j3) == 0x2E then -- '.'
		is_float = true
		j3 = j3 + 1
		if j3 > n or byte1(s, j3) < 0x30 or byte1(s, j3) > 0x39 then
			return nil, nil, "expected digit after decimal point at position " .. j3
		end
		while j3 <= n and byte1(s, j3) >= 0x30 and byte1(s, j3) <= 0x39 do j3 = j3 + 1 end
	end
	-- exponent
	local j3e = j3 --[[:! integer]]
	if j3e <= n and (byte(s, j3e) == 0x65 or byte(s, j3e) == 0x45) then -- 'e' or 'E'
		is_float = true
		j3e = j3e + 1
		local j4 = j3e --[[:! integer]]
		if j4 <= n and (byte(s, j4) == 0x2B or byte(s, j4) == 0x2D) then j4 = j4 + 1 end
		local j5 = j4 --[[:! integer]]
		if j5 > n or byte1(s, j5) < 0x30 or byte1(s, j5) > 0x39 then
			return nil, nil, "expected digit in exponent at position " .. j5
		end
		while j5 <= n and byte1(s, j5) >= 0x30 and byte1(s, j5) <= 0x39 do j5 = j5 + 1 end
		j3e = j5
	end
	local numstr = sub(s, i, j3e - 1)
	local num = tonumber(numstr)
	if num == nil then return nil, nil, "invalid number: " .. numstr end
	return num, j3, nil
end

--: (string, integer, integer) -> (unknown, integer | nil, string | nil)
decode_array = function(s, i, n)
	local arr = {}
	local idx = 1
	-- skip whitespace
	while i <= n and WS[byte(s, i)] do i = i + 1 end
	if i > n then return nil, nil, "unterminated array" end
	-- empty array
	if byte(s, i) == 0x5D then return arr, i + 1, nil end -- ']'
	while true do
		local val, ni, err = decode_value(s, i, n)
		if err then return nil, nil, err end
		arr[idx] = val
		idx = idx + 1
		i = ni --[[:! integer]]
		-- skip whitespace
		while i <= n and WS[byte(s, i)] do i = i + 1 end
		if i > n then return nil, nil, "unterminated array" end
		local b = byte(s, i)
		if b == 0x5D then return arr, i + 1, nil end -- ']'
		if b ~= 0x2C then return nil, nil, "expected ',' or ']' in array at position " .. i end -- ','
		i = i + 1
		-- check for trailing comma
		while i <= n and WS[byte(s, i)] do i = i + 1 end
		if i <= n and byte(s, i) == 0x5D then
			return nil, nil, "trailing comma in array at position " .. (i - 1)
		end
	end
end

--: (string, integer, integer) -> (unknown, integer | nil, string | nil)
decode_object = function(s, i, n)
	local obj = {}
	-- skip whitespace
	while i <= n and WS[byte(s, i)] do i = i + 1 end
	if i > n then return nil, nil, "unterminated object" end
	-- empty object
	if byte(s, i) == 0x7D then return obj, i + 1, nil end -- '}'
	while true do
		-- skip whitespace
		while i <= n and WS[byte(s, i)] do i = i + 1 end
		if i > n then return nil, nil, "unterminated object" end
		-- key must be a string
		if byte(s, i) ~= 0x22 then -- '"'
			return nil, nil, "expected string key in object at position " .. i
		end
		local key, ni, err = decode_string(s, i + 1, n)
		if err then return nil, nil, err end
		i = ni --[[:! integer]]
		local skey = key --[[:! string]]
		-- skip whitespace, expect ':'
		while i <= n and WS[byte(s, i)] do i = i + 1 end
		if i > n or byte(s, i) ~= 0x3A then -- ':'
			return nil, nil, "expected ':' in object at position " .. i
		end
		i = i + 1
		-- value
		local val, ni2, err2 = decode_value(s, i, n)
		if err2 then return nil, nil, err2 end
		i = ni2 --[[:! integer]]
		obj[skey] = val
		-- skip whitespace
		while i <= n and WS[byte(s, i)] do i = i + 1 end
		if i > n then return nil, nil, "unterminated object" end
		local b = byte(s, i)
		if b == 0x7D then return obj, i + 1, nil end -- '}'
		if b ~= 0x2C then -- ','
			return nil, nil, "expected ',' or '}' in object at position " .. i
		end
		i = i + 1
		-- check for trailing comma
		while i <= n and WS[byte(s, i)] do i = i + 1 end
		if i <= n and byte(s, i) == 0x7D then
			return nil, nil, "trailing comma in object at position " .. (i - 1)
		end
	end
end

--- Decode a JSON string into a Lua value.
-- Returns value, nil on success; nil, errmsg on error.
-- JSON null decodes to json.null sentinel.
--: (string) -> (unknown, string | nil)
M.decode = function(s)
	if type(s) ~= "string" then
		return nil, "json.decode: expected string, got " .. type(s)
	end
	local n = #s
	local val, ni, err = decode_value(s, 1, n)
	if err then return nil, err end
	local i = ni --[[:! integer]]
	-- check for trailing non-whitespace
	while i <= n and WS[byte(s, i)] do i = i + 1 end
	if i <= n then
		return nil, "unexpected trailing content at position " .. i
	end
	return val, nil
end

-- ── Encoder ──────────────────────────────────────────────────────────────────

-- Characters that must be escaped in JSON strings
local ESCAPE = {} --: { [integer]: string }
ESCAPE[0x22] = '\\"'   -- "
ESCAPE[0x5C] = '\\\\'  -- \
ESCAPE[0x08] = '\\b'
ESCAPE[0x0C] = '\\f'
ESCAPE[0x0A] = '\\n'
ESCAPE[0x0D] = '\\r'
ESCAPE[0x09] = '\\t'
for i = 0, 0x1F do
	if not ESCAPE[i] then ESCAPE[i] = format("\\u%04X", i) end
end

local function encode_string(s)
	local result = {}
	local start = 1 --: integer
	local i = 1 --: integer
	local n = #s --: integer
	while i <= n do
		local b = byte1(s, i)
		local esc = ESCAPE[b]
		if esc then
			if i > start then result[#result + 1] = sub(s, start, i - 1) end
			result[#result + 1] = esc
			i = i + 1
			start = i --[[:! integer]]
		else
			i = i + 1
		end
	end
	if start <= n then result[#result + 1] = sub(s, start, n) end
	return '"' .. concat(result) .. '"'
end

local encode_value

--: (t: { [integer]: unknown }, opts: { indent: number | nil, sort_keys: boolean | nil } | nil, depth: integer) -> (string | nil, string | nil)
local function encode_array(t, opts, depth)
	if #t == 0 then return "[]" end
	local indent = opts and opts.indent
	local parts = {}
	if indent then
		local ind = floor(indent --[[:! number]])
		local inner_pad = rep(" ", (depth + 1) * ind)
		local close_pad = rep(" ", depth * ind)
		for i = 1, #t do
			local v, err = encode_value(t[i], opts, depth + 1)
			if not v then return nil, err end
			parts[i] = inner_pad .. v
		end
		return "[\n" .. concat(parts, ",\n") .. "\n" .. close_pad .. "]"
	else
		for i = 1, #t do
			local v, err = encode_value(t[i], opts, depth + 1)
			if not v then return nil, err end
			parts[i] = v
		end
		return "[" .. concat(parts, ",") .. "]"
	end
end

--: (t: { [string]: unknown }, opts: { indent: number | nil, sort_keys: boolean | nil } | nil, depth: integer) -> (string | nil, string | nil)
local function encode_object(t, opts, depth)
	local keys = {}
	for k in pairs(t) do
		if type(k) ~= "string" then
			return nil, "json.encode: object keys must be strings, got " .. type(k)
		end
		keys[#keys + 1] = k
	end
	if #keys == 0 then return "{}" end
	if opts and opts.sort_keys then sort(keys) end
	local indent = opts and opts.indent
	local parts = {}
	if indent then
		local ind = floor(indent --[[:! number]])
		local inner_pad = rep(" ", (depth + 1) * ind)
		local close_pad = rep(" ", depth * ind)
		for idx, k in ipairs(keys) do
			local v, err = encode_value(t[k], opts, depth + 1)
			if not v then return nil, err end
			parts[idx] = inner_pad .. encode_string(k) .. ": " .. v
		end
		return "{\n" .. concat(parts, ",\n") .. "\n" .. close_pad .. "}"
	else
		for idx, k in ipairs(keys) do
			local v, err = encode_value(t[k], opts, depth + 1)
			if not v then return nil, err end
			parts[idx] = encode_string(k) .. ":" .. v
		end
		return "{" .. concat(parts, ",") .. "}"
	end
end

--: (unknown, { indent: number | nil, sort_keys: boolean | nil } | nil, integer) -> (string | nil, string | nil)
encode_value = function(val, opts, depth)
	local t = type(val)
	if val == M.null then
		return "null", nil
	elseif t == "nil" then
		return "null", nil
	elseif t == "boolean" then
		return val and "true" or "false", nil
	elseif t == "number" then
		local nval = val --[[:! number]]
		if nval ~= nval then return nil, "json.encode: NaN is not allowed" end
		if nval == huge or nval == -huge then return nil, "json.encode: Infinity is not allowed" end
		-- Represent integers without decimal point; handle negative zero as 0
		if nval == floor(nval) and nval >= -1e15 and nval <= 1e15 then
			if nval == 0 then return "0", nil end
			return format("%.0f", nval), nil
		end
		-- Use shortest representation
		local s = format("%.17g", nval)
		return s, nil
	elseif t == "string" then
		return encode_string(val --[[:! string]]), nil
	elseif t == "table" then
		-- Determine array vs object: array if sequential integer keys from 1
		-- An empty table with no keys encodes as array []
		local tval = val --[[:! { [integer]: unknown }]]
		local n = #tval
		local is_array = true
		-- Check that table has no non-integer or out-of-range keys
		local count = 0
		for k in pairs(tval) do
			count = count + 1
			if type(k) ~= "number" or floor(k --[[:! number]]) ~= k or (k --[[:! number]]) < 1 or (k --[[:! number]]) > n then
				is_array = false
				break
			end
		end
		-- If count doesn't match n, there are holes → not a pure array
		if is_array and count ~= n then is_array = false end
		if is_array then
			return encode_array(tval, opts, depth)
		else
			return encode_object(val --[[:! { [string]: unknown }]], opts, depth)
		end
	else
		return nil, "json.encode: unsupported type " .. t
	end
end

--- Encode a Lua value as a JSON string.
-- Returns string, nil on success; nil, errmsg on error.
-- Options: { indent: number|nil, sort_keys: boolean|nil }
-- Use json.null to encode explicit null. Lua nil encodes as null.
--: (unknown, { indent: number | nil, sort_keys: boolean | nil } | nil) -> (string | nil, string | nil)
M.encode = function(val, opts)
	return encode_value(val, opts, 0)
end

-- ── Aliases ───────────────────────────────────────────────────────────────────

M.parse         = M.decode
M.stringify     = M.encode
M.json_to_string = M.decode
M.string_to_json = M.encode

return M
