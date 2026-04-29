-- lib/regex/pure.lua
-- Pure Lua regex tier — backtracking matcher supporting a useful subset.
-- _tier = "pure-lua"
--
-- Supported syntax:
--   . * + ? ^ $ | \d \w \s \D \W \S [abc] [a-z] [^x] (...) \char

local M = {}
M._tier = "pure-lua"

-- ── Character class helpers ──────────────────────────────────────────────────

local function is_digit(c) return c >= 48 and c <= 57 end
local function is_word(c)
	return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95
end
local function is_space(c)
	return c == 32 or c == 9 or c == 10 or c == 13 or c == 12 or c == 11
end

-- ── Regex compiler: pattern string -> node tree ─────────────────────────────
--
-- Node types:
--   { type="lit", byte=N }           -- literal byte
--   { type="dot" }                   -- any char (except \n unless dotall)
--   { type="class", ranges={}, neg=bool, shortcuts={} }  -- [...]
--   { type="shortcut", fn=func, neg=bool }   -- \d \w \s etc
--   { type="seq", children={} }      -- concatenation
--   { type="alt", children={} }      -- alternation
--   { type="group", child=node, idx=N }  -- capture group
--   { type="quant", child=node, min=N, max=N|math.huge, greedy=bool }
--   { type="anchor_start" }          -- ^
--   { type="anchor_end" }            -- $

local function parse_error(pat, pos, msg)
	return nil, "regex: " .. msg .. " at position " .. pos .. " in /" .. pat .. "/"
end

