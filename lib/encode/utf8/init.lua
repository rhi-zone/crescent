if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local bor = bit.bor; local band = bit.band; local lshift = bit.lshift; local rshift = bit.rshift
local byte = string.byte; local char = string.char

local mod = {}

--: string
mod.charpattern = "[\0-\x7F\xC2-\xF4][\x80-\xBF]*"

--: (...integer) -> string
mod.char = function (...)
	local parts = {}
	local nums = { ... } --: { [integer]: integer }
	local k = 0 --: integer
	for i = 1, #nums do
		local n = nums[i] or 0
		k = k + 1
		if n <= 0x7f then
			parts[k] = char(n)
		elseif n <= 0x7ff then
			local c1 = bor(0xc0, rshift(n, 6)); local c2 = bor(0x80, band(n, 0x3f))
			parts[k] = char(c1, c2)
		elseif n <= 0xffff then
			local c1 = bor(0xe0, rshift(n, 12)); local c2 = bor(0x80, band(rshift(n, 6), 0x3f)); local c3 = bor(0x80, band(n, 0x3f))
			parts[k] = char(c1, c2, c3)
		else
			local c1 = bor(0xf0, rshift(n, 18)); local c2 = bor(0x80, band(rshift(n, 12), 0x3f)); local c3 = bor(0x80, band(rshift(n, 6), 0x3f)); local c4 = bor(0x80, band(n, 0x3f))
			parts[k] = char(c1, c2, c3, c4)
		end
	end
	return table.concat(parts)
end

local high_nibble_to_length = {} --: { [integer]: integer }
high_nibble_to_length[0] = 1; high_nibble_to_length[1] = 1; high_nibble_to_length[2] = 1; high_nibble_to_length[3] = 1
high_nibble_to_length[4] = 1; high_nibble_to_length[5] = 1; high_nibble_to_length[6] = 1; high_nibble_to_length[7] = 1
high_nibble_to_length[8] = 0; high_nibble_to_length[9] = 0; high_nibble_to_length[10] = 0; high_nibble_to_length[11] = 0
high_nibble_to_length[12] = 2; high_nibble_to_length[13] = 2; high_nibble_to_length[14] = 3; high_nibble_to_length[15] = 4
local length_to_signifier = { 0, 0xc0, 0xe0, 0xf0 } --: { [integer]: integer }
local length_to_mask = { 0, 0x1f, 0xf, 0x7 } --: { [integer]: integer }

--: (string) -> boolean
mod.is_valid = function (bytes)
	local start = 1
	if #bytes >= 3 then
		local a, b, c = bytes:byte(1, 3)
		if a == 0xef and b == 0xbb and c == 0xbf then start = start + 3 end
	end
	local remain = 0 --: integer
	for i = start, #bytes do
		local b = bytes:byte(i) or 0
		if remain == 0 then
			if b < 0x80 then --[[continue]]
			elseif b < 0xc0 then return false --[[continuation]]
			elseif b < 0xe0 then remain = 1
			elseif b < 0xf0 then remain = 2
			elseif b < 0xf8 then remain = 3
			else return false end
		else
			if b < 0x80 or b >= 0xc0 then return false
			else remain = remain - 1 end
		end
	end
	return remain == 0
end

--: (string, integer | nil, integer | nil) -> (integer | nil, integer | nil)
mod.len = function (s, i, j)
	i = i or 1
	if i < 0 then i = #s + i + 1 end
	j = j or #s
	if j < 0 then j = #s + j + 1 end
	if i == #s + 1 then return 0 end
	-- not sure this is correct behavior
	if i > #s or band(byte(s, i) or 0, 0xc0) == 0x80 then return nil, i end
	local len = 0 --: integer
	while i <= j do
		local b = byte(s, i) or 0
		-- tight inner loop for ascii
		while i <= j and band(b, 0x80) == 0 do len = len + 1; i = i + 1; b = byte(s, i) or 0 end
		if i <= j then
			-- predicted length
			local plen = high_nibble_to_length[rshift(b, 4)] or 0
			if plen == 0 or b >= 0xf8 then return nil, i end
			for k = i + 1, i + plen - 1 do
				if band(byte(s, k) or 0, 0xc0) ~= 0x80 then return nil, i end
			end
			len = len + 1
			i = i + plen
		end
	end
	return len
end

