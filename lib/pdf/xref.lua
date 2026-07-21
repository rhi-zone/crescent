-- lib/pdf/xref.lua
-- PDF cross-reference table parsing (ISO 32000-1 §7.5.4, §7.5.8).
--
-- Builds the offset lookup table ("which byte offset holds object N") from
-- either a traditional xref table (`xref` keyword, plain-text subsections,
-- `trailer` dictionary) or a cross-reference stream (PDF 1.5+, a compressed
-- stream object with /Type /XRef). Follows /Prev chains across incremental
-- updates and /XRefStm hybrid pointers, merging entries with newest-wins
-- (the most recently written section is processed first; an object number
-- already resolved by a newer section is never overwritten by an older one).
--
-- Does not resolve objects — lib/pdf's top-level module does that by
-- combining this table's offsets with lib/pdf/object.lua's parser. Objects
-- stored inside an Object Stream (xref entry type 2) are represented but not
-- resolved: resolving them requires parsing the Object Stream container
-- (ISO 32000-1 §7.5.7), which is a distinct, not-yet-built piece of substrate
-- (see TODO.md).
--
-- Errors: `(nil, errmsg)`, per docs/conventions.md.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local pdf_object = require("lib.pdf.object")
local pdf_filter = require("lib.pdf.filter")

local M = {}
M._tier = "pure"

local byte_raw, sub, find = string.byte, string.sub, string.find
local floor = math.floor

-- TYPECHECKER WORKAROUND: calling string.byte's overloaded (intersection)
-- signature directly and then using the result in a comparison inside a loop
-- with `break` spuriously narrows the result to `never` (or, in a sibling
-- case, an unresolved `_`) instead of `integer | nil` — see TODO.md and the
-- same-shaped gap recorded for lib/pdf/object.lua. Natural code would call
-- string.byte directly, as lib/pdf/object.lua's `peek_byte` wrapper also
-- has to route around. Wrapping it in a local single-signature function
-- avoids the overload resolver entirely.
--: (string, integer) -> integer | nil
local function byte(s, pos)
	return byte_raw(s, pos)
end

--:: XrefEntryFree = { kind: "free" }
--:: XrefEntryInUse = { kind: "in_use", offset: number, gen: number }
-- `stream_num`/`index` name the containing Object Stream's object number and
-- this object's index within it (ISO 32000-1 §7.5.7, Table 18 type 2 row).
--:: XrefEntryCompressed = { kind: "compressed", stream_num: number, index: number }
--:: XrefEntry = XrefEntryFree | XrefEntryInUse | XrefEntryCompressed

-- `trailer` is `unknown` (a parsed PDF dictionary — see lib/pdf/object.lua's
-- header comment for why polymorphic PDF values are typed `unknown` here).
--:: XrefSection = { entries: { [integer]: XrefEntry }, trailer: unknown, prev: integer | nil, xref_stm: integer | nil }
--:: XrefTable = { entries: { [integer]: XrefEntry }, trailer: unknown }

-- Mirrors lib/pdf/object.lua's ParseOpts. Type declarations don't cross
-- `require` boundaries in this typechecker (require() return types are
-- inferred structurally from `return M`), so this is a same-shape local
-- redeclaration, not an import.
--:: XrefOpts = { resolve_length: ((unknown) -> (number | nil)) | nil }

-- ── Narrowing helpers over `unknown` PDF values ──────────────────────────────
-- Mirrors the pattern lib/pdf/object_test.lua uses: PDF values are `unknown`
-- and must be narrowed by shape before use, same as lib/json's decoded values.

--: (unknown) -> { [string]: unknown, [integer]: unknown } | nil
local function as_table(v)
	if type(v) == "table" then return v end
	return nil
end

--: (unknown) -> number | nil
local function as_number(v)
	if type(v) == "number" then return v end
	return nil
end

--: (unknown) -> integer | nil
local function as_integer(v)
	local n = as_number(v)
	if n == nil then return nil end
	return floor(n)
end

--: (unknown) -> string | nil
local function as_string(v)
	if type(v) == "string" then return v end
	return nil
end

--: (unknown) -> { [integer]: unknown } | nil
local function as_array(v)
	-- Arrays and dictionaries are both plain, untagged tables in
	-- lib/pdf/object.lua's representation; every array this module reads
	-- (/W, /Index, /Filter, /DecodeParms) is spec-mandated to be an array
	-- when present, so there is no separate discriminator to check here.
	return as_table(v)
end

-- ── Traditional xref table (ISO 32000-1 §7.5.4) ─────────────────────────────

-- PDF whitespace, mirrored from object.lua's byte classes (kept local: no
-- framework coupling between the two parsers beyond object.lua's public API).
local WS = { [0] = true, [9] = true, [10] = true, [12] = true, [13] = true, [32] = true }

--: (string, integer) -> integer
local function skip_ws(s, pos)
	local n = #s
	while pos <= n and WS[byte(s, pos)] do pos = pos + 1 end
	return pos
