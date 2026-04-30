-- lib/sscanf/init.lua
-- C-style scanf/sscanf for parsing structured text in Lua.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local find, sub, match, gmatch = string.find, string.sub, string.match, string.gmatch
local tonumber, tostring, type = tonumber, tostring, type
local floor, huge = math.floor, math.huge

-- ---------------------------------------------------------------------------
-- Format string parsing
-- ---------------------------------------------------------------------------
-- Each parsed directive is a table:
--   { kind="lit",    text=s }          — literal text to match
--   { kind="ws" }                       — whitespace skip (format whitespace)
--   { kind="spec",  suppress=bool, width=n|nil, conv=char, class=s|nil }
--                                       — conversion specifier

--- Parse a format string into a list of directives.
---@param fmt string
---@return table
local function parse_format(fmt)
	local directives = {}
	local i = 1
	local n = #fmt

	while i <= n do
		local c = sub(fmt, i, i)

		if c == "%" then
			i = i + 1
			if i > n then
				return nil, "format ends after '%'"
			end

			-- suppress flag
			local suppress = false
			if sub(fmt, i, i) == "*" then
				suppress = true
				i = i + 1
			end

			-- width
			local width = nil
			local ws, we = find(fmt, "^%d+", i)
			if ws then
				width = tonumber(sub(fmt, ws, we))
				i = we + 1
			end

			if i > n then
				return nil, "format ends after width"
			end

			local conv = sub(fmt, i, i)

			if conv == "%" then
				directives[#directives + 1] = { kind = "lit", text = "%" }
			elseif conv == "[" then
				-- character class: %[...] or %[^...]
				i = i + 1
				if i > n then return nil, "unterminated character class" end
				local negated = false
				if sub(fmt, i, i) == "^" then
					negated = true
					i = i + 1
				end
				-- collect class characters; ] is literal if it is the first char
				local class_chars = {}
				local first_in_class = true
				while i <= n do
					local ch = sub(fmt, i, i)
					if ch == "]" and not first_in_class then
						break
					end
					class_chars[#class_chars + 1] = ch
					first_in_class = false
					i = i + 1
				end
				if i > n then return nil, "unterminated character class" end
				-- i now points at ']'; will be incremented below
				directives[#directives + 1] = {
					kind = "spec",
					suppress = suppress,
					width = width,
					conv = "[",
					negated = negated,
					class_chars = class_chars,
				}
			elseif conv == "c" then
				directives[#directives + 1] = {
					kind = "spec",
					suppress = suppress,
					width = width or 1,
					conv = "c",
				}
			else
				directives[#directives + 1] = {
					kind = "spec",
					suppress = suppress,
					width = width,
					conv = conv,
				}
			end
			i = i + 1

		elseif c == " " or c == "\t" or c == "\n" or c == "\r" then
			-- collapse run of whitespace in format into a single ws directive
			directives[#directives + 1] = { kind = "ws" }
			while i <= n do
				local nc = sub(fmt, i, i)
				if nc == " " or nc == "\t" or nc == "\n" or nc == "\r" then
					i = i + 1
				else
					break
				end
			end
		else
			-- literal character
			-- collect run of non-% non-whitespace literals
			local start = i
			while i <= n do
				local nc = sub(fmt, i, i)
				if nc == "%" or nc == " " or nc == "\t" or nc == "\n" or nc == "\r" then
					break
				end
				i = i + 1
			end
			directives[#directives + 1] = { kind = "lit", text = sub(fmt, start, i - 1) }
		end
	end

	return directives
end

-- ---------------------------------------------------------------------------
-- Build a Lua pattern segment for a conversion specifier.
-- Returns a pattern string.  The pattern does NOT use anchors — it is used
-- with string.find(input, pattern, pos) to match at the current position.
-- ---------------------------------------------------------------------------

-- Escape a single character for use inside a Lua [] character class
local function escape_class_char(c)
	-- Characters that have special meaning inside [] in Lua patterns
	if c == "%" or c == "^" or c == "]" or c == "-" then
		return "%" .. c
	end
	return c
end

local function build_class_pattern(dir)
	-- Build [chars] or [^chars] Lua pattern from dir.class_chars
	local t = { "[" }
	if dir.negated then t[#t + 1] = "^" end
	for _, ch in ipairs(dir.class_chars) do
		t[#t + 1] = escape_class_char(ch)
	end
	t[#t + 1] = "]"
	local cls = table.concat(t)
	-- Apply width by repeating if needed — handled at match time
	return cls
end

-- ---------------------------------------------------------------------------
-- Match a single directive against input at position pos.
-- Returns: matched_text (string|nil), new_pos (number), error_msg (string|nil)
-- ---------------------------------------------------------------------------

local function match_directive(dir, input, pos)
	local ilen = #input
	if dir.kind == "lit" then
		local text = dir.text
		local tlen = #text
		if sub(input, pos, pos + tlen - 1) == text then
			return text, pos + tlen, nil
		else
			return nil, pos, "literal mismatch: expected " .. text
		end
	end

	if dir.kind == "ws" then
		-- Match 0 or more whitespace chars (greedy)
		local _, e = find(input, "^%s*", pos)
		return "", e + 1, nil
	end

	-- kind == "spec"
	local conv = dir.conv
	local width = dir.width

	if conv == "c" then
		-- %c: read exactly `width` (default 1) characters, no whitespace skip
		local w = width or 1
		if pos + w - 1 > ilen then
			return nil, pos, "%c: not enough input"
		end
		local text = sub(input, pos, pos + w - 1)
		return text, pos + w, nil
	end

	-- For all other specs, skip leading whitespace first (C scanf behaviour)
	-- (except %c which is handled above)
	local _, wsend = find(input, "^%s*", pos)
	pos = wsend + 1

	if conv == "s" then
		-- Match non-whitespace
		local pat = width and ("^.{1," .. width .. "}") or "^%S+"
		-- Use simpler approach: match char by char up to width or whitespace
		local e = pos
		local count = 0
		local limit = width or huge
		while e <= ilen and count < limit do
			local ch = sub(input, e, e)
			if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
				break
			end
			e = e + 1
			count = count + 1
		end
		if e == pos then
			return nil, pos, "%s: no token found"
		end
		return sub(input, pos, e - 1), e, nil

	elseif conv == "d" then
		-- signed decimal integer
		local s, e = find(input, "^%-?%d+", pos)
		if not s then return nil, pos, "%d: no integer" end
		if width then e = math.min(e, pos + width - 1) end
		-- re-verify after width clamp
		local text = sub(input, pos, e)
		if not match(text, "^%-?%d+$") then
			-- width may have cut mid-number; just parse what we have
			local s2, e2 = find(text, "^%-?%d+")
			if not s2 then return nil, pos, "%d: no integer after width clamp" end
			text = sub(text, s2, e2)
			e = pos + e2 - 1
		end
		return text, e + 1, nil

	elseif conv == "i" then
		-- integer: 0x hex, 0 octal, or decimal
		local text, new_pos
		if sub(input, pos, pos + 1) == "0x" or sub(input, pos, pos + 1) == "0X" then
			local s, e = find(input, "^0[xX]%x+", pos)
			if s then
				if width then e = math.min(e, pos + width - 1) end
				text = sub(input, pos, e)
				new_pos = e + 1
			end
		elseif sub(input, pos, pos) == "0" and find(input, "^0[0-7]", pos) then
			local s, e = find(input, "^0[0-7]+", pos)
			if s then
				if width then e = math.min(e, pos + width - 1) end
				text = sub(input, pos, e)
				new_pos = e + 1
			end
		end
		if not text then
			local s, e = find(input, "^%-?%d+", pos)
			if not s then return nil, pos, "%i: no integer" end
			if width then e = math.min(e, pos + width - 1) end
			text = sub(input, pos, e)
			new_pos = e + 1
		end
		return text, new_pos, nil

	elseif conv == "u" then
		-- unsigned decimal
		local s, e = find(input, "^%d+", pos)
		if not s then return nil, pos, "%u: no unsigned integer" end
		if width then e = math.min(e, pos + width - 1) end
		local text = sub(input, pos, e)
		return text, e + 1, nil

	elseif conv == "f" or conv == "e" or conv == "g" or conv == "E" or conv == "G" then
		-- floating point
		local s, e = find(input, "^%-?%d*%.?%d+", pos)
		if not s then
			-- try just integer with no dot
			s, e = find(input, "^%-?%d+", pos)
			if not s then return nil, pos, "%" .. conv .. ": no float" end
		end
		-- check for exponent
		local exp_s, exp_e = find(input, "^[eE][%+%-]?%d+", e + 1)
		if exp_s then e = exp_e end
		if width then e = math.min(e, pos + width - 1) end
		local text = sub(input, pos, e)
		return text, e + 1, nil

	elseif conv == "[" then
		-- character class
		local pat = build_class_pattern(dir)
		local e = pos
		local count = 0
		local limit = width or huge
		while e <= ilen and count < limit do
			local cs, ce = find(input, "^" .. pat, e)
			if not cs then break end
			e = ce + 1
			count = count + 1
		end
		if e == pos then
			return nil, pos, "%[]: no match"
		end
		return sub(input, pos, e - 1), e, nil

	else
		return nil, pos, "unknown conversion '%" .. conv .. "'"
	end
end

-- ---------------------------------------------------------------------------
-- Convert a matched text to a Lua value based on the conversion specifier.
-- ---------------------------------------------------------------------------

local function convert_value(conv, text)
	if conv == "d" or conv == "u" then
		local n = tonumber(text)
		if not n then return nil, "cannot convert to integer: " .. text end
		return floor(n)
	elseif conv == "i" then
		local n
		-- hex: 0x prefix
		if text:sub(1,2) == "0x" or text:sub(1,2) == "0X" then
			n = tonumber(text:sub(3), 16)
		-- octal: 0 followed by octal digits
		elseif text:sub(1,1) == "0" and #text > 1 and not text:find("[89]") then
			n = tonumber(text:sub(2), 8)
		else
			n = tonumber(text)
		end
		if not n then return nil, "cannot convert to integer: " .. text end
		return floor(n)
	elseif conv == "f" or conv == "e" or conv == "g" or conv == "E" or conv == "G" then
		local n = tonumber(text)
		if not n then return nil, "cannot convert to float: " .. text end
		return n
	else
		-- %s, %c, %[...] — return string as-is
		return text
	end
end

-- ---------------------------------------------------------------------------
-- Core engine: run directives against input, return values and named captures
-- ---------------------------------------------------------------------------

--- Run parsed directives against input starting at pos.
--- @param directives table
--- @param input string
--- @param names table|nil  — list of names in capture order (from named format)
--- @return values table|nil, named table|nil, err string|nil
local function run_directives(directives, input, names)
	local pos = 1
	local values = {}
	local named = names and {} or nil
	local cap_idx = 0  -- index into names array

	for _, dir in ipairs(directives) do
		if dir.kind == "lit" or dir.kind == "ws" then
			local _, new_pos, err = match_directive(dir, input, pos)
			if err then return nil, nil, err end
			pos = new_pos
		else
			-- spec
			local text, new_pos, err = match_directive(dir, input, pos)
			if err then return nil, nil, err end
			pos = new_pos

			if not dir.suppress then
				local val, verr = convert_value(dir.conv, text)
				if verr then return nil, nil, verr end
				values[#values + 1] = val
				if names then
					cap_idx = cap_idx + 1
					local nm = names[cap_idx]
					if nm then
						named[nm] = val
					end
				end
			end
		end
	end

	return values, named, nil
end

-- ---------------------------------------------------------------------------
-- Named format: %{name}d etc.
-- Strip names out, replace with plain specifier, build names list.
-- ---------------------------------------------------------------------------

local function parse_named_format(fmt)
	local names = {}
	local plain = fmt:gsub("%%(%*?)(%d*){([^}]+)}(.)", function(suppress, w, name, conv)
		names[#names + 1] = suppress == "*" and false or name
		return "%" .. suppress .. w .. conv
	end)
	return plain, names
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Parse a string using a C-style format, returning multiple values.
--- Returns nil (no values) if no match.
M.sscanf = function(input, fmt)
	local directives, err = parse_format(fmt)
	if not directives then return nil end
	local values, _, verr = run_directives(directives, input, nil)
	if verr then return nil end
	if #values == 0 then return nil end
	return unpack(values)
end

--- Parse using named format specifiers %{name}d.
--- Returns a table mapping names to values, or nil on failure.
M.named = function(input, fmt)
	local plain, names = parse_named_format(fmt)
	local directives, err = parse_format(plain)
	if not directives then return nil end
	local values, named, verr = run_directives(directives, input, names)
	if verr then return nil end
	return named
end

--- Parse each line of a multiline string with the given format.
--- Returns an array of arrays (one per matching line).
M.scan_all = function(input, fmt)
	local directives, err = parse_format(fmt)
	if not directives then return nil end
	local results = {}
	for line in (input .. "\n"):gmatch("([^\n]*)\n") do
		local values, _, verr = run_directives(directives, line, nil)
		if not verr and values and #values > 0 then
			results[#results + 1] = values
		end
	end
	return results
end

--- Return true if input matches the format, false otherwise.
M.matches = function(input, fmt)
	local directives, err = parse_format(fmt)
	if not directives then return false end
	local values, _, verr = run_directives(directives, input, nil)
	return verr == nil
end

--- Split a string by a separator string.
--- opts.skip_empty = true to omit empty segments.
M.split = function(input, sep, opts)
	local skip_empty = opts and opts.skip_empty
	local results = {}
	local sep_len = #sep
	local pos = 1
	local ilen = #input
	while pos <= ilen + 1 do
		local s, e = find(input, sep, pos, true)
		if not s then
			local seg = sub(input, pos)
			if not skip_empty or seg ~= "" then
				results[#results + 1] = seg
			end
			break
		end
		local seg = sub(input, pos, s - 1)
		if not skip_empty or seg ~= "" then
			results[#results + 1] = seg
		end
		pos = e + 1
	end
	return results
end

--- Tokenize a string by extracting all tokens matching a format specifier.
--- Default: %s (non-whitespace tokens).
M.tokenize = function(input, fmt)
	fmt = fmt or "%s"
	local directives, err = parse_format(fmt)
	if not directives then return nil end
	-- We expect a single spec directive
	local spec_dir
	for _, d in ipairs(directives) do
		if d.kind == "spec" then spec_dir = d break end
	end
	if not spec_dir then return nil end

	local results = {}
	local pos = 1
	local ilen = #input
	while pos <= ilen do
		-- skip whitespace between tokens
		local _, wsend = find(input, "^%s*", pos)
		pos = wsend + 1
		if pos > ilen then break end
		local text, new_pos, err = match_directive(spec_dir, input, pos)
		if err or not text or text == "" then break end
		local val, verr = convert_value(--[[:! any]] spec_dir.conv, text)
		if not verr then
			results[#results + 1] = val
		end
		pos = new_pos
	end
	return results
end

return M
