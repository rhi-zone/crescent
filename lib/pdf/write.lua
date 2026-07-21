-- lib/pdf/write.lua
-- PDF object serialization and incremental-update writing (ISO 32000-1 §7.5.6).
--
-- The inverse of lib/pdf/object.lua's parser: given a value in that module's
-- object-model representation (see its header comment for the type mapping),
-- produce PDF syntax bytes for it. Built on top for incremental updates —
-- the standard way PDF form fillers (and every other "edit a PDF without
-- rewriting the whole file") work: append new/changed indirect objects to
-- the end of the existing file, followed by a new cross-reference section
-- and trailer whose /Prev chains back to the original xref (which
-- lib/pdf/xref.lua already knows how to follow). The original bytes are
-- never modified in place.
--
-- Only a fresh, traditional (plain-text) xref section is written for the
-- appended update, regardless of whether the original file used a
-- cross-reference stream — a traditional section is valid PDF syntax
-- appended after any prior section (ISO 32000-1 §7.5.4) and every
-- conforming reader must support it, so this sidesteps needing a stream
-- compressor here.
--
-- Errors: `(nil, errmsg)`, per docs/conventions.md.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local pdf_xref = require("lib.pdf.xref")

local M = {}
M._tier = "pure"

local concat, format, byte, char = table.concat, string.format, string.byte, string.char
local floor = math.floor

-- ── Narrowing helpers over `unknown` PDF values ──────────────────────────────
-- Mirrors the pattern used throughout lib/pdf/xref.lua and lib/pdf/filter.lua.

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

-- A plain Lua array table has consecutive integer keys 1..n and no string
-- keys — the same shape lib/pdf/object.lua produces for a PDF Array. A PDF
-- Dictionary is a plain Lua table keyed by (stripped) name strings, so this
-- is how this module tells the two apart when serializing an `unknown`
-- value (there is no `kind` tag on either — see object.lua's header comment
-- on why PdfObject stays untyped `unknown`).
--: ({ [string]: unknown, [integer]: unknown }) -> boolean
local function is_array_shaped(t)
	local n = 0
	for k in pairs(t) do
		local kn = as_number(k)
		if kn == nil then return false end
		if kn < 1 or floor(kn) ~= kn then return false end
		n = n + 1
	end
	for i = 1, n do
		if t[i] == nil then return false end
	end
	return true
end

-- ── Name serialization ───────────────────────────────────────────────────────

-- Bytes a Name may print literally without a `#xx` escape: regular
-- characters (not whitespace, not a delimiter) in the printable ASCII
-- range, excluding '#' itself (always escaped so re-parsing never mistakes
-- a literal '#' for the start of an escape).
--: (integer) -> boolean
local function name_byte_needs_escape(b)
	if b == 35 then return true end -- '#'
	if b < 33 or b > 126 then return true end
	-- PDF delimiters: ( ) < > [ ] { } / %
	if b == 40 or b == 41 or b == 60 or b == 62 or b == 91 or b == 93
		or b == 123 or b == 125 or b == 47 or b == 37 then
		return true
	end
	return false
end

--: (string) -> string
local function name_to_bytes(value)
	local buf = { "/" } --[[: { [integer]: string } ]]
	for i = 1, #value do
		local b = byte(value, i)
		if b ~= nil and name_byte_needs_escape(b) then
			buf[#buf + 1] = format("#%02x", b)
		else
			buf[#buf + 1] = char(b or 0)
		end
	end
	return concat(buf)
end
M.name_to_bytes = name_to_bytes

-- ── String serialization ─────────────────────────────────────────────────────

local HEX_DIGITS = "0123456789abcdef"

-- Always emits the hex-string syntax (`<...>`), never the literal-string
-- syntax (`(...)`) — ISO 32000-1 §7.3.4.3 makes the two exact spelling
-- alternatives for the same String object type, and hex is a fixed 2-bytes-
-- per-source-byte encoding with no escaping rules to get subtly wrong for
-- arbitrary binary content (raw CR/LF normalization, nested unescaped
-- parens, octal-escape ambiguity), unlike the literal form.
--: (string) -> string
local function string_to_bytes(value)
	local buf = { "<" } --[[: { [integer]: string } ]]
	for i = 1, #value do
		local b = byte(value, i) or 0
		local hi = floor(b / 16)
		local lo = b % 16
		buf[#buf + 1] = char(byte(HEX_DIGITS, hi + 1))
		buf[#buf + 1] = char(byte(HEX_DIGITS, lo + 1))
	end
	buf[#buf + 1] = ">"
	return concat(buf)
end
M.string_to_bytes = string_to_bytes

-- ── Number serialization ─────────────────────────────────────────────────────

--: (number) -> (string | nil, string | nil)
local function number_to_bytes(n)
	if n ~= n or n == math.huge or n == -math.huge then
		return nil, "cannot serialize non-finite number " .. tostring(n)
	end
	if n == floor(n) and n < 1e15 and n > -1e15 then
		return format("%d", n), nil
	end
	-- %f avoids the scientific notation %g/tostring can fall back to for very
	-- small/large reals — PDF numeric syntax has no exponent form.
	local text = format("%.6f", n)
	-- Trim trailing zeros (and a trailing '.') left by %f's fixed precision,
	-- so round Reals like 1.500000 print as PDF would expect, "1.5".
	local trimmed = text:gsub("0+$", "")
	trimmed = trimmed:gsub("%.$", "")
	return trimmed, nil
end
M.number_to_bytes = number_to_bytes

-- ── Dispatch ─────────────────────────────────────────────────────────────────

local object_to_bytes

--: ({ [integer]: unknown }) -> (string | nil, string | nil)
local function array_to_bytes(arr)
	local buf = { "[" } --[[: { [integer]: string } ]]
	local n = 0
	for i = 1, math.huge do
		if arr[i] == nil then break end
		n = i
	end
	for i = 1, n do
		local piece, err = object_to_bytes(arr[i])
		if piece == nil then return nil, "array element " .. i .. ": " .. tostring(err) end
		if i > 1 then buf[#buf + 1] = " " end
		buf[#buf + 1] = piece
	end
	buf[#buf + 1] = "]"
	return concat(buf), nil
end

--: ({ [string]: unknown }) -> (string | nil, string | nil)
local function dict_to_bytes(dict)
	local buf = { "<<" } --[[: { [integer]: string } ]]
	for k, v in pairs(dict) do
		local piece, err = object_to_bytes(v)
		if piece == nil then return nil, "dictionary entry /" .. tostring(k) .. ": " .. tostring(err) end
		buf[#buf + 1] = " "
		buf[#buf + 1] = name_to_bytes(k)
		buf[#buf + 1] = " "
		buf[#buf + 1] = piece
	end
	buf[#buf + 1] = " >>"
	return concat(buf), nil
end

--: ({ [string]: unknown, [integer]: unknown }) -> (string | nil, string | nil)
local function stream_to_bytes(st)
	local dict = as_table(st.dict)
	if dict == nil then return nil, "stream has no dictionary" end
	local data = st.data
	if type(data) ~= "string" then return nil, "stream has no data" end
	-- The serialized /Length must describe the bytes actually written here,
	-- not whatever /Length the dictionary happened to carry (e.g. copied
	-- from a parsed object) — copy the dict and override it so the two can
	-- never drift apart.
	local dict_copy = {}
	for k, v in pairs(dict) do dict_copy[k] = v end
	dict_copy.Length = #data
	local dict_bytes, derr = dict_to_bytes(dict_copy)
	if dict_bytes == nil then return nil, derr end
	return dict_bytes .. "\nstream\n" .. data .. "\nendstream", nil
end

--- Serialize a single PDF object-model value (as produced/consumed by
-- lib/pdf/object.lua) to PDF syntax bytes. Handles every PdfObject shape:
-- boolean, number, string, PdfName, PdfReference, PdfNull, array,
-- dictionary, and stream.
--: (unknown) -> (string | nil, string | nil)
object_to_bytes = function(v)
	if type(v) == "boolean" then return v and "true" or "false", nil end
	if type(v) == "number" then return number_to_bytes(v) end
	if type(v) == "string" then return string_to_bytes(v), nil end
	if type(v) == "nil" then return nil, "cannot serialize a Lua nil (use pdf.null for a PDF null)" end
	if type(v) == "table" then
		local tv = v
		local kind = tv.kind
		if kind == "null" then return "null", nil end
		if kind == "name" then
			local name_val = tv.value
			if type(name_val) ~= "string" then return nil, "name object has no string value" end
			return name_to_bytes(name_val), nil
		end
		if kind == "reference" then
			local num = as_number(tv.num)
			local gen = as_number(tv.gen)
			if num == nil or gen == nil then return nil, "reference has no num/gen" end
			return format("%d %d R", floor(num), floor(gen)), nil
		end
		if kind == "stream" then return stream_to_bytes(tv) end
		if is_array_shaped(tv) then return array_to_bytes(tv) end
		return dict_to_bytes(tv)
	end
	return nil, "cannot serialize a Lua " .. type(v) .. " value"
end
M.object_to_bytes = object_to_bytes

--- Serialize a complete indirect object ("N G obj ... endobj").
--: ({ num: number, gen: number, value: unknown }) -> (string | nil, string | nil)
function M.indirect_object_to_bytes(iobj)
	local num = as_number(iobj.num)
	local gen = as_number(iobj.gen)
	if num == nil or gen == nil then return nil, "indirect object has no num/gen" end
	local value_bytes, err = object_to_bytes(iobj.value)
	if value_bytes == nil then return nil, err end
	return format("%d %d obj\n", floor(num), floor(gen)) .. value_bytes .. "\nendobj\n", nil
end

-- ── Incremental update (ISO 32000-1 §7.5.6) ─────────────────────────────────

--:: WriteDocument = { bytes: string, entries: unknown, trailer: unknown }
--:: NewObject = { num: number, gen: number, value: unknown }

--: (unknown) -> { [string]: unknown, [integer]: unknown } | nil
local function doc_as_table(v) return as_table(v) end

--- Append a new revision to `doc.bytes`: writes each of `objects` (a list of
-- `{ num, gen, value }` indirect objects, new or replacing an existing
-- object number) after the end of the current file, followed by a fresh
-- traditional xref section covering just those object numbers and a new
-- trailer chaining `/Prev` back to the document's existing xref (located via
-- lib/pdf/xref.lua's `find_startxref` over `doc.bytes`, the same chain
-- lib/pdf/xref.lua's `build` follows on load — so a document produced by
-- this function loads correctly through `pdf.string_to_document` again).
--
-- The trailer carries forward `/Root` from `doc.trailer` unchanged (this
-- function never rewrites the catalog) and sets `/Size` to one past the
-- highest object number known to exist (existing highest, or a written
-- object's number, whichever is larger).
--: (WriteDocument, { [integer]: NewObject }) -> (string | nil, string | nil)
function M.write_incremental_update(doc, objects)
	if type(doc.bytes) ~= "string" then return nil, "document has no source bytes" end
	local trailer = doc_as_table(doc.trailer)
	if trailer == nil then return nil, "document has no trailer" end
	if trailer.Root == nil then return nil, "document trailer has no /Root entry" end

	local prev_offset, perr = pdf_xref.find_startxref(doc.bytes)
	if prev_offset == nil then return nil, "cannot locate previous xref to chain from: " .. tostring(perr) end

	local n = 0
	for i = 1, math.huge do
		if objects[i] == nil then break end
		n = i
	end
	if n == 0 then return nil, "no objects to write" end

	-- Sort by object number so contiguous runs collapse into one xref
	-- subsection (not required for correctness — the spec allows any number
	-- of single-entry subsections — but keeps the written xref legible).
	local sorted = {} --[[: { [integer]: NewObject } ]]
	for i = 1, n do sorted[i] = objects[i] end
	table.sort(sorted, function(a, b) return a.num < b.num end)

	local body_parts = {} --[[: { [integer]: string } ]]
	local offsets = {} --[[: { [integer]: { offset: number, gen: number } } ]]
	local running_offset = #doc.bytes
	local max_num = 0 --[[: number]]
	for i = 1, n do
		local obj = sorted[i]
		local num = obj.num
		local gen = obj.gen
		local text, err = M.indirect_object_to_bytes(obj)
		if text == nil then return nil, "serializing object " .. num .. ": " .. tostring(err) end
		body_parts[#body_parts + 1] = text
		offsets[num] = { offset = running_offset, gen = gen }
		running_offset = running_offset + #text
		if num > max_num then max_num = num end
	end

	local existing_entries = doc_as_table(doc.entries)
	if existing_entries ~= nil then
		for k in pairs(existing_entries) do
			local kn = as_number(k)
			if kn ~= nil and kn > max_num then max_num = kn end
		end
	end

	-- Build xref subsections over contiguous object-number runs.
	local xref_lines = { "xref\n" } --[[: { [integer]: string } ]]
	local nums = {} --[[: { [integer]: number } ]]
	for num in pairs(offsets) do nums[#nums + 1] = num end
	-- TYPECHECKER WORKAROUND: natural code here is `table.sort(nums)` (a plain
	-- ascending sort with no comparator). This file already calls
	-- `table.sort(sorted, function(a, b) return a.num < b.num end)` above with
	-- `sorted: { [integer]: NewObject }`; the checker then binds that first
	-- call's element type to `table.sort`'s generic parameter for the *whole
	-- file* rather than re-instantiating it per call site, so this second,
	-- differently-typed call is rejected as "cannot assign `number` to
	-- `NewObject`". Confirmed as a call-site-independent, not shape-dependent,
	-- issue with a minimal two-call repro outside this file. Worked around
	-- with an explicit insertion sort instead of the stdlib call. Revert to
	-- `table.sort(nums)` once generic instantiation is per-call-site. See
	-- TODO.md.
	for i = 2, #nums do
		local v = nums[i]
		local j = i - 1
		while j >= 1 and nums[j] > v do
			nums[j + 1] = nums[j]
			j = j - 1
		end
		nums[j + 1] = v
	end
	local i = 1
	while i <= #nums do
		local run_start = nums[i]
		local j = i
		while j + 1 <= #nums and nums[j + 1] == nums[j] + 1 do j = j + 1 end
		xref_lines[#xref_lines + 1] = format("%d %d\n", run_start, j - i + 1)
		for k = i, j do
			local e = offsets[nums[k]]
			xref_lines[#xref_lines + 1] = format("%010d %05d n \n", e.offset, e.gen)
		end
		i = j + 1
	end

	local root_bytes, root_err = object_to_bytes(trailer.Root)
	if root_bytes == nil then return nil, "serializing trailer /Root: " .. tostring(root_err) end

	local xref_offset = running_offset
	local xref_text = concat(xref_lines)
	local trailer_text = "trailer\n<< /Size " .. (max_num + 1) .. " /Root "
		.. root_bytes .. " /Prev " .. prev_offset .. " >>\n"

	local new_bytes = doc.bytes .. concat(body_parts) .. xref_text .. trailer_text
		.. "startxref\n" .. xref_offset .. "\n%%EOF"
	return new_bytes, nil
end

return M
