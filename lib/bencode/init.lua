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
local encode --: ((unknown) -> (string | nil, string | nil)) | nil

--: (unknown) -> (string | nil, string | nil)
local function encode_value(val)
	local t = type(val)
	if t == "number" then
		local n = val --[[:! number]]
		if n ~= n then return nil, "bencode: cannot encode NaN" end
		if n == 1/0 or n == -1/0 then return nil, "bencode: cannot encode infinity" end
		-- integers only
		if n % 1 ~= 0 then return nil, "bencode: cannot encode non-integer number" end
		return "i" .. tostring(n) .. "e"
	elseif t == "string" then
		local s = val --[[:! string]]
		return #s .. ":" .. s
	elseif t == "table" then
		local tbl = val --[[:! { [unknown]: unknown }]]
		-- detect list vs dict: if sequential integer keys from 1..#val, treat as list
		local n = #tbl
		local is_list = true
		if n == 0 then
			-- check if there are any keys at all
			for _ in pairs(tbl) do
				is_list = false
				break
			end
		else
			-- verify all keys are 1..n
			local count = 0
			for _ in pairs(tbl) do
				count = count + 1
			end
			if count ~= n then
				is_list = false
			end
		end
		if is_list then
			local parts = { "l" }
			for i = 1, n do
				local enc, err = encode_value(tbl[i])
				if not enc then return nil, err end
				parts[#parts + 1] = enc
			end
			parts[#parts + 1] = "e"
			return concat(parts)
		else
			-- dictionary: all keys must be strings, sorted
			local keys = {} --: { [integer]: string }
			for k in pairs(tbl) do
				if type(k) ~= "string" then
					return nil, "bencode: dictionary keys must be strings, got " .. type(k)
				end
				keys[#keys + 1] = k --[[:! string]]
			end
			sort(keys)
			local parts = { "d" }
			for i = 1, #keys do
				local k = keys[i]
				parts[#parts + 1] = #k .. ":" .. k
				local enc, err = encode_value(tbl[k])
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
--: (string, integer) -> (unknown, integer | nil, string | nil)
local function decode_at(s, pos)
	if pos > #s then return nil, nil, "bencode: unexpected end of input" end
	local _c_raw = byte(s, pos)
	local c = (_c_raw or 0) --[[:! integer]]
	if c == 0x69 then -- 'i'
		local e_pos = s:find("e", pos + 1, true)
		if not e_pos then return nil, nil, "bencode: unterminated integer" end
		local e_pos_i = e_pos --[[:! integer]]
		local num_str = sub(s, pos + 1, e_pos_i - 1)
		if #num_str == 0 then return nil, nil, "bencode: empty integer" end
		-- leading zeros check (i03e is invalid, i-0e is invalid, but i0e is ok)
		if #num_str > 1 and ((byte(num_str, 1)) or 0 --[[:! integer]]) == 0x30 then
			return nil, nil, "bencode: leading zeros in integer"
		end
		if #num_str > 1 and ((byte(num_str, 1)) or 0 --[[:! integer]]) == 0x2d and ((byte(num_str, 2)) or 0 --[[:! integer]]) == 0x30 then
			return nil, nil, "bencode: negative zero in integer"
		end
		local num = tonumber(num_str)
		if not num then return nil, nil, "bencode: invalid integer '" .. num_str .. "'" end
		return num, e_pos_i + 1, nil
	elseif c == 0x6c then -- 'l'
		local list = {}
		local p = pos + 1
		while true do
			if p > #s then return nil, nil, "bencode: unterminated list" end
			if ((byte(s, p)) or 0 --[[:! integer]]) == 0x65 then -- 'e'
				return list, p + 1, nil
			end
			local val, next_p, verr = decode_at(s, p)
			if verr then return nil, nil, verr end
			list[#list + 1] = val
			p = next_p --[[:! integer]]
		end
	elseif c == 0x64 then -- 'd'
		local dict = {}
		local p = pos + 1
		local prev_key --: string|nil
		while true do
			if p > #s then return nil, nil, "bencode: unterminated dictionary" end
			if ((byte(s, p)) or 0 --[[:! integer]]) == 0x65 then -- 'e'
				return dict, p + 1, nil
			end
			-- key must be a string
			local key, key_next, kerr = decode_at(s, p)
			if kerr then return nil, nil, kerr end
			if type(key) ~= "string" then
				return nil, nil, "bencode: dictionary key must be a string"
			end
			local key_s = key --[[:! string]]
			-- keys must be sorted
			if prev_key and key_s < prev_key then
				return nil, nil, "bencode: dictionary keys not sorted"
			end
			prev_key = key_s
			-- value
			local val, val_next, verr2 = decode_at(s, key_next --[[:! integer]])
			if verr2 then return nil, nil, verr2 end
			dict[key_s] = val
			p = val_next --[[:! integer]]
		end
	elseif c >= 0x30 and c <= 0x39 then -- '0'-'9' → string
		local colon = s:find(":", pos, true)
		if not colon then return nil, nil, "bencode: invalid string length prefix" end
		local colon_i = colon --[[:! integer]]
		local len_s = sub(s, pos, colon_i - 1)
		local len_i = 0
		for i = 1, #len_s do
			local d = (byte(len_s, i) or 0) --[[:! integer]] - 0x30
			if d < 0 or d > 9 then len_i = -1 break end
			len_i = len_i * 10 + d
		end
		if len_i < 0 then return nil, nil, "bencode: invalid string length" end
		local str_end = colon_i + len_i
		if str_end > #s then return nil, nil, "bencode: string truncated" end
		return sub(s, colon_i + 1, str_end), str_end + 1, nil
	else
		return nil, nil, "bencode: unexpected byte " .. tostring(c) .. " at position " .. tostring(pos)
	end
end

-- Public decode: returns (value) on success, (nil, errmsg) on failure.
--: (string) -> (unknown, string | nil)
local function decode(s)
	if type(s) ~= "string" then return nil, "bencode: expected string input" end
	if #s == 0 then return nil, "bencode: empty input" end
	local val, _next_pos, err = decode_at(s, 1)
	if err then return nil, err end
	return val
end

-- Primary names (type-in-the-name convention)
M.string_to_table = decode
M.table_to_string = encode

-- Aliases for swappability
M.encode = encode
M.decode = decode

return M