end

--: (string, integer) -> (integer | nil, integer | nil)
-- Reads one run of ASCII digits as an integer; returns (value, next_pos).
local function read_uint(s, pos)
	local start = pos
	local n = #s
	while pos <= n do
		local b = byte(s, pos)
		if b == nil then break end
		if b < 48 or b > 57 then break end
		pos = pos + 1
	end
	if pos == start then return nil, nil end
	local v = tonumber(sub(s, start, pos - 1))
	if v == nil then return nil, nil end
	return floor(v), pos
end

--: (string, integer) -> (XrefSection | nil, string | nil)
function M.parse_traditional(bytes, pos)
	pos = skip_ws(bytes, pos)
	if sub(bytes, pos, pos + 3) ~= "xref" then
		return nil, "expected 'xref' keyword at offset " .. pos
	end
	pos = pos + 4

	local entries = {} --[[: { [integer]: XrefEntry } ]]

	while true do
		pos = skip_ws(bytes, pos)
		if sub(bytes, pos, pos + 6) == "trailer" then
			pos = pos + 7
			break
		end
		local start, after_start = read_uint(bytes, pos)
		if start == nil or after_start == nil then
			return nil, "expected subsection header (start count) at offset " .. pos
		end
		pos = skip_ws(bytes, after_start)
		local count, after_count = read_uint(bytes, pos)
		if count == nil or after_count == nil then
			return nil, "expected subsection count at offset " .. pos
		end
		pos = after_count

		for i = 0, count - 1 do
			pos = skip_ws(bytes, pos)
			local offset, after_offset = read_uint(bytes, pos)
			if offset == nil or after_offset == nil then
				return nil, "expected entry offset at offset " .. pos
			end
			pos = skip_ws(bytes, after_offset)
			local gen, after_gen = read_uint(bytes, pos)
			if gen == nil or after_gen == nil then
				return nil, "expected entry generation at offset " .. pos
			end
			pos = skip_ws(bytes, after_gen)
			local kind_byte = byte(bytes, pos)
			if kind_byte == 110 then -- 'n'
				local objnum = start + i
				if entries[objnum] == nil then
					entries[objnum] = { kind = "in_use", offset = offset, gen = gen }
				end
				pos = pos + 1
			elseif kind_byte == 102 then -- 'f'
				local objnum = start + i
				if entries[objnum] == nil then
					entries[objnum] = { kind = "free" }
				end
				pos = pos + 1
			else
				return nil, "expected 'n' or 'f' entry type at offset " .. pos
			end
		end
	end

	local trailer, terr = pdf_object.string_to_object(bytes, pos)
	if trailer == nil then return nil, "failed to parse trailer: " .. tostring(terr) end
	local tt = as_table(trailer)
	if tt == nil then return nil, "trailer is not a dictionary" end

	return {
		entries = entries,
		trailer = trailer,
		prev = as_integer(tt.Prev),
		xref_stm = as_integer(tt.XRefStm),
	}, nil
end

-- ── Cross-reference streams (ISO 32000-1 §7.5.8) ────────────────────────────
-- Filter/predictor decoding (FlateDecode, PNG predictors) lives in
-- lib/pdf/filter.lua — shared with lib/pdf's top-level generic stream
-- resolver, since a cross-reference stream is a PDF stream like any other.

