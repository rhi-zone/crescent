if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--: string
M._tier = "pure"

local byte = string.byte
local sub = string.sub
local concat = table.concat
local sort = table.sort
local type = type
local tostring = tostring
local tonumber = tonumber

-- Encode a Lua value to a bencode string.
-- Returns (string) on success, (nil, errmsg) on failure.
--: (unknown) -> string | (nil, string)
local encode

--: (unknown) -> string | (nil, string)
local function encode_value(val)
	local t = type(val)
	if t == "number" then
		if val ~= val then return nil, "bencode: cannot encode NaN" end
		if val == 1/0 or val == -1/0 then return nil, "bencode: cannot encode infinity" end
		-- integers only
		if val % 1 ~= 0 then return nil, "bencode: cannot encode non-integer number" end
		return "i" .. tostring(val) .. "e"
	elseif t == "string" then
		return #val .. ":" .. val
	elseif t == "table" then
		-- detect list vs dict: if sequential integer keys from 1..#val, treat as list
		local n = #val
		local is_list = true
		if n == 0 then
			-- check if there are any keys at all
			for _ in pairs(val) do
				is_list = false
				break
			end
		else
			-- verify all keys are 1..n
			local count = 0
			for _ in pairs(val) do
				count = count + 1
			end
			if count ~= n then
				is_list = false
			end
		end
		if is_list then
			local parts = { "l" }
			for i = 1, n do
				local enc, err = encode_value(val[i])
				if not enc then return nil, err end
				parts[#parts + 1] = enc
			end
			parts[#parts + 1] = "e"
			return concat(parts)
		else
			-- dictionary: all keys must be strings, sorted
			local keys = {}
			for k in pairs(val) do
				if type(k) ~= "string" then
					return nil, "bencode: dictionary keys must be strings, got " .. type(k)
				end
				keys[#keys + 1] = k
			end
			sort(keys)
			local parts = { "d" }
			for i = 1, #keys do
				local k = keys[i]
				parts[#parts + 1] = #k .. ":" .. k
				local enc, err = encode_value(val[k])
				if not enc then return nil, err end
				parts[#parts + 1] = enc
			end
			parts[#parts + 1] = "e"
			return concat(parts)
		end
	elseif t == "boolean" then
		return nil, "bencode: cannot encode boolean"
	elseif t == "nil" then
		return nil, "bencode: cannot encode nil"
	else
		return nil, "bencode: cannot encode " .. t
	end
end

encode = encode_value

-- Decode a bencode string to a Lua value.
-- Returns (value, next_pos) on success, (nil, errmsg) on failure.
-- Internal: pos is 1-indexed position in string.
--: (string, number) -> (unknown, number) | (nil, string)
local function decode_at(s, pos)
	if pos > #s then return nil, "bencode: unexpected end of input" end
	local c = byte(s, pos)
	if c == 0x69 then -- 'i'
		local e_pos = s:find("e", pos + 1, true)
		if not e_pos then return nil, "bencode: unterminated integer" end
		local num_str = sub(s, pos + 1, e_pos - 1)
		if #num_str == 0 then return nil, "bencode: empty integer" end
		-- leading zeros check (i03e is invalid, i-0e is invalid, but i0e is ok)
		if #num_str > 1 and byte(num_str, 1) == 0x30 then
			return nil, "bencode: leading zeros in integer"
		end
		if #num_str > 1 and byte(num_str, 1) == 0x2d and byte(num_str, 2) == 0x30 then
			return nil, "bencode: negative zero in integer"
		end
		local num = tonumber(num_str)
		if not num then return nil, "bencode: invalid integer '" .. num_str .. "'" end
		return num, e_pos + 1
	elseif c == 0x6c then -- 'l'
		local list = {}
		local p = pos + 1
		while true do
			if p > #s then return nil, "bencode: unterminated list" end
			if byte(s, p) == 0x65 then -- 'e'
				return list, p + 1
			end
			local val, next_p = decode_at(s, p)
			if val == nil and type(next_p) == "string" then return nil, next_p end
			list[#list + 1] = val
			p = next_p
		end
	elseif c == 0x64 then -- 'd'
		local dict = {}
		local p = pos + 1
		local prev_key
		while true do
			if p > #s then return nil, "bencode: unterminated dictionary" end
			if byte(s, p) == 0x65 then -- 'e'
				return dict, p + 1
			end
			-- key must be a string
			local key, key_next = decode_at(s, p)
			if key == nil and type(key_next) == "string" then return nil, key_next end
			if type(key) ~= "string" then
				return nil, "bencode: dictionary key must be a string"
			end
			-- keys must be sorted
			if prev_key and key < prev_key then
				return nil, "bencode: dictionary keys not sorted"
			end
			prev_key = key
			-- value
			local val, val_next = decode_at(s, key_next)
			if val == nil and type(val_next) == "string" then return nil, val_next end
			dict[key] = val
			p = val_next
		end
	elseif c >= 0x30 and c <= 0x39 then -- '0'-'9' → string
		local colon = s:find(":", pos, true)
		if not colon then return nil, "bencode: invalid string length prefix" end
		local len = tonumber(sub(s, pos, colon - 1))
		if not len then return nil, "bencode: invalid string length" end
		local str_end = colon + len
		if str_end > #s then return nil, "bencode: string truncated" end
		return sub(s, colon + 1, str_end), str_end + 1
	else
		return nil, "bencode: unexpected byte " .. tostring(c) .. " at position " .. tostring(pos)
	end
end

-- Public decode: returns (value) on success, (nil, errmsg) on failure.
--: (string) -> unknown | (nil, string)
local function decode(s)
	if type(s) ~= "string" then return nil, "bencode: expected string input" end
	if #s == 0 then return nil, "bencode: empty input" end
	local val, next_pos = decode_at(s, 1)
	if val == nil and type(next_pos) == "string" then return nil, next_pos end
	return val
end

-- Primary names (type-in-the-name convention)
M.string_to_table = decode
M.table_to_string = encode

-- Aliases for swappability
M.encode = encode
M.decode = decode

return M
