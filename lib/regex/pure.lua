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
	local pat_s = pat --[[:! string]]
	return nil, "regex: " .. msg .. " at position " .. pos .. " in /" .. pat_s .. "/"
end

--: (string, integer) -> (any | nil, integer | nil)
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

--: (string, integer) -> (any | nil, integer | nil)
local function parse_atom(pat, pos)
	if pos > #pat then return nil end
	local b = pat:byte(pos) or 0
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

local parse_alt --: ((string, integer, { [integer]: integer }, boolean) -> (any | nil, integer | nil)) | nil

--: (string, integer, { [integer]: integer }, boolean) -> (any | nil, integer | nil)
local function parse_seq(pat, pos, group_counter, dotall)
	local children = {}
	while pos <= #pat do
		local b = pat:byte(pos) or 0
		if b == 41 or b == 124 then break end -- ) or |
		local node, npos
		if b == 40 then -- (
			group_counter[1] = (group_counter[1] --[[:! integer]]) + 1
			local idx = group_counter[1]
			local child
			local alt_pos
			child, alt_pos = (parse_alt --[[:! (string, integer, { [integer]: integer }, boolean) -> (any | nil, integer | nil)]])(pat, pos + 1, group_counter, dotall)
			local alt_pos_i = (alt_pos or 0) --[[:! integer]]
			if not child then return child, alt_pos_i end -- propagate error
			if alt_pos_i > #pat or pat:byte(alt_pos_i) ~= 41 then
				return parse_error(pat, alt_pos_i, "unterminated group")
			end
			pos = alt_pos_i
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
		local npos_i = (npos or 0) --[[:! integer]]
		if npos and npos_i <= #pat then
			local q = pat:byte(npos_i)
			local node_a = node --[[: any]]
			if q == 42 then -- *
				node_a = { type = "quant", child = node_a, min = 0, max = math.huge, greedy = true }
				npos_i = npos_i + 1
			elseif q == 43 then -- +
				node_a = { type = "quant", child = node_a, min = 1, max = math.huge, greedy = true }
				npos_i = npos_i + 1
			elseif q == 63 then -- ?
				node_a = { type = "quant", child = node_a, min = 0, max = 1, greedy = true }
				npos_i = npos_i + 1
			end
			node = node_a
			npos = npos_i
		end
		children[#children + 1] = node
		pos = npos_i
	end
	if #children == 0 then
		return { type = "seq", children = {} }, pos
	elseif #children == 1 then
		return children[1], pos
	end
	return { type = "seq", children = children }, pos
end

--: (string, integer, { [integer]: integer }, boolean) -> (any | nil, integer | nil)
parse_alt = function(pat, pos, group_counter, dotall)
	local pat = (pat --[[:! string]])
	local first, npos = parse_seq(pat, pos, group_counter, dotall)
	if not first then return first, npos end
	local npos_i = (npos or 0) --[[:! integer]]
	if npos and npos_i <= #pat and pat:byte(npos_i) == 124 then -- |
		local alts = { first }
		while npos_i <= #pat and pat:byte(npos_i) == 124 do
			local branch
			branch, npos = parse_seq(pat, npos_i + 1, group_counter, dotall)
			if not branch then return branch, npos end
			npos_i = (npos or 0) --[[:! integer]]
			alts[#alts + 1] = branch
		end
		return { type = "alt", children = alts }, npos_i
	end
	return first, npos_i
end

--: (string, string | nil) -> (any | nil, string | nil)
local function compile_pattern(pat, flags)
	local pat = (pat --[[:! string]])
	local flags_s = (flags or "") --[[:! string]]
	local ci = false
	local dotall = false
	if flags then
		for i = 1, #flags_s do
			local c = flags_s:sub(i, i)
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
	local pos_i = (pos or 0) --[[:! integer]]
	local pat_s = pat --[[:! string]]
	if pos_i <= #pat_s then
		return parse_error(pat_s, pos_i, "unexpected character '" .. pat_s:sub(pos_i, pos_i) .. "'")
	end
	return { tree = tree, ngroups = group_counter[1], ci = ci, dotall = dotall, pattern = pat }
end

-- ── Matcher: backtracking NFA ────────────────────────────────────────────────

local function match_class(node, byte)
	local node_a = node --[[: any]]
	local hit = false
	local ranges = node_a.ranges --[[:! { [integer]: { [integer]: integer } }]]
	for i = 1, #ranges do
		local r = ranges[i]
		if byte >= r[1] and byte <= r[2] then hit = true; break end
	end
	if not hit then
		local shortcuts = node_a.shortcuts --[[:! { [integer]: { fn: (integer) -> boolean, neg: boolean } }]]
		for i = 1, #shortcuts do
			local sc = shortcuts[i]
			local res = sc.fn(byte)
			if sc.neg then res = not res end
			if res then hit = true; break end
		end
	end
	if node_a.neg then return not hit end
	return hit
end

--: (any, string, integer, { [integer]: unknown }, unknown, unknown) -> (integer | nil)
local function match_node(node, subject, pos, caps, ci, dotall)
	local node_a = node --[[: any]]
	local subject_s = subject --[[:! string]]
	local t = node_a.type
	if t == "lit" then
		if pos > #subject_s then return nil end
		local sb = subject_s:byte(pos) or 0
		local nb = (node_a.byte --[[:! integer]])
		if ci then
			-- Case-insensitive: normalize to lower
			if sb >= 65 and sb <= 90 then sb = sb + 32 end
			if nb >= 65 and nb <= 90 then nb = nb + 32 end
		end
		if sb == nb then return pos + 1 end
		return nil
	elseif t == "dot" then
		if pos > #subject_s then return nil end
		if not dotall and subject_s:byte(pos) == 10 then return nil end
		return pos + 1
	elseif t == "class" then
		if pos > #subject_s then return nil end
		local b = subject_s:byte(pos) or 0
		if ci then
			-- Try both cases
			local bl = b
			if bl >= 65 and bl <= 90 then bl = bl + 32 end
			local bu = b
			if bu >= 97 and bu <= 122 then bu = bu - 32 end
			if match_class(node_a, bl) or match_class(node_a, bu) or match_class(node_a, b) then
				return pos + 1
			end
			return nil
		end
		if match_class(node_a, b) then return pos + 1 end
		return nil
	elseif t == "shortcut" then
		if pos > #subject_s then return nil end
		local b = subject_s:byte(pos) or 0
		local res = (node_a.fn --[[:! (integer) -> boolean]])(b)
		if node_a.neg then res = not res end
		if res then return pos + 1 end
		return nil
	elseif t == "anchor_start" then
		if pos == 1 then return pos end
		return nil
	elseif t == "anchor_end" then
		if pos == #subject_s + 1 then return pos end
		return nil
	elseif t == "seq" then
		local p --: integer | nil
		p = pos
		local children_s = node_a.children --[[:! { [integer]: any }]]
		for i = 1, #children_s do
			p = match_node(children_s[i], subject_s, (p or 0) --[[:! integer]], caps, ci, dotall)
			if not p then return nil end
		end
		return p
	elseif t == "alt" then
		local children_a = node_a.children --[[:! { [integer]: any }]]
		for i = 1, #children_a do
			-- Save captures
			local saved = {}
			for k, v in pairs(caps) do saved[k] = v end
			local p = match_node(children_a[i], subject_s, pos, caps, ci, dotall)
			if p then return p end
			-- Restore captures
			for k in pairs(caps) do caps[k] = nil end
			for k, v in pairs(saved) do caps[k] = v end
		end
		return nil
	elseif t == "group" then
		local start = pos
		local p_group = match_node(node_a.child, subject_s, pos, caps, ci, dotall)
		local p_group_i = (p_group or 0) --[[:! integer]]
		if p_group then
			caps[node_a.idx] = subject_s:sub(start, p_group_i - 1)
			return p_group_i
		end
		return nil
	elseif t == "quant" then
		-- Greedy backtracking
		local child = node_a.child
		local min = node_a.min --[[:! number]]
		local max = node_a.max --[[:! number]]
		-- First, try to match as many as possible
		local positions = { pos } --: { [integer]: integer }
		local saved_caps = {}
		local count = 0
		while count < max do
			local cp = {}
			for k, v in pairs(caps) do cp[k] = v end
			local p = match_node(child, subject_s, positions[#positions], caps, ci, dotall)
			if not p then
				-- Restore caps
				for k in pairs(caps) do caps[k] = nil end
				for k, v in pairs(cp) do caps[k] = v end
				break
			end
			count = count + 1
			positions[#positions + 1] = (p or 0) --[[:! integer]]
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

--:: Regex = { _compiled: { tree: any, ngroups: integer, ci: boolean, dotall: boolean, pattern: string }, match: (self: Regex, subject: string, init: integer | nil) -> any, find: (self: Regex, subject: string, init: integer | nil) -> (integer | nil, integer | nil), gmatch: (self: Regex, subject: string) -> (() -> any), gsub: (self: Regex, subject: string, replacement: string | ((match: string, ...string) -> string), n: number | nil) -> (string, number), split: (self: Regex, subject: string) -> { [integer]: string } }
local Regex = {}
Regex.__index = Regex

function Regex:match(subject, init)
	local compiled = self._compiled --[[: any]]
	local subject_s = subject --[[:! string]]
	local start = init or 1
	local tree = compiled.tree
	local ngroups = compiled.ngroups
	local ci = compiled.ci
	local dotall = compiled.dotall
	-- Check if pattern is anchored at start
	local anchored = (tree.type == "anchor_start")
		or (tree.type == "seq" and tree.children[1] and tree.children[1].type == "anchor_start")
	local limit = anchored and start or #subject_s
	for pos = start, limit do
		local caps = {}
		local p = match_node(tree, subject_s, pos, caps, ci, dotall)
		if p then
			if ngroups > 0 then
				local result = {}
				for i = 1, ngroups do
					result[i] = caps[i] or false
				end
				return unpack(result)
			end
			return subject_s:sub(pos, p - 1)
		end
	end
	return nil
end

function Regex:find(subject, init)
	local compiled = self._compiled --[[: any]]
	local subject_s = subject --[[:! string]]
	local start = init or 1
	local tree = compiled.tree
	local ci = compiled.ci
	local dotall = compiled.dotall
	local anchored = (tree.type == "anchor_start")
		or (tree.type == "seq" and tree.children[1] and tree.children[1].type == "anchor_start")
	local limit = anchored and start or #subject_s
	for pos = start, limit do
		local caps = {}
		local p = match_node(tree, subject_s, pos, caps, ci, dotall)
		if p then return pos, p - 1 end
	end
	return nil
end

function Regex:gmatch(subject)
	local compiled = self._compiled --[[: any]]
	local subject_s = subject --[[:! string]]
	local offset = 1
	local tree = compiled.tree
	local ngroups = compiled.ngroups
	local ci = compiled.ci
	local dotall = compiled.dotall
	local len = #subject_s
	return function()
		while offset <= len do
			local caps = {}
			local p = match_node(tree, subject_s, offset, caps, ci, dotall)
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
				return subject_s:sub(old_offset, p - 1)
			else
				offset = offset + 1
			end
		end
		return nil
	end
end

--: (self: Regex, subject: string, replacement: string | ((match: string, ...string) -> string), n: number | nil) -> (string, number)
function Regex:gsub(subject, replacement, n)
	local compiled = self._compiled --[[: any]]
	local subject_s = subject --[[:! string]]
	local parts = {}
	local count = 0
	local offset = 1
	local tree = compiled.tree
	local ngroups = compiled.ngroups
	local ci = compiled.ci
	local dotall = compiled.dotall
	local len = #subject_s
	local is_fn = type(replacement) == "function"
	local replacement_fn = replacement --[[: any]]
	local replacement_s = replacement --[[: any]]
	while offset <= len do
		if n and count >= n then break end
		-- Scan forward to find next match
		local match_start, match_end_pos, match_caps
		for try_pos = offset, len do
			local try_caps = {}
			local try_p = match_node(tree, subject_s, try_pos, try_caps, ci, dotall)
			if try_p then
				match_start = try_pos
				match_end_pos = try_p
				match_caps = try_caps
				break
			end
		end
		if not match_start then break end
		local match_end_i = (match_end_pos or 0) --[[:! integer]]
		-- Append text before match
		if match_start > offset then
			parts[#parts + 1] = subject_s:sub(offset, match_start - 1)
		end
		local full_match = subject_s:sub(match_start, match_end_i - 1)
		local match_caps_a = match_caps --[[: any]]
		if is_fn then
			if ngroups > 0 then
				local cap_args = {}
				for i = 1, ngroups do cap_args[i] = match_caps_a[i] or false end
				parts[#parts + 1] = replacement_fn(full_match, unpack(cap_args)) or full_match
			else
				parts[#parts + 1] = replacement_fn(full_match) or full_match
			end
		else
			local rep_s = replacement_s --[[:! string]]
			local rep = rep_s:gsub("\\(%d)", function(d)
				local idx = tonumber(d)
				if idx == 0 then return full_match end
				return match_caps_a[idx] or ""
			end)
			parts[#parts + 1] = rep
		end
		count = count + 1
		if match_end_i == match_start then
			if match_start <= len then
				parts[#parts + 1] = subject_s:sub(match_start, match_start)
			end
			offset = match_start + 1
		else
			offset = match_end_i
		end
	end
	if offset <= len then
		parts[#parts + 1] = subject_s:sub(offset)
	end
	return table.concat(parts), count
end

function Regex:split(subject)
	local compiled = self._compiled --[[: any]]
	local subject_s = subject --[[:! string]]
	local result = {}
	local offset = 1
	local tree = compiled.tree
	local ci = compiled.ci
	local dotall = compiled.dotall
	local len = #subject_s
	while offset <= len do
		local match_start, match_end_pos
		for try_pos = offset, len do
			local caps = {}
			local p = match_node(tree, subject_s, try_pos, caps, ci, dotall)
			if p then
				match_start = try_pos
				match_end_pos = p
				break
			end
		end
		if not match_start then
			result[#result + 1] = subject_s:sub(offset)
			return result
		end
		local match_end_i = (match_end_pos or 0) --[[:! integer]]
		if match_end_i == match_start then
			-- Empty match
			result[#result + 1] = subject_s:sub(offset, offset)
			offset = offset + 1
		else
			result[#result + 1] = subject_s:sub(offset, match_start - 1)
			offset = match_end_i
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
