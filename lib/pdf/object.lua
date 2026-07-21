-- lib/pdf/object.lua
-- PDF object-model lexer/parser (ISO 32000-1 §7.3).
--
-- Parses the 8 PDF object types plus the indirect-object wrapper
-- ("N G obj ... endobj") that every top-level object in a PDF file body is
-- wrapped in.
--
-- Representation choices (mirrors lib/sexp's tagging of atoms distinct from
-- lists/strings):
--   Boolean            -> Lua boolean
--   Integer / Real      -> Lua number (PDF calls both "numeric objects";
--                          consumers essentially never need to distinguish
--                          the two syntaxes once parsed — same collapse json
--                          makes for its own numbers).
--   String (literal or  -> Lua string (decoded bytes). Literal and hex syntax
--   hex)                   are two spellings of the same object type per
--                          spec; both decode to the same byte-string value.
--   Name                -> { kind = "name", value = string }  (value has the
--                          leading '/' stripped and #xx escapes decoded).
--                          Tagged because a Name is a distinct object type
--                          from a String at the value position (e.g. dict
--                          values), not just at the key position.
--   Array               -> Lua array table (1..n, no holes).
--   Dictionary          -> Lua table keyed by plain Lua strings (leading '/'
--                          stripped from each key), values are any PDF object.
--   Stream              -> { kind = "stream", dict = <dictionary>, data = string }
--                          `data` is the raw bytes between `stream`/`endstream`
--                          exactly as stored — filters (e.g. FlateDecode) are
--                          NOT applied here. See stream_to_bytes.
--   Indirect reference  -> { kind = "reference", num = number, gen = number }
--   null                -> singleton M.null, tagged { kind = "null" } so the
--                          `kind` field works uniformly across every object
--                          that doesn't already have a native Lua type.
--
-- Errors: `(nil, errmsg)`, per docs/conventions.md. Nothing here throws for
-- malformed input.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, char, sub, find = string.byte, string.char, string.sub, string.find
local concat = table.concat

--:: PdfName = { kind: "name", value: string }
-- num/gen are always non-negative integers at the PDF syntax level, but are
-- typed `number` here because Integer and Real syntax both collapse to Lua
-- `number` throughout this module (see header comment) and object numbers
-- are parsed with the same numeric parser as any other numeric object.
--:: PdfReference = { kind: "reference", num: number, gen: number }
--:: PdfNull = { kind: "null" }
-- A PdfObject is one of: boolean, number, string, PdfName, PdfReference,
-- PdfNull, PdfStream, an array of PdfObject, or a PdfDictionary. There is no
-- declared `PdfObject` type alias for this union: it mixes scalars, arrays,
-- and dictionaries, so (as with lib/json's equally heterogeneous JSON value)
-- any precise recursive union makes `#`, indexing, and field access fail
-- overload/subtyping checks for callers that haven't first narrowed by
-- `type()`/`.kind` — the same tradeoff lib/json makes by typing decoded
-- values `unknown` rather than a `JsonValue` union. Polymorphic "any PDF
-- object" slots (array elements, dictionary values, stream dict values,
-- an indirect object's value) are therefore typed `unknown` below; callers
-- narrow the same way they would a decoded JSON value.
--:: PdfDictionary = { [string]: unknown }
--:: PdfStream = { kind: "stream", dict: PdfDictionary, data: string }
--:: PdfIndirectObject = { num: number, gen: number, value: unknown }

-- Options threaded through parsing. `resolve_length` lets a caller with xref
-- access (lib/pdf's top-level resolver) resolve a stream's indirect /Length
-- reference; see parse_dictionary_or_stream for the fallback when absent.
--:: ParseOpts = { resolve_length: ((PdfReference) -> (number | nil)) | nil }

-- Singleton null value. `kind` field lets callers branch uniformly:
--   if type(v) == "table" and v.kind == "null" then ...
M.null = setmetatable({ kind = "null" }, { __tostring = function() return "pdf.null" end }) --[[: PdfNull]]

--:: Reader = { src: string, pos: integer, len: integer }

--: (string, integer | nil) -> Reader
local function new_reader(src, pos)
	return { src = src, pos = pos or 1, len = #src }
end
M.new_reader = new_reader

-- ── Byte classification (ISO 32000-1 §7.2) ──────────────────────────────────

-- PDF whitespace: NUL, HT, LF, FF, CR, SP.
local WS = { [0] = true, [9] = true, [10] = true, [12] = true, [13] = true, [32] = true }
-- PDF delimiters: ( ) < > [ ] { } / %
local DELIM = {
	[40] = true, [41] = true, [60] = true, [62] = true,
	[91] = true, [93] = true, [123] = true, [125] = true,
	[47] = true, [37] = true,
}

--: (integer | nil) -> boolean
local function is_ws(b) return b ~= nil and WS[b] == true end
--: (integer | nil) -> boolean
local function is_delim(b) return b ~= nil and DELIM[b] == true end
--: (integer | nil) -> boolean
local function is_regular(b) return b ~= nil and not WS[b] and not DELIM[b] end
--: (integer | nil) -> boolean
local function is_digit(b) return b ~= nil and b >= 48 and b <= 57 end

--: (Reader) -> integer | nil
local function peek_byte(r)
	if r.pos > r.len then return nil end
	return byte(r.src, r.pos)
end

--: (Reader, integer) -> integer | nil
local function peek_byte_at(r, offset)
	local p = r.pos + offset
	if p > r.len or p < 1 then return nil end
	return byte(r.src, p)
end

-- Skip PDF whitespace and `%...` comments (to end of line, exclusive of the EOL).
--: (Reader) -> nil
local function skip_ws_and_comments(r)
	while true do
		local b = peek_byte(r)
		if b == nil then return end
		if WS[b] then
			r.pos = r.pos + 1
		elseif b == 37 then -- '%'
			r.pos = r.pos + 1
			while true do
				local c = peek_byte(r)
				if c == nil or c == 10 or c == 13 then break end
				r.pos = r.pos + 1
			end
		else
			return
		end
	end
end

--: (Reader, string) -> boolean
-- Match a literal keyword at the current position without consuming on failure.
local function match_keyword(r, kw)
	local n = #kw
	if r.pos + n - 1 > r.len then return false end
	if sub(r.src, r.pos, r.pos + n - 1) ~= kw then return false end
	-- Keyword must not be followed by another regular character (so "truex" is
	-- not mistaken for "true").
	local after = peek_byte_at(r, n)
	if is_regular(after) then return false end
	r.pos = r.pos + n
	return true
end

-- ── Numbers ──────────────────────────────────────────────────────────────────

--: (Reader) -> (number | nil, string | nil)
local function parse_number(r)
	local start = r.pos
	local b = peek_byte(r)
	if b == 43 or b == 45 then r.pos = r.pos + 1 end -- '+' or '-'
	local saw_digit = false
	while is_digit(peek_byte(r)) do r.pos = r.pos + 1; saw_digit = true end
	if peek_byte(r) == 46 then -- '.'
		r.pos = r.pos + 1
		while is_digit(peek_byte(r)) do r.pos = r.pos + 1; saw_digit = true end
	end
	if not saw_digit then
		r.pos = start
		return nil, "invalid number at offset " .. start
	end
	local text = sub(r.src, start, r.pos - 1)
	local n = tonumber(text)
	if n == nil then
		r.pos = start
		return nil, "invalid number literal: " .. text
	end
	return n, nil
end

-- ── Literal strings: ( ... ) ─────────────────────────────────────────────────

local OCTAL_ESCAPE = { [98] = 8, [110] = 10, [114] = 13, [116] = 9, [102] = 12 }
-- \b \n \r \t \f -> backspace, LF, CR, HT, FF

--: (Reader) -> (string | nil, string | nil)
local function parse_literal_string(r)
	if peek_byte(r) ~= 40 then return nil, "expected '(' at offset " .. r.pos end
	r.pos = r.pos + 1
	local depth = 1
	local buf = {}
	while true do
		local b = peek_byte(r)
		if b == nil then return nil, "unterminated literal string" end
		if b == 92 then -- backslash
			r.pos = r.pos + 1
			local e = peek_byte(r)
			if e == nil then return nil, "unterminated escape in literal string" end
			if e == 110 or e == 114 or e == 116 or e == 98 or e == 102 then -- n r t b f
				buf[#buf + 1] = char(OCTAL_ESCAPE[e])
				r.pos = r.pos + 1
			elseif e == 40 or e == 41 or e == 92 then -- ( ) backslash
				buf[#buf + 1] = char(e)
				r.pos = r.pos + 1
			elseif e == 13 then -- \<CR> or \<CRLF> line continuation: dropped
				r.pos = r.pos + 1
				if peek_byte(r) == 10 then r.pos = r.pos + 1 end
			elseif e == 10 then -- \<LF> line continuation: dropped
				r.pos = r.pos + 1
			elseif e >= 48 and e <= 55 then -- octal escape, 1-3 digits
				local val = 0
				local n = 0
				while n < 3 do
					local d = peek_byte(r)
					if d == nil then break end
					if d < 48 or d > 55 then break end
					val = val * 8 + (d - 48)
					r.pos = r.pos + 1
					n = n + 1
				end
				buf[#buf + 1] = char(val % 256)
			else
				-- Unrecognized escape: backslash is ignored, char kept literally.
				buf[#buf + 1] = char(e)
				r.pos = r.pos + 1
			end
		elseif b == 40 then -- unescaped '(' nests
			depth = depth + 1
			buf[#buf + 1] = "("
			r.pos = r.pos + 1
		elseif b == 41 then -- unescaped ')' — may close the string
			depth = depth - 1
			r.pos = r.pos + 1
			if depth == 0 then break end
			buf[#buf + 1] = ")"
		elseif b == 13 then -- raw CR or CRLF -> single LF
			r.pos = r.pos + 1
			if peek_byte(r) == 10 then r.pos = r.pos + 1 end
			buf[#buf + 1] = "\n"
		else
			buf[#buf + 1] = char(b)
			r.pos = r.pos + 1
		end
	end
	return concat(buf), nil
end

-- ── Hex strings: < ... > ─────────────────────────────────────────────────────

local HEX_VAL = {}
do
	for i = 0, 9 do HEX_VAL[48 + i] = i end       -- '0'-'9'
	for i = 0, 5 do HEX_VAL[65 + i] = 10 + i end  -- 'A'-'F'
	for i = 0, 5 do HEX_VAL[97 + i] = 10 + i end  -- 'a'-'f'
end

--: (Reader) -> (string | nil, string | nil)
local function parse_hex_string(r)
	if peek_byte(r) ~= 60 then return nil, "expected '<' at offset " .. r.pos end
	r.pos = r.pos + 1
	local digits = {}
	while true do
		local b = peek_byte(r)
		if b == nil then return nil, "unterminated hex string" end
		if b == 62 then -- '>'
			r.pos = r.pos + 1
			break
		elseif WS[b] then
			r.pos = r.pos + 1
		else
			local v = HEX_VAL[b]
			if v == nil then return nil, "invalid hex digit in hex string at offset " .. r.pos end
			digits[#digits + 1] = v
			r.pos = r.pos + 1
		end
	end
	if #digits % 2 == 1 then digits[#digits + 1] = 0 end -- odd trailing digit padded with 0
	local buf = {}
	for i = 1, #digits, 2 do
		buf[#buf + 1] = char(digits[i] * 16 + digits[i + 1])
	end
	return concat(buf), nil
end

-- ── Names: /Foo ──────────────────────────────────────────────────────────────

--: (Reader) -> (PdfName | nil, string | nil)
local function parse_name(r)
	if peek_byte(r) ~= 47 then return nil, "expected '/' at offset " .. r.pos end
	r.pos = r.pos + 1
	local buf = {}
	while true do
		local b = peek_byte(r)
		if not is_regular(b) then break end
		if b == 35 then -- '#' hex escape
			local h1, h2 = peek_byte_at(r, 1), peek_byte_at(r, 2)
			if h1 ~= nil and h2 ~= nil and HEX_VAL[h1] and HEX_VAL[h2] then
				buf[#buf + 1] = char(HEX_VAL[h1] * 16 + HEX_VAL[h2])
				r.pos = r.pos + 3
			else
				buf[#buf + 1] = "#"
				r.pos = r.pos + 1
			end
		else
			buf[#buf + 1] = char(b)
			r.pos = r.pos + 1
		end
	end
	return { kind = "name", value = concat(buf) }, nil
end

-- forward declaration for recursion
local parse_object

-- ── Arrays: [ ... ] ──────────────────────────────────────────────────────────

--: (Reader, ParseOpts | nil) -> ({ [integer]: unknown } | nil, string | nil)
local function parse_array(r, opts)
	if peek_byte(r) ~= 91 then return nil, "expected '[' at offset " .. r.pos end
	r.pos = r.pos + 1
	local items = {}
	while true do
		skip_ws_and_comments(r)
		local b = peek_byte(r)
		if b == nil then return nil, "unterminated array" end
		if b == 93 then -- ']'
			r.pos = r.pos + 1
			break
		end
		local v, err = parse_object(r, opts)
		if v == nil then return nil, err end
		items[#items + 1] = v
	end
	return items, nil
end

-- ── Dictionaries and streams: << ... >> [stream ... endstream] ─────────────

--: (Reader) -> boolean
local function at_dict_open(r)
	return peek_byte(r) == 60 and peek_byte_at(r, 1) == 60
end

--: (Reader) -> boolean
local function at_dict_close(r)
	return peek_byte(r) == 62 and peek_byte_at(r, 1) == 62
end

--: (Reader, ParseOpts | nil) -> (unknown, string | nil)
local function parse_dictionary_or_stream(r, opts)
	r.pos = r.pos + 2 -- consume '<<'
	local dict = {}
	while true do
		skip_ws_and_comments(r)
		if at_dict_close(r) then
			r.pos = r.pos + 2
			break
		end
		if peek_byte(r) ~= 47 then
			return nil, "expected name key in dictionary at offset " .. r.pos
		end
		local key, kerr = parse_name(r)
		if key == nil then return nil, kerr end
		skip_ws_and_comments(r)
		local val, verr = parse_object(r, opts)
		if val == nil then return nil, verr end
		dict[key.value] = val
	end

	-- Look ahead for `stream` keyword (only meaningful for indirect objects,
	-- but harmless to check anywhere a dictionary can appear).
	local save = r.pos
	skip_ws_and_comments(r)
	if match_keyword(r, "stream") then
		-- Exactly CRLF or LF must follow the `stream` keyword (ISO 32000-1 §7.3.8.1).
		local b = peek_byte(r)
		if b == 13 and peek_byte_at(r, 1) == 10 then
			r.pos = r.pos + 2
		elseif b == 10 then
			r.pos = r.pos + 1
		else
			return nil, "malformed stream: expected CRLF or LF after 'stream' keyword at offset " .. r.pos
		end

		local data_start = r.pos
		local length = dict.Length
		-- number, not integer: Integer/Real both collapse to Lua `number` in this
		-- module's object representation (see header comment), even though the
		-- PDF spec requires /Length to be an integer object.
		local data_end --: number | nil

		if type(length) == "number" then
			data_end = data_start + length
		elseif type(length) == "table" and length.kind == "reference" then
			-- /Length is an indirect reference. This module has no xref access,
			-- so it cannot resolve it directly. A caller that does have xref
			-- access (lib/pdf's top-level resolver) may supply opts.resolve_length
			-- to bridge that gap; failing that, fall back to scanning for the
			-- next `endstream` keyword — the standard technique every real-world
			-- PDF parser uses for forward-referenced stream lengths.
			local resolved = nil
			local resolve_length = opts and opts.resolve_length
			if resolve_length ~= nil then
				resolved = resolve_length(length --[[: PdfReference]])
			end
			if type(resolved) == "number" then
				data_end = data_start + resolved
			end
		end

		if data_end == nil then
			-- Missing, unresolved, or indirect /Length: scan for `endstream`.
			local found = find(r.src, "endstream", data_start, true)
			if found == nil then return nil, "unterminated stream: 'endstream' not found" end
			-- TYPECHECKER WORKAROUND: `found`, narrowed from string.find's
			-- $FindReturn<P>-derived (integer|nil) return, does not satisfy
			-- string.byte's overloaded (intersection) signature even though it
			-- satisfies string.sub's single signature and plain arithmetic — the
			-- overload resolver reports "cannot pass `_`". Natural code would be
			-- `local raw_end = found` with no cast. See TODO.md.
			local raw_end = found --[[: integer]]
			-- Strip the single EOL marker required immediately before `endstream`.
			if raw_end > data_start and byte(r.src, raw_end - 1) == 10 then
				raw_end = raw_end - 1
				if raw_end > data_start and byte(r.src, raw_end - 1) == 13 then
					raw_end = raw_end - 1
				end
			elseif raw_end > data_start and byte(r.src, raw_end - 1) == 13 then
				raw_end = raw_end - 1
			end
			local data = sub(r.src, data_start, raw_end - 1)
			r.pos = found
			if not match_keyword(r, "endstream") then
				return nil, "expected 'endstream' keyword at offset " .. r.pos
			end
			return { kind = "stream", dict = dict, data = data }, nil
		else
			-- Cast: /Length is spec-required to be an integer object, but this
			-- module's numeric collapse (see header comment) types it as plain
			-- `number`. Not a typechecker gap — a consequence of that design
			-- decision, asserted here where a byte offset is needed.
			local length_end = math.floor(data_end)
			if length_end - 1 > r.len then
				return nil, "stream length exceeds end of input"
			end
			local data = sub(r.src, data_start, length_end - 1)
			r.pos = length_end
			skip_ws_and_comments(r)
			if not match_keyword(r, "endstream") then
				return nil, "stream length mismatch: 'endstream' not found at expected offset " .. r.pos
			end
			return { kind = "stream", dict = dict, data = data }, nil
		end
	end

	r.pos = save
	return dict, nil
end

-- ── Indirect references: "N G R" vs a plain number ──────────────────────────

-- Object/generation numbers in an "N G R" reference (or "N G obj" header) are
-- always non-negative integers — no sign, no decimal point. This checks both
-- the parsed value and the raw source text so "12.0" (a real number literal
-- that happens to be integral) is correctly rejected as a reference operand.
--: (Reader, integer, integer) -> boolean
local function looks_like_object_number(r, text_start, text_end)
	local text = sub(r.src, text_start, text_end)
	if find(text, "[.+]") ~= nil then return false end
	if byte(text, 1) == 45 then return false end -- '-'
	return true
end

--: (Reader) -> (unknown, string | nil)
local function parse_number_or_reference(r)
	local n1_start = r.pos
	local n1, err1 = parse_number(r)
	if n1 == nil then return nil, err1 end
	local n1_end = r.pos - 1
	local after_first = r.pos

	if looks_like_object_number(r, n1_start, n1_end) then
		skip_ws_and_comments(r)
		if is_digit(peek_byte(r)) then
			local n2_start = r.pos
			local n2, err2 = parse_number(r)
			if n2 ~= nil and looks_like_object_number(r, n2_start, r.pos - 1) then
				skip_ws_and_comments(r)
				if peek_byte(r) == 82 and not is_regular(peek_byte_at(r, 1)) then -- 'R'
					r.pos = r.pos + 1
					return { kind = "reference", num = n1, gen = n2 }, nil
				end
			end
		end
	end

	-- Not "N G R" — rewind past the lookahead, return the plain number.
	r.pos = after_first
	return n1, nil
end

-- ── Dispatch ─────────────────────────────────────────────────────────────────

--: (Reader, ParseOpts | nil) -> (unknown, string | nil)
parse_object = function(r, opts)
	skip_ws_and_comments(r)
	local b = peek_byte(r)
	if b == nil then return nil, "unexpected end of input" end

	if b == 47 then return parse_name(r) end
	if b == 40 then return parse_literal_string(r) end
	if at_dict_open(r) then return parse_dictionary_or_stream(r, opts) end
	if b == 60 then return parse_hex_string(r) end
	if b == 91 then return parse_array(r, opts) end
	if b == 45 or b == 43 or b == 46 or is_digit(b) then
		return parse_number_or_reference(r)
	end
	if match_keyword(r, "true") then return true, nil end
	if match_keyword(r, "false") then return false, nil end
	if match_keyword(r, "null") then return M.null, nil end

	return nil, "unexpected byte " .. b .. " at offset " .. r.pos
end

M.parse_object = parse_object

-- ── Top-level indirect object: "N G obj ... endobj" ─────────────────────────

--: (Reader, ParseOpts | nil) -> (PdfIndirectObject | nil, string | nil)
function M.parse_indirect_object(r, opts)
	skip_ws_and_comments(r)
	local num, nerr = parse_number(r)
	if num == nil then return nil, nerr end
	skip_ws_and_comments(r)
	local gen, gerr = parse_number(r)
	if gen == nil then return nil, gerr end
	skip_ws_and_comments(r)
	if not match_keyword(r, "obj") then
		return nil, "expected 'obj' keyword at offset " .. r.pos
	end
	local value, verr = parse_object(r, opts)
	if value == nil then return nil, verr end
	skip_ws_and_comments(r)
	if not match_keyword(r, "endobj") then
		return nil, "expected 'endobj' keyword at offset " .. r.pos
	end
	return { num = num, gen = gen, value = value }, nil
end

--- Parse a single object from a string starting at a given byte offset (1-based).
-- Convenience entry point that doesn't require constructing a Reader.
--: (string, integer | nil, ParseOpts | nil) -> (unknown, string | nil)
function M.string_to_object(s, pos, opts)
	local r = new_reader(s, pos)
	return parse_object(r, opts)
end

--: (string, integer | nil, ParseOpts | nil) -> (PdfIndirectObject | nil, string | nil)
function M.string_to_indirect_object(s, pos, opts)
	local r = new_reader(s, pos)
	return M.parse_indirect_object(r, opts)
end

return M