local function parse_class(pat, pos)
	-- pos points to the char after '['
	local neg = false
	if pos <= #pat and pat:byte(pos) == 94 then -- ^
		neg = true
		pos = pos + 1
	end
	local ranges = {}
	local shortcuts = {}
	-- Allow ] as first char in class
	local first = true
	while pos <= #pat do
		local b = pat:byte(pos)
		if b == 93 and not first then -- ]
			return { type = "class", ranges = ranges, neg = neg, shortcuts = shortcuts }, pos + 1
		end
		first = false
		if b == 92 then -- backslash
			pos = pos + 1
			if pos > #pat then return parse_error(pat, pos, "unexpected end of pattern in class") end
			local esc = pat:byte(pos)
			if esc == 100 then -- \d
				shortcuts[#shortcuts + 1] = { fn = is_digit, neg = false }
				pos = pos + 1
			elseif esc == 68 then -- \D
				shortcuts[#shortcuts + 1] = { fn = is_digit, neg = true }
				pos = pos + 1
			elseif esc == 119 then -- \w
				shortcuts[#shortcuts + 1] = { fn = is_word, neg = false }
				pos = pos + 1
			elseif esc == 87 then -- \W
				shortcuts[#shortcuts + 1] = { fn = is_word, neg = true }
				pos = pos + 1
			elseif esc == 115 then -- \s
				shortcuts[#shortcuts + 1] = { fn = is_space, neg = false }
				pos = pos + 1
			elseif esc == 83 then -- \S
				shortcuts[#shortcuts + 1] = { fn = is_space, neg = true }
				pos = pos + 1
			else
				-- Literal escaped char — check for range
				local lo = esc
				if pos + 2 <= #pat and pat:byte(pos + 1) == 45 then -- -
					pos = pos + 2
					local hi
					if pat:byte(pos) == 92 then
						pos = pos + 1
						hi = pat:byte(pos)
					else
						hi = pat:byte(pos)
					end
					ranges[#ranges + 1] = { lo, hi }
					pos = pos + 1
				else
					ranges[#ranges + 1] = { lo, lo }
					pos = pos + 1
				end
			end
		else
			-- Normal char — check for range
			local lo = b
			if pos + 2 <= #pat and pat:byte(pos + 1) == 45 and pat:byte(pos + 2) ~= 93 then
				local hi = pat:byte(pos + 2)
				ranges[#ranges + 1] = { lo, hi }
				pos = pos + 3
			else
				ranges[#ranges + 1] = { lo, lo }
				pos = pos + 1
			end
		end
	end
	return parse_error(pat, pos, "unterminated character class")
end

local function parse_atom(pat, pos)
	if pos > #pat then return nil end
	local b = pat:byte(pos)
	if b == 40 then -- (
		-- Parse group
		return nil -- handled by parse_seq
	elseif b == 41 then -- )
		return nil
	elseif b == 124 then -- |
		return nil
	elseif b == 94 then -- ^
		return { type = "anchor_start" }, pos + 1
	elseif b == 36 then -- $
		return { type = "anchor_end" }, pos + 1
	elseif b == 46 then -- .
		return { type = "dot" }, pos + 1
	elseif b == 91 then -- [
		return parse_class(pat, pos + 1)
	elseif b == 92 then -- backslash
		pos = pos + 1
		if pos > #pat then return parse_error(pat, pos, "unexpected end of pattern") end
		local esc = pat:byte(pos)
		if esc == 100 then return { type = "shortcut", fn = is_digit, neg = false }, pos + 1
		elseif esc == 68 then return { type = "shortcut", fn = is_digit, neg = true }, pos + 1
		elseif esc == 119 then return { type = "shortcut", fn = is_word, neg = false }, pos + 1
		elseif esc == 87 then return { type = "shortcut", fn = is_word, neg = true }, pos + 1
		elseif esc == 115 then return { type = "shortcut", fn = is_space, neg = false }, pos + 1
		elseif esc == 83 then return { type = "shortcut", fn = is_space, neg = true }, pos + 1
		else return { type = "lit", byte = esc }, pos + 1
		end
	else
		return { type = "lit", byte = b }, pos + 1
	end
end

local parse_alt -- forward declaration

local function parse_seq(pat, pos, group_counter, dotall)
	local children = {}
	while pos <= #pat do
		local b = pat:byte(pos)
		if b == 41 or b == 124 then break end -- ) or |
		local node, npos
		if b == 40 then -- (
			group_counter[1] = group_counter[1] + 1
			local idx = group_counter[1]
			local child
			child, pos = parse_alt(pat, pos + 1, group_counter, dotall)
			if not child then return child, pos end -- propagate error
			if pos > #pat or pat:byte(pos) ~= 41 then
				return parse_error(pat, pos, "unterminated group")
			end
			node = { type = "group", child = child, idx = idx }
			npos = pos + 1
		else
			node, npos = parse_atom(pat, pos)
			if not node then
				if npos then return node, npos end -- error
				break
			end
		end
		-- Check for quantifier
		if npos and npos <= #pat then
			local q = pat:byte(npos)
			if q == 42 then -- *
				node = { type = "quant", child = node, min = 0, max = math.huge, greedy = true }
				npos = npos + 1
			elseif q == 43 then -- +
				node = { type = "quant", child = node, min = 1, max = math.huge, greedy = true }
				npos = npos + 1
			elseif q == 63 then -- ?
				node = { type = "quant", child = node, min = 0, max = 1, greedy = true }
				npos = npos + 1
			end
		end
		children[#children + 1] = node
		pos = npos
	end
	if #children == 0 then
		return { type = "seq", children = {} }, pos
	elseif #children == 1 then
		return children[1], pos
	end
	return { type = "seq", children = children }, pos
end

parse_alt = function(pat, pos, group_counter, dotall)
	local first, npos = parse_seq(pat, pos, group_counter, dotall)
	if not first then return first, npos end
	if npos and npos <= #pat and pat:byte(npos) == 124 then -- |
		local alts = { first }
		while npos <= #pat and pat:byte(npos) == 124 do
			local branch
			branch, npos = parse_seq(pat, npos + 1, group_counter, dotall)
			if not branch then return branch, npos end
			alts[#alts + 1] = branch
		end
		return { type = "alt", children = alts }, npos
	end
	return first, npos
end

local function compile_pattern(pat, flags)
	local ci = false
	local dotall = false
	if flags then
		for i = 1, #flags do
			local c = flags:sub(i, i)
			if c == "i" then ci = true
			elseif c == "s" then dotall = true
			elseif c == "m" or c == "x" then
				-- m and x: simplified handling
			else
				return nil, "regex: unknown flag '" .. c .. "'"
			end
		end
	end
	local group_counter = { 0 }
	local tree, pos = parse_alt(pat, 1, group_counter, dotall)
	if not tree then return tree, pos end
	if pos <= #pat then
		return parse_error(pat, pos, "unexpected character '" .. pat:sub(pos, pos) .. "'")
	end
	return { tree = tree, ngroups = group_counter[1], ci = ci, dotall = dotall, pattern = pat }
end

-- ── Matcher: backtracking NFA ────────────────────────────────────────────────

local function match_class(node, byte)
	local hit = false
	for i = 1, #node.ranges do
		local r = node.ranges[i]
		if byte >= r[1] and byte <= r[2] then hit = true; break end
	end
	if not hit then
		for i = 1, #node.shortcuts do
			local sc = node.shortcuts[i]
			local res = sc.fn(byte)
			if sc.neg then res = not res end
			if res then hit = true; break end
		end
	end
	if node.neg then return not hit end
	return hit
end

local function match_node(node, subject, pos, caps, ci, dotall)
	local t = node.type
	if t == "lit" then
		if pos > #subject then return nil end
		local sb = subject:byte(pos)
		local nb = node.byte
		if ci then
			-- Case-insensitive: normalize to lower
			if sb >= 65 and sb <= 90 then sb = sb + 32 end
			if nb >= 65 and nb <= 90 then nb = nb + 32 end
		end
		if sb == nb then return pos + 1 end
		return nil
	elseif t == "dot" then
		if pos > #subject then return nil end
		if not dotall and subject:byte(pos) == 10 then return nil end
		return pos + 1
	elseif t == "class" then
		if pos > #subject then return nil end
		local b = subject:byte(pos)
		if ci then
			-- Try both cases
			local bl = b
			if bl >= 65 and bl <= 90 then bl = bl + 32 end
			local bu = b
			if bu >= 97 and bu <= 122 then bu = bu - 32 end
			if match_class(node, bl) or match_class(node, bu) or match_class(node, b) then
				return pos + 1
			end
			return nil
		end
		if match_class(node, b) then return pos + 1 end
		return nil
	elseif t == "shortcut" then
		if pos > #subject then return nil end
		local b = subject:byte(pos)
		local res = node.fn(b)
		if node.neg then res = not res end
		if res then return pos + 1 end
		return nil
	elseif t == "anchor_start" then
		if pos == 1 then return pos end
		return nil
	elseif t == "anchor_end" then
		if pos == #subject + 1 then return pos end
		return nil
	elseif t == "seq" then
		local p = pos
		for i = 1, #node.children do
			p = match_node(node.children[i], subject, p, caps, ci, dotall)
			if not p then return nil end
		end
		return p
	elseif t == "alt" then
		for i = 1, #node.children do
			-- Save captures
			local saved = {}
			for k, v in pairs(caps) do saved[k] = v end
			local p = match_node(node.children[i], subject, pos, caps, ci, dotall)
			if p then return p end
			-- Restore captures
			for k in pairs(caps) do caps[k] = nil end
			for k, v in pairs(saved) do caps[k] = v end
		end
		return nil
	elseif t == "group" then
		local start = pos
		local p = match_node(node.child, subject, pos, caps, ci, dotall)
		if p then
			caps[node.idx] = subject:sub(start, p - 1)
			return p
		end
		return nil
	elseif t == "quant" then
		-- Greedy backtracking
		local child = node.child
		local min = node.min
		local max = node.max
		-- First, try to match as many as possible
		local positions = { pos }
		local saved_caps = {}
		local count = 0
		while count < max do
			local cp = {}
			for k, v in pairs(caps) do cp[k] = v end
			local p = match_node(child, subject, positions[#positions], caps, ci, dotall)
			if not p then
				-- Restore caps
				for k in pairs(caps) do caps[k] = nil end
				for k, v in pairs(cp) do caps[k] = v end
				break
			end
			count = count + 1
			positions[#positions + 1] = p
			saved_caps[count] = cp
		end
		-- Now backtrack from most to min
		for i = #positions, min + 1, -1 do
			return positions[i]
		end
		if min == 0 then return pos end
		return nil
	end
	return nil
end

-- ── Regex object ─────────────────────────────────────────────────────────────

local Regex = {}
Regex.__index = Regex

function Regex:match(subject, init)
	local start = init or 1
	local tree = self._compiled.tree
	local ngroups = self._compiled.ngroups
	local ci = self._compiled.ci
	local dotall = self._compiled.dotall
	-- Check if pattern is anchored at start
	local anchored = (tree.type == "anchor_start")
		or (tree.type == "seq" and tree.children[1] and tree.children[1].type == "anchor_start")
	local limit = anchored and start or #subject
	for pos = start, limit do
		local caps = {}
		local p = match_node(tree, subject, pos, caps, ci, dotall)
		if p then
			if ngroups > 0 then
				local result = {}
				for i = 1, ngroups do
					result[i] = caps[i] or false
				end
				return unpack(result)
			end
			return subject:sub(pos, p - 1)
		end
	end
	return nil
end

function Regex:find(subject, init)
	local start = init or 1
	local tree = self._compiled.tree
	local ci = self._compiled.ci
	local dotall = self._compiled.dotall
	local anchored = (tree.type == "anchor_start")
		or (tree.type == "seq" and tree.children[1] and tree.children[1].type == "anchor_start")
	local limit = anchored and start or #subject
	for pos = start, limit do
		local caps = {}
		local p = match_node(tree, subject, pos, caps, ci, dotall)
		if p then return pos, p - 1 end
	end
	return nil
end

function Regex:gmatch(subject)
	local offset = 1
	local tree = self._compiled.tree
	local ngroups = self._compiled.ngroups
	local ci = self._compiled.ci
	local dotall = self._compiled.dotall
	local len = #subject
	return function()
		while offset <= len do
			local caps = {}
			local p = match_node(tree, subject, offset, caps, ci, dotall)
			if p then
				local old_offset = offset
				if p == offset then
					offset = offset + 1
				else
					offset = p
				end
				if ngroups > 0 then
					local result = {}
					for i = 1, ngroups do
						result[i] = caps[i] or false
					end
					return unpack(result)
				end
				return subject:sub(old_offset, p - 1)
			else
				offset = offset + 1
			end
		end
		return nil
	end
end

--: (self: Regex, subject: string, replacement: string | ((match: string, ...string) -> string), n: number | nil) -> (string, number)
function Regex:gsub(subject, replacement, n)
	local parts = {}
	local count = 0
	local offset = 1
	local tree = self._compiled.tree
	local ngroups = self._compiled.ngroups
	local ci = self._compiled.ci
	local dotall = self._compiled.dotall
	local len = #subject
	local is_fn = type(replacement) == "function"
	while offset <= len do
		if n and count >= n then break end
		-- Scan forward to find next match
		local match_start, match_end_pos, match_caps
		for try_pos = offset, len do
			local try_caps = {}
			local try_p = match_node(tree, subject, try_pos, try_caps, ci, dotall)
			if try_p then
				match_start = try_pos
				match_end_pos = try_p
				match_caps = try_caps
				break
			end
		end
		if not match_start then break end
		-- Append text before match
		if match_start > offset then
			parts[#parts + 1] = subject:sub(offset, match_start - 1)
		end
		local full_match = subject:sub(match_start, match_end_pos - 1)
		if is_fn then
			if ngroups > 0 then
				local cap_args = {}
				for i = 1, ngroups do cap_args[i] = match_caps[i] or false end
				parts[#parts + 1] = replacement(full_match, unpack(cap_args)) or full_match
			else
				parts[#parts + 1] = replacement(full_match) or full_match
			end
		else
			local rep = replacement:gsub("\\(%d)", function(d)
				local idx = tonumber(d)
				if idx == 0 then return full_match end
				return match_caps[idx] or ""
			end)
			parts[#parts + 1] = rep
		end
		count = count + 1
		if match_end_pos == match_start then
			if match_start <= len then
				parts[#parts + 1] = subject:sub(match_start, match_start)
			end
			offset = match_start + 1
		else
			offset = match_end_pos
		end
	end
	if offset <= len then
		parts[#parts + 1] = subject:sub(offset)
	end
	return table.concat(parts), count
end

function Regex:split(subject)
	local result = {}
	local offset = 1
	local tree = self._compiled.tree
	local ci = self._compiled.ci
	local dotall = self._compiled.dotall
	local len = #subject
	while offset <= len do
		local match_start, match_end_pos
		for try_pos = offset, len do
			local caps = {}
			local p = match_node(tree, subject, try_pos, caps, ci, dotall)
			if p then
				match_start = try_pos
				match_end_pos = p
				break
			end
		end
		if not match_start then
			result[#result + 1] = subject:sub(offset)
			return result
		end
		if match_end_pos == match_start then
			-- Empty match
			result[#result + 1] = subject:sub(offset, offset)
			offset = offset + 1
		else
			result[#result + 1] = subject:sub(offset, match_start - 1)
			offset = match_end_pos
		end
	end
	return result
end

function M.compile(pattern, flags)
	local compiled, err = compile_pattern(pattern, flags)
	if not compiled then return nil, err end
	return setmetatable({ _compiled = compiled }, Regex)
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