--: (unknown, XrefOpts | nil) -> ({ [integer]: XrefEntry } | nil, unknown, integer | nil, string | nil)
function M.decode_xref_stream(stream, opts)
	local st = as_table(stream)
	if st == nil or st.kind ~= "stream" then
		return nil, nil, nil, "not a stream object"
	end
	local dict = as_table(st.dict)
	if dict == nil then return nil, nil, nil, "stream has no dictionary" end
	local raw_data = as_string(st.data)
	if raw_data == nil then return nil, nil, nil, "stream has no data" end

	local w_arr = as_array(dict.W)
	if w_arr == nil then return nil, nil, nil, "xref stream missing /W [w1 w2 w3]" end
	local w1 = as_integer(w_arr[1])
	local w2 = as_integer(w_arr[2])
	local w3 = as_integer(w_arr[3])
	if w1 == nil or w2 == nil or w3 == nil then
		return nil, nil, nil, "xref stream /W must be three integers"
	end
	local row_width = w1 + w2 + w3

	local size = as_integer(dict.Size)
	local index_arr = as_array(dict.Index)
	local index_pairs = {} --[[: { [integer]: integer } ]]
	if index_arr ~= nil then
		local i = 1
		while index_arr[i] ~= nil do
			local v = as_integer(index_arr[i])
			if v == nil then return nil, nil, nil, "/Index entries must be integers" end
			index_pairs[#index_pairs + 1] = v
			i = i + 1
		end
	elseif size ~= nil then
		index_pairs = { 0, size }
	else
		return nil, nil, nil, "xref stream has neither /Index nor /Size"
	end

	local data, ferr = pdf_filter.decode_stream(dict, raw_data, row_width)
	if data == nil then return nil, nil, nil, ferr end

	local entries = {} --[[: { [integer]: XrefEntry } ]]
	local data_pos = 1
	local data_len = #data
	local pi = 1
	while index_pairs[pi] ~= nil and index_pairs[pi + 1] ~= nil do
		local sub_start = index_pairs[pi]
		local sub_count = index_pairs[pi + 1]
		pi = pi + 2
		for i = 0, sub_count - 1 do
			if data_pos + row_width - 1 > data_len then
				return nil, nil, nil, "xref stream data too short for /Index"
			end
			local field1 = 1
			if w1 > 0 then
				field1 = 0
				for k = 0, w1 - 1 do
					local b = byte(data, data_pos + k)
					if b == nil then return nil, nil, nil, "truncated xref stream row" end
					field1 = field1 * 256 + b
				end
			end
			local field2 = 0
			for k = 0, w2 - 1 do
				local b = byte(data, data_pos + w1 + k)
				if b == nil then return nil, nil, nil, "truncated xref stream row" end
				field2 = field2 * 256 + b
			end
			local field3 = 0
			for k = 0, w3 - 1 do
				local b = byte(data, data_pos + w1 + w2 + k)
				if b == nil then return nil, nil, nil, "truncated xref stream row" end
				field3 = field3 * 256 + b
			end
			data_pos = data_pos + row_width

			local objnum = sub_start + i
			if entries[objnum] == nil then
				if field1 == 0 then
					entries[objnum] = { kind = "free" }
				elseif field1 == 1 then
					entries[objnum] = { kind = "in_use", offset = field2, gen = field3 }
				elseif field1 == 2 then
					entries[objnum] = { kind = "compressed", stream_num = field2, index = field3 }
				else
					return nil, nil, nil, "unknown xref stream entry type: " .. tostring(field1)
				end
			end
		end
	end

	return entries, dict, as_integer(dict.Prev), nil
end

-- ── Top-level: locate + chain-resolve the full xref table ───────────────────

--: (string) -> (integer | nil, string | nil)
local function find_startxref(bytes)
	local last_pos = nil --: integer | nil
	local search_from = 1
	while true do
		local found = find(bytes, "startxref", search_from, true)
		if found == nil then break end
		-- TYPECHECKER WORKAROUND: same string.find narrowing gap recorded in
		-- TODO.md for lib/pdf/object.lua — the value found here doesn't
		-- survive arithmetic with its true narrowed type intact. See there.
		local found_pos = found --[[: integer]]
		last_pos = found_pos
		search_from = found_pos + 1
	end
	if last_pos == nil then return nil, "'startxref' keyword not found" end
	local pos = skip_ws(bytes, last_pos + 9)
	local offset = read_uint(bytes, pos)
	if offset == nil then return nil, "expected byte offset after 'startxref'" end
	return offset, nil
end
M.find_startxref = find_startxref

--: (string, integer, XrefOpts | nil) -> (XrefSection | nil, string | nil)
local function parse_section_at(bytes, offset, opts)
	local pos = skip_ws(bytes, offset + 1)
	if sub(bytes, pos, pos + 3) == "xref" then
		return M.parse_traditional(bytes, pos)
	end

	local indirect, ierr = pdf_object.string_to_indirect_object(bytes, offset + 1, opts)
	if indirect == nil then return nil, "failed to parse xref stream object: " .. tostring(ierr) end
	local iv = as_table(indirect)
	if iv == nil then return nil, "malformed indirect object" end
	local entries, trailer, prev, derr = M.decode_xref_stream(iv.value, opts)
	if entries == nil then return nil, derr end
	return { entries = entries, trailer = trailer, prev = prev, xref_stm = nil }, nil
end

--: (string, XrefOpts | nil) -> (XrefTable | nil, string | nil)
function M.build(bytes, opts)
	local start_offset, serr = find_startxref(bytes)
	if start_offset == nil then return nil, serr end

	local entries = {} --[[: { [integer]: XrefEntry } ]]
	local trailer = nil --: unknown
	local seen = {} --[[: { [integer]: boolean } ]]
	local offset = start_offset --: integer | nil

	while offset ~= nil do
		if seen[offset] then break end -- cyclical /Prev chain guard
		seen[offset] = true

		local section, err = parse_section_at(bytes, offset, opts)
		if section == nil then return nil, err end

		if trailer == nil then trailer = section.trailer end
		for k, v in pairs(section.entries) do
			if entries[k] == nil then entries[k] = v end
		end

		local xref_stm = section.xref_stm
		if xref_stm ~= nil then
			local hybrid, herr = parse_section_at(bytes, xref_stm, opts)
			if hybrid == nil then return nil, "failed to parse hybrid /XRefStm: " .. tostring(herr) end
			for k, v in pairs(hybrid.entries) do
				if entries[k] == nil then entries[k] = v end
			end
		end

		offset = section.prev
	end

	return { entries = entries, trailer = trailer }, nil
end

return M