--: (string, integer | nil, integer | nil) -> (...unknown)
mod.codepoint = function (s, i, j)
	i = i or 1
	if i < 0 then i = #s + i + 1 end
	j = j or i
	if j < 0 then j = #s + j + 1 end
	if band(byte(s, i) or 0, 0xc0) == 0x80 then return nil, "invalid UTF-8 sequence" end

	-- Fast path: single codepoint (most common case) — no table allocation
	if i == j then
		local b = byte(s, i) or 0
		if band(b, 0x80) == 0 then return b end  -- ASCII
		local plen = high_nibble_to_length[rshift(b, 4)] or 0
		if plen == 0 or b >= 0xf8 then return nil, "invalid UTF-8 sequence" end
		local c = band(length_to_mask[plen] or 0, b) --: integer
		for k = i + 1, i + plen - 1 do
			local b2 = byte(s, k) or 0
			if band(b2, 0xc0) ~= 0x80 then return nil, "invalid UTF-8 sequence" end
			c = bor(lshift(c, 6), band(b2, 0x3f))
		end
		return c
	end

	-- Range case: collect into table, return with unpack
	local cs = {} --: { [integer]: integer }
	while i <= j do
		local b = byte(s, i) or 0
		-- tight inner loop for ascii
		while i <= j and band(b, 0x80) == 0 do cs[#cs+1] = b; i = i + 1; b = byte(s, i) or 0 end
		if i <= j then
			local plen = high_nibble_to_length[rshift(b, 4)] or 0
			if plen == 0 or b >= 0xf8 then return nil, "invalid UTF-8 sequence" end
			local c = band(length_to_mask[plen] or 0, b) --: integer
			for k = i + 1, i + plen - 1 do
				local b2 = byte(s, k) or 0
				if band(b2, 0xc0) ~= 0x80 then return nil, "invalid UTF-8 sequence" end
				c = bor(lshift(c, 6), band(b2, 0x3f))
			end
			cs[#cs+1] = c
			i = i + plen
		end
	end
	-- The force cast here works around a typechecker limitation: generic
	-- instantiation of `unpack` (T = integer, since cs: { [integer]: integer })
	-- does not flow into the return position, so the vararg return type stays
	-- unbound. Fixing this requires typechecker work outside this directory.
	-- Cast the argument (not the call result) so parens don't truncate the
	-- multi-value return down to a single value.
	return unpack(cs)
end

--: (string, integer | nil) -> (integer | nil, integer | nil)
local codes_iter = function (s, p)
	if p == nil then p = 1
	else p = p + (high_nibble_to_length[rshift(byte(s, p) or 0, 4)] or 0) end
	if p > #s then return end
	local b = byte(s, p) or 0
	if b < 0x80 then return p, b end
	local plen = high_nibble_to_length[rshift(b, 4)] or 0
	-- invalid byte sequence: stop iteration rather than throwing (iterators cannot return errors)
	if plen == 0 or b >= 0xf8 then return nil end
	local c = band(length_to_mask[plen] or 0, b) --: integer
	for k = p + 1, p + plen - 1 do
		local b2 = byte(s, k) or 0
		if band(b2, 0xc0) ~= 0x80 then return nil end
		c = bor(lshift(c, 6), band(b2, 0x3f))
	end
	return p, c
end

--: (string) -> ((string, integer | nil) -> (integer | nil, integer | nil), string)
mod.codes = function (s)
	return codes_iter, s
end

--: (string, integer, integer | nil) -> integer
mod.offset = function (s, n, i)
	if n == 0 then
		i = i or 1
		while i < #s and band(byte(s, i) or 0, 0xc0) == 0x80 do i = i - 1 end
		return i
	elseif n >= 0 then
		i = i or 1
		local len = #s
		while i <= len and band(byte(s, i) or 0, 0xc0) == 0x80 do i = i + 1 end
		if i > len then return i end
		for _ = 2, n do
			if i > len then return i end
			i = i + 1
			while i <= len and band(byte(s, i) or 0, 0xc0) == 0x80 do i = i + 1 end
		end
		return i
	else
		i = i or #s + 1
		for _ = 1, -n do
			i = i - 1
			while i >= 1 and band(byte(s, i) or 0, 0xc0) == 0x80 do i = i - 1 end
			if i < 1 then return i end
		end
		return i
	end
end

return mod
